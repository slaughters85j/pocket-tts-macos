//
//  EnsembleModels.swift
//  mimika-ai-voice-studio
//
//  Pure runtime value types for Ensemble Mode's turn loop + conductor. These
//  are deliberately separate from the SwiftData @Model types in
//  EnsembleDataModels.swift: the @Models are storage; these are the in-memory,
//  Sendable shapes the loop, conductor, and POV renderer pass around. A
//  saved `EnsemblePersona` is mapped to a runtime `Persona` when a cast is
//  loaded.
//
//  All of these are `nonisolated` (matching BundledVoice / PCMFrame house
//  style) so the nonisolated Conductor and the SpokenTurnRunner's @Sendable
//  task closures can construct and read them without crossing the module's
//  default MainActor isolation.

import Foundation

// MARK: - Persona
// One speaker as the turn loop sees it: identity, the voice to synthesize in,
// the system prompt that defines the character, the per-agent LLM temperature,
// and a turn-selection weight (talkativeness dial).

nonisolated struct Persona: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var voiceID: String
    var systemPrompt: String
    /// Retained for persistence back-compat; no longer drives sampling. The
    /// `samplingPreset` is the single source of LLM temperature/top-p/top-k.
    var temperature: Double
    var weight: Double
    /// User-facing sampling preset (Strict / Relaxed / Spirited / Butterfly
    /// Chaser) — governs the LLM temperature/top-p/top-k for this speaker.
    var samplingPreset: SamplingPreset

    init(
        id: UUID = UUID(),
        name: String,
        voiceID: String,
        systemPrompt: String,
        temperature: Double = 0.7,
        weight: Double = 1.0,
        samplingPreset: SamplingPreset = .relaxed
    ) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.weight = weight
        self.samplingPreset = samplingPreset
    }
}

// MARK: - SamplingPreset
// Friendly per-speaker "how on-the-rails" dial that maps to real sampling
// params. Stored on EnsemblePersona as its rawValue; surfaced as a segmented
// picker in setup.

nonisolated enum SamplingPreset: String, CaseIterable, Sendable {
    case strict
    case relaxed
    case spirited
    case butterflyChaser

    var displayName: String {
        switch self {
        case .strict:          return "Strict"
        case .relaxed:         return "Relaxed"
        case .spirited:        return "Spirited"
        case .butterflyChaser: return "Butterfly Chaser"
        }
    }

    var temperature: Double {
        switch self {
        case .strict:          return 0.3
        case .relaxed:         return 0.7
        case .spirited:        return 0.9
        case .butterflyChaser: return 1.1
        }
    }

    var topP: Double {
        switch self {
        case .strict:          return 0.85
        case .relaxed:         return 0.95
        case .spirited:        return 0.97
        case .butterflyChaser: return 0.98
        }
    }

    var topK: Int {
        switch self {
        case .strict:          return 20
        case .relaxed:         return 40
        case .spirited:        return 60
        case .butterflyChaser: return 100
        }
    }
}

// MARK: - UserPeer
// The human participant, modeled as a peer (not the hub) so the loop renders
// their turns the same way it renders any other named speaker.

nonisolated struct UserPeer: Equatable, Sendable {
    /// Display name — the transcript speaker tag. Defaults to the second-person
    /// "You" (right for the UI; used by the transcript, export, and history).
    var name: String = "You"
    /// Model-facing name. MUST NOT be a pronoun: the model treats a speaker label
    /// as a proper noun, so "You" gets echoed back as address ("Your skepticism",
    /// "questions You may have"). Defaults to a neutral proper noun and mirrors
    /// `name` once the user sets a real one.
    var modelName: String = "Guest"
}

// MARK: - EnsembleTurn
// One entry in the canonical, app-side transcript — the source of truth for
// both POV rendering and audio export. `speakerID == nil` means the user.

