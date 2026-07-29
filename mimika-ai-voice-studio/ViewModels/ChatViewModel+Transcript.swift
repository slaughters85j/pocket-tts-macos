//
//  ChatViewModel+Transcript.swift
//  mimika-ai-voice-studio
//
//  View mode, transcript export, and text-only Multi-Talk reuse.

import AppKit
import Foundation
import UniformTypeIdentifiers

extension ChatViewModel {

    // MARK: View mode

    /// Toggle between the orb and transcript surfaces.
    func toggleViewMode() {
        viewMode = (viewMode == .orb) ? .transcript : .orb
        UserDefaults.standard.set(viewMode.rawValue, forKey: "chatViewMode")
    }

    /// Clear sent transcript state while preserving the unsent composer.
    func resetTranscript() {
        guard activeTurn == nil else {
            showToast("Please wait until the model finishes responding.")
            return
        }

        messages.removeAll()
        previewAttachment = nil
        showsVisionRecovery = false
        deferredVisionRecovery = false
        lastAutomaticVisionRecoveryKey = nil
        status = .idle
    }

    // MARK: Transcript export

    /// Present a Markdown save panel for reusable text only.
    func saveTranscript() {
        let panel = NSSavePanel()
        panel.title = "Save Chat Transcript"
        panel.nameFieldStringValue = "chat-transcript.md"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try formatTranscriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            status = .error("Failed to save: \(shortError(error))")
        }
    }

    /// Build a text-only payload that opens the transcript in Multi-Talk.
    func multiTalkPayload() -> PendingReuse {
        let voiceID = settings.ttsVoiceID
        let alternateVoice = voiceID == "cosette" ? "jean" : "cosette"
        return .multi(
            script: formatTranscriptMultiTalk(),
            speakers: [
                SpeakerRef(name: "Speaker 1", voiceID: alternateVoice),
                SpeakerRef(name: "Speaker 2", voiceID: voiceID)
            ],
            normalizeSpeakers: true
        )
    }

    /// Markdown export deliberately drops images and image-only turns.
    func formatTranscriptMarkdown() -> String {
        messages.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.role != .system, !content.isEmpty else { return nil }
            let label = message.role == .user ? "**You**" : "**Assistant**"
            return "\(label):\n\(content)"
        }
        .joined(separator: "\n\n---\n\n") + "\n"
    }

    /// Multi-Talk reuse deliberately drops images and image-only turns.
    func formatTranscriptMultiTalk() -> String {
        let stripBrackets = settings.activeBackend == .pocketTTS
        return messages.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.role != .system, !content.isEmpty else { return nil }
            let tag = message.role == .user ? "{Speaker 1}" : "{Speaker 2}"
            let cleaned = TextNormalizer.stripStageDirections(
                content,
                stripBracketedTags: stripBrackets
            )
            return cleaned.isEmpty ? nil : "\(tag) \(cleaned)"
        }
        .joined(separator: "\n")
    }
}
