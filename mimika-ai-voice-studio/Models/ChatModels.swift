//
//  ChatModels.swift
//  mimika-ai-voice-studio
//
//  Phase 4 — chat data structures + LLM endpoint settings persistence.

import Foundation

// MARK: - Role

nonisolated enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
}

// MARK: - ChatMessage

nonisolated struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var role: Role
    var content: String
    /// Session-only image attachments. Custom Codable intentionally omits
    /// these bytes so no existing persistence/export path can write them.
    var attachments: [ChatImageAttachment]
    /// HTTP acceptance state for user turns containing attachments.
    var deliveryState: ChatDeliveryState?
    /// Sentences already piped to the TTS pipeline. Used by the ChatViewModel
    /// to track how far auto-speak has advanced on a growing assistant message
    /// so it doesn't re-synthesize earlier sentences if the model retries.
    var spokenSentences: Int

    init(
        id: UUID = UUID(),
        role: Role,
        content: String = "",
        attachments: [ChatImageAttachment] = [],
        deliveryState: ChatDeliveryState? = nil,
        spokenSentences: Int = 0
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.deliveryState = deliveryState
        self.spokenSentences = spokenSentences
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case spokenSentences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        spokenSentences = try container.decodeIfPresent(Int.self, forKey: .spokenSentences) ?? 0
        attachments = []
        deliveryState = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(spokenSentences, forKey: .spokenSentences)
    }
}

// MARK: - Chat Markdown

/// Rendered section of one assistant response.
nonisolated enum ChatMarkdownSegment: Equatable, Sendable {
    case prose(String)
    case code(language: String?, content: String)
    /// GFM pipe table. `rows` excludes the header and the `---` separator.
    ///
    /// Foundation's `AttributedString(markdown:)` has no table support at all —
    /// it handles inline styling only — so a pipe table used to render as literal
    /// `| Shift | Role |` text. Segmenting it here lets the view draw a real grid.
    case table(header: [String], rows: [[String]])
}

/// Streaming-safe fenced-code segmentation shared by chat display and reuse.
nonisolated enum ChatMarkdownParser {
    static func parse(_ source: String) -> [ChatMarkdownSegment] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var segments: [ChatMarkdownSegment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInsideCodeFence = false

        func flushProse() {
            let prose = proseLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !prose.isEmpty {
                segments.append(.prose(prose))
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let code = codeLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            segments.append(.code(language: codeLanguage, content: code))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for lineSubstring in lines {
            let line = String(lineSubstring)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInsideCodeFence {
                    flushCode()
                    isInsideCodeFence = false
                } else {
                    flushProse()
                    let language = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    isInsideCodeFence = true
                }
                continue
            }

            if isInsideCodeFence {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }

        if isInsideCodeFence {
            flushCode()
        } else {
            flushProse()
        }

        return segments.flatMap(splitTables)
    }

    // MARK: - Tables

    /// Split a prose segment into prose / table / prose runs.
    ///
    /// Runs after fence handling so a pipe table inside a code fence stays code.
    private static func splitTables(_ segment: ChatMarkdownSegment) -> [ChatMarkdownSegment] {
        guard case let .prose(text) = segment else { return [segment] }
        let lines = text.components(separatedBy: "\n")
        var out: [ChatMarkdownSegment] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.prose(joined)) }
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            // A table is a pipe row followed by a |---|---| separator.
            if index + 1 < lines.count,
               isPipeRow(lines[index]),
               isSeparatorRow(lines[index + 1]) {
                let header = cells(in: lines[index])
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count, isPipeRow(lines[cursor]) {
                    var row = cells(in: lines[cursor])
                    // Ragged rows are common in model output — pad/trim to header.
                    if row.count < header.count {
                        row += Array(repeating: "", count: header.count - row.count)
                    } else if row.count > header.count {
                        row = Array(row.prefix(header.count))
                    }
                    rows.append(row)
                    cursor += 1
                }
                flushProse()
                out.append(.table(header: header, rows: rows))
                index = cursor
                continue
            }
            prose.append(lines[index])
            index += 1
        }
        flushProse()
        return out
    }

    private static func isPipeRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.count > 1
    }

    /// `| --- | :--: |` — dashes with optional alignment colons.
    private static func isSeparatorRow(_ line: String) -> Bool {
        guard isPipeRow(line) else { return false }
        let parts = cells(in: line)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty
                && c.allSatisfy { $0 == "-" || $0 == ":" }
                && c.contains("-")
        }
    }

    /// Cells of a pipe row, without the leading/trailing delimiters.
    private static func cells(in line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - ViewMode

enum ViewMode: String, Sendable {
    case transcript
    case orb
}

// MARK: - TTS Backend

enum TTSBackendType: String, Codable, Sendable, CaseIterable, Identifiable {
    case pocketTTS = "pocket-tts"
    case fishSpeech = "fish-speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pocketTTS:  return "Pocket TTS (100M, CPU)"
        case .fishSpeech: return "Fish Audio S2 Pro (5B, MLX)"
        }
    }
}

