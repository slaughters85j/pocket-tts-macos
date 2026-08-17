//
//  ChatThreadModels.swift
//  mimika-ai-voice-studio
//
//  Lightweight JSON shapes for Solo / Ensemble conversation threads.
//  Catalog + per-thread files live under Application Support (same tree
//  as saved-voices/). Images stay session-only — Codable ChatMessage
//  already drops attachment bytes.
//

import Foundation

// MARK: - Kind

/// Solo vs Ensemble — sidebar lists are scoped, never mixed.
nonisolated enum ChatThreadKind: String, Codable, Sendable {
    case solo
    case ensemble
}

// MARK: - Index row

/// One sidebar card. Theme is the model-written one-liner; createdAt is
/// the date shown on the trailing edge (Messages-style).
nonisolated struct ChatThreadIndexEntry: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var kind: ChatThreadKind
    var title: String
    var theme: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool
    /// Set once the user renames the thread, so the per-turn save stops
    /// re-deriving the title from the first message.
    ///
    /// Optional on purpose: synthesized `Codable` THROWS on a missing key, so a
    /// non-optional field here would make every thread file written before this
    /// build fail to decode — and `loadIndexUnlocked` turns a decode failure into
    /// an empty index, which the next save then writes over the top of. Optional
    /// decodes as `nil` for old files.
    var titleIsCustom: Bool?
}

// MARK: - Index file

nonisolated struct ChatThreadIndex: Codable, Sendable {
    var entries: [ChatThreadIndexEntry]
}

// MARK: - Full thread file

nonisolated struct ChatThreadRecord: Identifiable, Codable, Sendable {
    var id: UUID
    var kind: ChatThreadKind
    var title: String
    var theme: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool
    var soloMessages: [ChatMessage]
    var ensemble: EnsembleThreadPayload?
    /// See `ChatThreadIndexEntry.titleIsCustom` — Optional for the same
    /// backward-compatibility reason.
    var titleIsCustom: Bool?

    init(
        id: UUID = UUID(),
        kind: ChatThreadKind,
        title: String = "New chat",
        theme: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        pinned: Bool = false,
        soloMessages: [ChatMessage] = [],
        ensemble: EnsembleThreadPayload? = nil,
        titleIsCustom: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.theme = theme
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.soloMessages = soloMessages
        self.ensemble = ensemble
        self.titleIsCustom = titleIsCustom
    }

    var indexEntry: ChatThreadIndexEntry {
        ChatThreadIndexEntry(
            id: id,
            kind: kind,
            title: title,
            theme: theme,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pinned: pinned,
            titleIsCustom: titleIsCustom
        )
    }
}

// MARK: - Tolerant decoding
// Synthesized `Codable` THROWS on any missing key, and `ChatThreadStore.loadIndexUnlocked` turns a decode
// failure into an EMPTY index — which the very next save then writes over the top of. One added field, one
// hand-edited file or one partial write would therefore cost the user every thread they own. These
// decoders mirror `ChatSettings`: `id` and `kind` stay required because a row without them addresses no
// file, and everything else falls back to a sane default. `encode(to:)` + `CodingKeys` stay synthesized.

extension ChatThreadIndexEntry {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(ChatThreadKind.self, forKey: .kind)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        self.theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? ""
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        self.createdAt = created
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom)
    }
}

extension ChatThreadRecord {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(ChatThreadKind.self, forKey: .kind)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        self.theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? ""
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        self.createdAt = created
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.soloMessages = try c.decodeIfPresent([ChatMessage].self, forKey: .soloMessages) ?? []
        self.ensemble = try c.decodeIfPresent(EnsembleThreadPayload.self, forKey: .ensemble)
        self.titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom)
    }
}

extension ChatThreadIndex {
    /// Salvages the catalog row by row, so ONE unreadable entry costs that entry alone.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try c.decodeIfPresent([SalvagedIndexRow].self, forKey: .entries) ?? []
        self.entries = rows.compactMap(\.entry)
    }
}

/// Decodes one index row to `nil` instead of throwing, so a bad row cannot fail the whole array.
private nonisolated struct SalvagedIndexRow: Decodable {
    let entry: ChatThreadIndexEntry?

    init(from decoder: Decoder) throws {
        self.entry = try? ChatThreadIndexEntry(from: decoder)
    }
}

// MARK: - Ensemble snapshot

/// Frozen cast + transcript for one Ensemble thread. Restart copies this
/// into a *new* record so the source thread is never overwritten.
nonisolated struct EnsembleThreadPayload: Codable, Equatable, Sendable {
    var scene: String
    var mood: String
    var userPeer: UserPeer
    var userCharacterRoster: [String]
    var cast: [Persona]
    var departedSpeakers: [Persona]
    var turns: [EnsembleTurn]
}
