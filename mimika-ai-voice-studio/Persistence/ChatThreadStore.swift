//
//  ChatThreadStore.swift
//  mimika-ai-voice-studio
//
//  JSON CRUD for Solo / Ensemble threads under Application Support:
//    pocket-tts-macos/chat-threads/index.json
//    pocket-tts-macos/chat-threads/solo/<uuid>.json
//    pocket-tts-macos/chat-threads/ensemble/<uuid>.json
//
//  Atomic writes (tmp + replace). Unpinned cap matches History (30 / kind).
//

import Foundation

// MARK: - ChatThreadStore

enum ChatThreadStore {
    static let maxUnpinnedPerKind = 30

    /// Serial file I/O — never encode/write JSON on the UI thread.
    private static let ioQueue = DispatchQueue(
        label: "com.mimika.chat-threads.io",
        qos: .utility
    )

    /// Tests point this at a temp folder so they never touch the live store.
    nonisolated(unsafe) static var directoryOverride: URL?

    // MARK: Paths

    static func rootDirectory() -> URL {
        if let directoryOverride { return directoryOverride }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("pocket-tts-macos", isDirectory: true)
            .appendingPathComponent("chat-threads", isDirectory: true)
    }

    private static func indexURL() -> URL {
        rootDirectory().appendingPathComponent("index.json")
    }

    private static func fileURL(id: UUID, kind: ChatThreadKind) -> URL {
        rootDirectory()
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootDirectory(), withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: rootDirectory().appendingPathComponent("solo", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: rootDirectory().appendingPathComponent("ensemble", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // MARK: Index

    static func list(kind: ChatThreadKind) -> [ChatThreadIndexEntry] {
        ioQueue.sync {
            loadIndexUnlocked().entries
                .filter { $0.kind == kind }
                .sorted { lhs, rhs in
                    if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
                    return lhs.updatedAt > rhs.updatedAt
                }
        }
    }

    static func loadIndex() -> ChatThreadIndex {
        ioQueue.sync { loadIndexUnlocked() }
    }

    private static func loadIndexUnlocked() -> ChatThreadIndex {
        ensureDirectories()
        guard
            let data = try? Data(contentsOf: indexURL()),
            let decoded = try? decoder.decode(ChatThreadIndex.self, from: data)
        else {
            return ChatThreadIndex(entries: [])
        }
        return decoded
    }

    // MARK: Record CRUD

    static func load(id: UUID, kind: ChatThreadKind) -> ChatThreadRecord? {
        ioQueue.sync { loadUnlocked(id: id, kind: kind) }
    }

    private static func loadUnlocked(id: UUID, kind: ChatThreadKind) -> ChatThreadRecord? {
        guard let data = try? Data(contentsOf: fileURL(id: id, kind: kind)) else {
            return nil
        }
        return try? decoder.decode(ChatThreadRecord.self, from: data)
    }

    @discardableResult
    static func save(_ record: ChatThreadRecord) -> ChatThreadRecord {
        ioQueue.sync { saveUnlocked(record) }
    }

    /// Encode + write off the main thread; hop back for UI (sidebar upsert).
    static func saveAsync(
        _ record: ChatThreadRecord,
        completion: @escaping @MainActor (ChatThreadRecord) -> Void
    ) {
        ioQueue.async {
            let saved = saveUnlocked(record)
            DispatchQueue.main.async {
                completion(saved)
            }
        }
    }

    private static func saveUnlocked(_ record: ChatThreadRecord) -> ChatThreadRecord {
        ensureDirectories()
        var next = record
        next.updatedAt = .now
        writeAtomically(next, to: fileURL(id: next.id, kind: next.kind))
        upsertIndex(next.indexEntry)
        enforceCap(kind: next.kind)
        return next
    }

    static func create(kind: ChatThreadKind, title: String = "New chat") -> ChatThreadRecord {
        let record = ChatThreadRecord(kind: kind, title: title)
        return save(record)
    }

    static func delete(id: UUID, kind: ChatThreadKind) {
        ioQueue.sync {
            try? FileManager.default.removeItem(at: fileURL(id: id, kind: kind))
            var index = loadIndexUnlocked()
            index.entries.removeAll { $0.id == id }
            writeIndex(index)
        }
    }

    static func setPinned(id: UUID, kind: ChatThreadKind, pinned: Bool) {
        ioQueue.sync {
            var index = loadIndexUnlocked()
            guard let i = index.entries.firstIndex(where: { $0.id == id }) else { return }
            index.entries[i].pinned = pinned
            writeIndex(index)
            if var record = loadUnlocked(id: id, kind: kind) {
                record.pinned = pinned
                writeAtomically(record, to: fileURL(id: id, kind: kind))
            }
        }
    }

    static func updateTheme(id: UUID, kind: ChatThreadKind, theme: String) {
        let trimmed = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ioQueue.sync {
            var index = loadIndexUnlocked()
            if let i = index.entries.firstIndex(where: { $0.id == id }) {
                index.entries[i].theme = trimmed
                writeIndex(index)
            }
            if var record = loadUnlocked(id: id, kind: kind) {
                record.theme = trimmed
                writeAtomically(record, to: fileURL(id: id, kind: kind))
            }
        }
    }

    // MARK: Theme prompt

    /// System prompt for the one-sentence sidebar blurb.
    static let themeSystemPrompt = """
    Write ONE short sentence (at most 14 words) that names the theme of this conversation. \
    No quotes, no preamble, no speaker names, no emoji. Just the sentence.
    """

    static func themeSourceText(from messages: [ChatMessage]) -> String {
        messages
            .filter { $0.role != .system }
            .prefix(8)
            .map { "\($0.role.rawValue): \($0.content)" }
            .joined(separator: "\n")
    }

    static func themeSourceText(from turns: [EnsembleTurn]) -> String {
        turns
            .filter { !$0.isSceneBeat }
            .prefix(8)
            .map { "\($0.speakerName): \($0.content)" }
            .joined(separator: "\n")
    }

    static func cleanedTheme(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.split(whereSeparator: { $0 == "\n" }).first {
            s = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (s.hasPrefix("\"") && s.hasSuffix("\""))
            || (s.hasPrefix("“") && s.hasSuffix("”")),
           s.count > 1 {
            s = String(s.dropFirst().dropLast())
        }
        return String(s.prefix(140))
    }

    // MARK: Internals

    private static func upsertIndex(_ entry: ChatThreadIndexEntry) {
        var index = loadIndexUnlocked()
        if let i = index.entries.firstIndex(where: { $0.id == entry.id }) {
            var merged = entry
            merged.pinned = index.entries[i].pinned || entry.pinned
            merged.theme = entry.theme.isEmpty ? index.entries[i].theme : entry.theme
            index.entries[i] = merged
        } else {
            index.entries.insert(entry, at: 0)
        }
        writeIndex(index)
    }

    private static func enforceCap(kind: ChatThreadKind) {
        var index = loadIndexUnlocked()
        let unpinned = index.entries
            .filter { $0.kind == kind && !$0.pinned }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard unpinned.count > maxUnpinnedPerKind else { return }
        for stale in unpinned.dropFirst(maxUnpinnedPerKind) {
            try? FileManager.default.removeItem(at: fileURL(id: stale.id, kind: stale.kind))
            index.entries.removeAll { $0.id == stale.id }
        }
        writeIndex(index)
    }

    private static func writeIndex(_ index: ChatThreadIndex) {
        writeAtomically(index, to: indexURL())
    }

    private static func writeAtomically<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private static let decoder: JSONDecoder = {
        CastPackageBuilder.jsonDecoder()
    }()
}