nonisolated struct FishGenParams: Codable, Equatable, Sendable {
    var temperature: Float = 0.7
    var topP: Float = 0.7
    var topK: Int = 30

    static let `default` = FishGenParams()
}

// MARK: - Chat inference settings

/// Per-system-prompt sampling values captured with each Solo Chat request.
nonisolated struct ChatInferenceSettings: Equatable, Sendable {
    var temperature: Double
    var topP: Double
    var topK: Int
    var repeatPenalty: Double
    var maxTokens: Int? = nil

    static let `default` = ChatInferenceSettings(
        temperature: 0.7,
        topP: 0.7,
        topK: 30,
        repeatPenalty: 1.1,
        maxTokens: nil
    )
}

// MARK: - ChatSettings

nonisolated struct ChatSettings: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    var systemPrompt: String
    var ttsVoiceID: String
    var singleVoiceSystemPrompt: String
    var multiTalkSystemPrompt: String
    var activeBackend: TTSBackendType
    var fishParams: FishGenParams
    /// Read-Aloud / menu-bar feature (opt-in). When true, the app shows a
    /// menu-bar voice picker and arms the system "Read Selection Aloud" service.
    var readAloudEnabled: Bool
    /// Voice used by the menu-bar read-aloud + the Services handler.
    var readAloudVoiceID: String
    /// Keep mimika available in the menu bar at login (SMAppService).
    var launchAtLogin: Bool
    /// Force-supported model capabilities, keyed by normalized endpoint/model.
    var capabilityOverrides: [String: Int]

    static let `default` = ChatSettings(
        baseURL: "http://localhost:1234",
        model: "",
        systemPrompt: "",
        ttsVoiceID: "cosette",
        singleVoiceSystemPrompt: defaultSingleVoicePrompt,
        multiTalkSystemPrompt: defaultMultiTalkPrompt,
        activeBackend: .pocketTTS,
        fishParams: .default,
        readAloudEnabled: false,
        readAloudVoiceID: "cosette",
        launchAtLogin: false,
        capabilityOverrides: [:]
    )

    static let defaultSingleVoicePrompt = """
    You are a script writer for a text-to-speech system. Generate ONLY the spoken \
    text — no stage directions, no speaker tags, no markdown, no quotation marks, \
    no parentheticals. Write natural, conversational speech that sounds good when \
    read aloud. Keep punctuation minimal and natural. Do NOT include any formatting \
    or metadata. Avoid ellipses.
    """

    static let defaultMultiTalkPrompt = """
    You are a script writer for a multi-voice text-to-speech system. Format your \
    output EXACTLY like this:

    {Speaker 1} Their dialogue here.
    {Speaker 2} Their response here.

    Rules:
    - Use EXACTLY the tags {Speaker 1} through {Speaker N} where N is the speaker count
    - Each speaker turn must start with a speaker tag on its own line
    - Write natural conversational dialogue
    - No stage directions, no parentheticals, no markdown
    - No quotation marks around dialogue
    - Avoid ellipses (use commas or dashes for pauses instead)
    - You may include [Xs] pause markers between lines for dramatic pauses (e.g. [1.5s])
    """
}

// MARK: - SettingsStore
// Thin UserDefaults wrapper. Sync API — settings are tiny and infrequent.