nonisolated struct EnsembleTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    var speakerID: UUID?
    var speakerName: String
    var content: String
    /// True when this line was truncated by a barge-in (Phase 4). Renders a
    /// "[cut off]" marker so the cast can react to being interrupted.
    var wasCutOff: Bool
    /// How many sentences of `content` were actually spoken before any cut.
    var spokenSentences: Int
    /// The sampling preset active for the SPEAKER when this turn was generated.
    /// Captured per-turn (a snapshot, not live) so the transcript shows preset
    /// history when the user changes a speaker's preset mid-conversation. nil for
    /// user turns. Ensemble-only — never part of the Multi-Talk export.
    var samplingPreset: SamplingPreset?
    /// True when this turn was the one-shot grenade bombshell (next speaker after
    /// the user armed the flame). Ensemble-only UI marker — not exported.
    var wasGrenade: Bool
    /// True when this turn carried a Director's Chair **Direct** instruction.
    /// Ensemble-only UI marker — not exported.
    var wasDirected: Bool
    /// Session-only images the human attached to this user turn (same types as
    /// Solo Chat). Never part of Multi-Talk / History text export.
    var attachments: [ChatImageAttachment]

    /// Synthetic "Scene" beats (boot deaths, etc.) — not a cast member or the user.
    /// Lands in POV history as a public event the models actually read.
    static let sceneBeatSpeakerID = UUID(uuidString: "A11CE5CE-0000-4000-8000-00000000BEA7")!

    /// True for director/scene announcements injected into the transcript.
    var isSceneBeat: Bool { speakerID == Self.sceneBeatSpeakerID }

    init(
        id: UUID = UUID(),
        speakerID: UUID?,
        speakerName: String,
        content: String = "",
        wasCutOff: Bool = false,
        spokenSentences: Int = 0,
        samplingPreset: SamplingPreset? = nil,
        wasGrenade: Bool = false,
        wasDirected: Bool = false,
        attachments: [ChatImageAttachment] = []
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.content = content
        self.wasCutOff = wasCutOff
        self.spokenSentences = spokenSentences
        self.samplingPreset = samplingPreset
        self.wasGrenade = wasGrenade
        self.wasDirected = wasDirected
        self.attachments = attachments
    }

    /// Public scene announcement (boot / environmental event).
    static func sceneBeat(_ content: String) -> EnsembleTurn {
        EnsembleTurn(
            speakerID: sceneBeatSpeakerID,
            speakerName: "Scene",
            content: content
        )
    }
}

// MARK: - Loop state

/// The public face of the turn-loop state machine
/// (idle -> pick -> generate -> speak -> append -> loop), plus the user-turn
/// and step-gate states.
nonisolated enum RunState: Equatable, Sendable {
    case idle
    case picking
    case generating(speaker: UUID)
    case speaking(speaker: UUID, sentenceIndex: Int)
    case awaitingStep        // .step mode, parked between turns
    case userTurn            // barge-in capture in progress
    case error(String)
}

/// Whether the loop advances autonomously or one turn at a time.
nonisolated enum AdvanceMode: Sendable {
    case auto
    case step
}

/// How the scramble dial behaves: re-draw the order every turn (chaos) or
/// shuffle once at run start (stable-but-scrambled rotation).
nonisolated enum RNGMode: String, CaseIterable, Codable, Sendable {
    case rerollPerTurn
    case shuffleOnce
}

// MARK: - ScenePlayMode
// How hard the cast should stick to the user-set scene + mood vs. follow
// whatever heat the table (and the human) just introduced. Scene-first is
// the default for faithful scene play; Free is opt-in for off-rails chaos.

// MARK: - PendingBoot
// Director's Chair: one-shot exit directive for a cast member, then remove.

/// Armed boot: force this speaker next, inject exit framing, remove after turn.
nonisolated struct PendingBoot: Equatable, Sendable {
    let speakerID: UUID
    let reason: String
}

// MARK: - PendingDirective
// Director's Chair: one-shot cast-specific direction (steer / stop phrase / etc.).

/// Armed direction: force this speaker next, inject instruction, Strict sampling.
nonisolated struct PendingDirective: Equatable, Sendable {
    let speakerID: UUID
    let instruction: String
}

/// Whether Ensemble framing prioritizes free riffing or faithful scene play.
nonisolated enum ScenePlayMode: String, CaseIterable, Codable, Sendable {
    /// Light scene/mood hints; chase lively reactions and user digressions.
    case free
    /// Prefer advancing the established scene; still always honor the human.
    case sceneFirst

    var displayName: String {
        switch self {
        case .free:       return "Free"
        case .sceneFirst: return "Scene-first"
        }
    }
}

// MARK: - ChatSubMode
// The Chat tab's Solo (1:1) vs Ensemble (multi-agent) toggle. Persisted on
// AppState; defaults to .solo so existing behavior is unchanged on launch.

nonisolated enum ChatSubMode: String, CaseIterable, Sendable {
    case solo
    case ensemble
}

// MARK: - CastPackage (portable cast export/import)
// JSON file format for sharing or backing up a cast. Source UUIDs are
// informational — import always mints new store/runtime IDs so re-importing
// the same file never collides with `@Attribute(.unique)`.

