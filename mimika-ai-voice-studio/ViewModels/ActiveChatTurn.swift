//
//  ActiveChatTurn.swift
//  mimika-ai-voice-studio
//
//  Single-flight lifecycle state for one Solo Chat request.

import Foundation
import Observation

// MARK: - Active turn

/// Main-actor owner for one Solo Chat request and its LLM/TTS tasks.
@MainActor
@Observable
final class ActiveChatTurn {
    enum Phase: Equatable {
        case awaitingAcceptance
        case accepted
        case terminal
    }

    let id = UUID()
    let userMessageID: UUID
    let assistantMessageID: UUID
    let originalDraft: String
    let originalAttachments: [ChatImageAttachment]
    var phase: Phase = .awaitingAcceptance
    var llmFinished = false
    var ttsFinished = false
    var wasCancelled = false
    @ObservationIgnored var llmTask: Task<Void, Never>?
    @ObservationIgnored var ttsTask: Task<Void, Never>?

    init(
        userMessageID: UUID,
        assistantMessageID: UUID,
        originalDraft: String,
        originalAttachments: [ChatImageAttachment]
    ) {
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.originalDraft = originalDraft
        self.originalAttachments = originalAttachments
    }

    /// True only after both asynchronous halves have stopped.
    var isSettled: Bool {
        llmFinished && ttsFinished
    }

    /// Cancel all work owned by this turn.
    func cancel() {
        wasCancelled = true
        llmTask?.cancel()
        ttsTask?.cancel()
    }
}