nonisolated enum SettingsStore {
    private static let key = "com.slaughtersj.mimika-ai-voice-studio.chatSettings"

    /// Pre-rename storage key. Commit `99bab45` (shipped v1.5.3) renamed this key alone and left its
    /// neighbours — `chatSubMode`, `multiTalkTagDisplayMode`, `pocketTTSChunkBudget`, `whisperActiveModel` —
    /// on the old prefix, so a user updating from v1.5.2 or earlier silently lost their endpoint, model and
    /// all three hand-written system prompts. `load()` falls back to this key once and writes the result
    /// forward. It is never written to, and deliberately never removed outside a full reset.
    private static let legacyKey = "com.slaughtersj.pocket-tts-macos.chatSettings"

    /// Where settings actually live. Under XCTest this is a volatile scratch
    /// suite, never the user's real domain.
    ///
    /// Data-integrity interlock, matching `ChatThreadStore` and `VoiceManager`.
    /// The unit tests run inside the real app host, and six test classes call
    /// `resetToDefaults()` in both `setUp` and `tearDown` while others write
    /// fixture endpoints and models through `AppState.applyChatConfiguration`.
    /// Against `.standard` that destroys the user's real `ChatSettings` blob —
    /// which holds not just toggles but all three hand-written system prompts
    /// (chat, single-voice, Multi-Talk), the endpoint, model, TTS voice,
    /// backend, read-aloud settings and launch-at-login.
    /// `nonisolated(unsafe)` is honest here: `UserDefaults` is documented
    /// thread-safe, it is simply not annotated `Sendable`. Immutable after init.
    nonisolated(unsafe) private static let defaults: UserDefaults = {
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil else {
            return .standard
        }
        let suite = "mimika.settings.testsandbox.\(ProcessInfo.processInfo.processIdentifier)"
        UserDefaults.standard.removePersistentDomain(forName: suite)  // PIDs recycle
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// Reads the stored settings, falling back once to the pre-rename key and writing that blob forward.
    ///
    /// The current key is always tried first, so a user who re-entered their settings after the rename can
    /// never have them overwritten by the older orphaned blob.
    static func load() -> ChatSettings {
        if let current = decode(forKey: key) {
            return current
        }
        guard let migrated = decode(forKey: legacyKey) else { return .default }
        save(migrated)
        return migrated
    }

    /// Decodes one stored blob, returning nil when the key is absent or the payload is unreadable.
    private static func decode(forKey storageKey: String) -> ChatSettings? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ChatSettings.self, from: data)
    }

    static func save(_ settings: ChatSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    /// Clears both keys, so a reset cannot be undone by the migration fallback on the next `load()`.
    static func resetToDefaults() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }
}

// MARK: - ChatSettings migration-safe decoding
// Synthesized Codable throws on a missing key, so adding a field would make
// every existing saved settings blob fail to decode and silently reset to
// defaults. This tolerant decoder defaults any absent field to `.default`, so
// new fields (read-aloud, login item, …) can be added without losing prior
// settings. `encode(to:)` + `CodingKeys` stay synthesized.

extension ChatSettings {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatSettings.default
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        self.ttsVoiceID = try c.decodeIfPresent(String.self, forKey: .ttsVoiceID) ?? d.ttsVoiceID
        self.singleVoiceSystemPrompt = try c.decodeIfPresent(String.self, forKey: .singleVoiceSystemPrompt) ?? d.singleVoiceSystemPrompt
        self.multiTalkSystemPrompt = try c.decodeIfPresent(String.self, forKey: .multiTalkSystemPrompt) ?? d.multiTalkSystemPrompt
        self.activeBackend = try c.decodeIfPresent(TTSBackendType.self, forKey: .activeBackend) ?? d.activeBackend
        self.fishParams = try c.decodeIfPresent(FishGenParams.self, forKey: .fishParams) ?? d.fishParams
        self.readAloudEnabled = try c.decodeIfPresent(Bool.self, forKey: .readAloudEnabled) ?? d.readAloudEnabled
        self.readAloudVoiceID = try c.decodeIfPresent(String.self, forKey: .readAloudVoiceID) ?? d.readAloudVoiceID
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        self.capabilityOverrides = try c.decodeIfPresent([String: Int].self, forKey: .capabilityOverrides) ?? d.capabilityOverrides
    }
}