/// Top-level portable cast file (`formatVersion` 1).
nonisolated struct CastPackage: Codable, Sendable, Equatable {
    var formatVersion: Int
    var exportedAt: Date
    var cast: CastPayload
    var personas: [PersonaPayload]

    static let currentFormatVersion = 1
}

/// Cast-level metadata + run knobs captured at export time.
nonisolated struct CastPayload: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var scene: String
    var mood: String
    var userPeerName: String
    var turnModeRaw: String?
    var paceSeconds: Double?
    var maxTurns: Int?
    var contextWindowTurns: Int?
    var rollingSummaryEnabled: Bool?
    var rngModeRaw: String?
    var voicedPlayback: Bool?
    var scenePlayModeRaw: String?
}

/// One persona row in a portable cast file.
nonisolated struct PersonaPayload: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var role: String
    var voiceID: String
    var suggestedVoice: String
    var personaPrompt: String
    var temperature: Double
    var samplingPresetRaw: String
    var readsOnOthers: [String: String]
    var sortOrder: Int
}

// MARK: - CastPackageBuilder
// Pure helpers so export/import voice resolution is unit-testable without
// AppKit panels or SwiftData.

nonisolated enum CastPackageBuilder {

    /// Default voice used for brand-new manual speakers and missing imports.
    static let defaultVoiceID = "cosette"
    static let defaultNewMemberName = "Cosette"
    static let minCastSize = 1
    static let maxCastSize = 8

    /// Build a portable package from live runtime state (+ optional SwiftData
    /// role/reads when available, parallel by index).
    static func make(
        castID: UUID?,
        castName: String,
        scene: String,
        mood: String,
        userPeerName: String,
        personas: [Persona],
        rolesAndReads: [(role: String, suggestedVoice: String, reads: [String: String])] = [],
        turnMode: TurnMode,
        rngMode: RNGMode,
        paceSeconds: Double,
        maxTurns: Int,
        contextWindowTurns: Int,
        rollingSummaryEnabled: Bool,
        voicedPlayback: Bool,
        scenePlayMode: ScenePlayMode = .sceneFirst,
        exportedAt: Date = .now
    ) -> CastPackage {
        let payloads: [PersonaPayload] = personas.enumerated().map { i, p in
            let extra = rolesAndReads.indices.contains(i) ? rolesAndReads[i] : (role: "", suggestedVoice: "", reads: [:])
            return PersonaPayload(
                id: p.id,
                name: p.name,
                role: extra.role,
                voiceID: p.voiceID,
                suggestedVoice: extra.suggestedVoice,
                personaPrompt: p.systemPrompt,
                temperature: p.temperature,
                samplingPresetRaw: p.samplingPreset.rawValue,
                readsOnOthers: extra.reads,
                sortOrder: i
            )
        }
        return CastPackage(
            formatVersion: CastPackage.currentFormatVersion,
            exportedAt: exportedAt,
            cast: CastPayload(
                id: castID ?? UUID(),
                name: castName.isEmpty ? (scene.isEmpty ? "Ensemble" : scene) : castName,
                scene: scene,
                mood: mood,
                userPeerName: userPeerName,
                turnModeRaw: turnMode.rawValue,
                paceSeconds: paceSeconds,
                maxTurns: maxTurns,
                contextWindowTurns: contextWindowTurns,
                rollingSummaryEnabled: rollingSummaryEnabled,
                rngModeRaw: rngMode.rawValue,
                voicedPlayback: voicedPlayback,
                scenePlayModeRaw: scenePlayMode.rawValue
            ),
            personas: payloads
        )
    }

    /// Resolve a voiceID against the voices available on this machine.
    /// Missing stock/imported voices fall back to Cosette.
    static func resolveVoiceID(_ voiceID: String, available: Set<String>) -> String {
        if available.contains(voiceID) { return voiceID }
        return defaultVoiceID
    }

    // MARK: Import clamps (UI ranges)

    static let maxTurnsRange = 4...300
    static let verbatimWindowRange = 4...40
    static let paceSecondsRange = 0.0...2.5

    static func clampMaxTurns(_ value: Int) -> Int {
        min(maxTurnsRange.upperBound, max(maxTurnsRange.lowerBound, value))
    }

    static func clampVerbatimWindow(_ value: Int) -> Int {
        min(verbatimWindowRange.upperBound, max(verbatimWindowRange.lowerBound, value))
    }

    static func clampPaceSeconds(_ value: Double) -> Double {
        min(paceSecondsRange.upperBound, max(paceSecondsRange.lowerBound, value))
    }

    static func jsonEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    static func jsonDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
