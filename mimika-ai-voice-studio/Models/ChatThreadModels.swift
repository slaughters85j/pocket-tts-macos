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

    init(
        id: UUID = UUID(),
        kind: ChatThreadKind,
        title: String = "New chat",
        theme: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        pinned: Bool = false,
        soloMessages: [ChatMessage] = [],
        ensemble: EnsembleThreadPayload? = nil
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
    }

    var indexEntry: ChatThreadIndexEntry {
        ChatThreadIndexEntry(
            id: id,
            kind: kind,
            title: title,
            theme: theme,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pinned: pinned
        )
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
