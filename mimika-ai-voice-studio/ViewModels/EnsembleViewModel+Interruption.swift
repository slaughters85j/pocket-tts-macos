//
//  EnsembleViewModel+Interruption.swift
//  mimika-ai-voice-studio
//
//  Phase 4 — barge-in. One mic button drives the same 3-state dictation cycle
//  as single-chat (idle → listening → ready → submit), but the START also cuts
//  the cast off: it stops the loop + the in-flight turn + the player and drops
//  the half-spoken sentence, then the cast reacts to the user's turn. A denied
//  mic still cuts the cast off — the user just types the turn instead.
//

import Foundation

extension EnsembleViewModel {

    // MARK: - Mic button (barge-in + 3-state cycle, mirrors ChatViewModel)

    func micButtonTapped() {
        switch dictation {
        case .idle, .unavailable:
            bargeIn()
        case .listening:
            stopListening()
        case .ready:
            dictation = .idle
            finishBargeIn()
        }
    }

    // MARK: - Barge-in

    /// Cut the cast off NOW: stop the loop + in-flight turn + player, drop the
    /// in-flight sentence, hand the floor to the user, and start listening.
    /// Audio stops synchronously; auth/dictation is async.
    func bargeIn() {
        // Already parked for an invited turn — just open the mic; don't cut the wait.
        if awaitingInvitedUserTurn {
            Task { await startListening() }
            return
        }
        interruptForBargeIn()
        truncateInFlightTurn()
        currentSpeakerID = nil
        runState = .userTurn
        Task { await startListening() }
    }

    /// Drop-in-flight-sentence rule (#6): keep the fully-spoken sentences of the
    /// interrupted turn, drop the one mid-drain, mark it cut off — or remove the
    /// turn entirely if nothing landed cleanly.
    private func truncateInFlightTurn() {
        // Only truncate the turn that's actively in flight — identified by the
        // current speaker. Between turns `turns.last` is already complete and
        // must not be cut.
        guard let sid = currentSpeakerID,
              let last = turns.last, last.speakerID == sid,
              let idx = turns.firstIndex(where: { $0.id == last.id }) else { return }
        if voicedPlayback {
            // Voiced: keep the sentences fully HEARD (`spokenSentences` is the
            // count drained through the player); the one mid-drain is dropped.
            if let kept = Self.truncatedSpokenText(content: last.content, playedSentences: last.spokenSentences) {
                turns[idx].content = kept
                turns[idx].wasCutOff = true
            } else {
                turns.remove(at: idx)
            }
        } else {
            // Text-only: the streamed text was already on screen — keep it, marked.
            if last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turns.remove(at: idx)
            } else {
                turns[idx].wasCutOff = true
            }
        }
    }

    /// Pure: keep the `playedSentences` fully-heard sentences of an interrupted
    /// turn's text (re-segmented with the same detector the runner used); the
    /// sentence that was mid-drain is excluded. Returns nil when nothing was
    /// heard. Static for testing.
    static func truncatedSpokenText(content: String, playedSentences: Int) -> String? {
        guard playedSentences > 0 else { return nil }
        let detector = SentenceDetector()
        var sentences = detector.append(content)
        if let tail = detector.flush() { sentences.append(tail) }
        let kept = sentences.prefix(playedSentences).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    // MARK: - Dictation (clone of ChatViewModel+Dictation)

    func startListening() async {
        if dictationController.authState != .authorized {
            await dictationController.requestAuthorization()
        }
        switch dictationController.authState {
        case .authorized:
            break
        case .denied:
            dictation = .unavailable("Microphone or speech-recognition access denied. Enable it in System Settings → Privacy & Security, or type your turn below.")
            return
        case .restricted:
            dictation = .unavailable("Speech recognition is restricted on this device. Type your turn below.")
            return
        case .notDetermined:
            dictation = .unavailable("Permission prompt was dismissed; tap the mic again to retry.")
            return
        case .unavailable(let msg):
            dictation = .unavailable(msg)
            return
        }

        dictationStartingDraft = draft
        dictationCapturedText = ""
        dictationController.onTranscript = { [weak self] partial in
            guard let self else { return }
            self.dictationCapturedText = partial
            let sep = self.dictationStartingDraft.isEmpty || self.dictationStartingDraft.hasSuffix(" ") ? "" : " "
            self.draft = self.dictationStartingDraft + sep + partial
        }
        dictationController.onError = { [weak self] err in
            self?.dictation = .unavailable(String(describing: err))
        }
        do {
            try dictationController.start()
            dictation = .listening
        } catch {
            dictation = .unavailable(String(describing: error))
        }
    }

    func stopListening() {
        dictationController.stop()
        let captured = dictationCapturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if captured.isEmpty {
            // Nothing said — abandon the interjection and let the cast carry on.
            draft = dictationStartingDraft
            dictation = .idle
            resumeCast()
        } else {
            dictation = .ready
        }
    }

    // MARK: - Submit

    /// Append the captured/typed turn (if any) and resume the cast so someone
    /// reacts. The conductor honors a name mentioned in the user's turn.
    func finishBargeIn() {
        // Invited turn: complete the parked wait instead of starting a new loop.
        if awaitingInvitedUserTurn {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = ""
            dictation = .idle
            if !text.isEmpty {
                turns.append(EnsembleTurn(id: UUID(), speakerID: nil, speakerName: userPeer.name, content: text))
                completeInvitedUserTurn(submitted: true)
            } else {
                completeInvitedUserTurn(submitted: false)
            }
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if !text.isEmpty {
            turns.append(EnsembleTurn(id: UUID(), speakerID: nil, speakerName: userPeer.name, content: text))
        }
        resumeCast()
    }
}
