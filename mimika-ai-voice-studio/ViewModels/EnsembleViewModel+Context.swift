//
//  EnsembleViewModel+Context.swift
//  mimika-ai-voice-studio
//
//  Point-of-view transcript rendering — the single mechanism that gives every
//  speaker both "shared context" and "unawareness": each persona sees its own
//  lines as the assistant and everyone else (other personas AND the user) as
//  name-prefixed people, never as AIs. Kept as a pure static so it can be unit
//  tested without constructing the whole view model.
//
//  Also: Director's Chair soft context dump — shrink model-facing history without
//  wiping the app transcript (export/history stay intact).
//

import Foundation

extension EnsembleViewModel {

    /// Build the `[ChatMessage]` to feed `me`'s LLM request from the canonical
    /// transcript. The model only ever sees a window (rolling summary + the
    /// last N verbatim turns); the full transcript stays app-side.
    static func renderPOV(
        turns: [EnsembleTurn],
        for me: Persona,
        rollingSummary: String = "",
        window: Int = 16
    ) -> [ChatMessage] {
        var out: [ChatMessage] = []

        // Coalesce consecutive non-me lines (other personas AND the user — both
        // map to the `user` role) into ONE message. Strict user/assistant
        // alternation is required by several local chat templates (Gemma,
        // Mistral): two `user` messages in a row — which happens the moment the
        // user interjects after a persona, or any time two other speakers go
        // back-to-back — makes those templates reject the whole prompt with a
        // "roles must alternate" error (the bug that flashed Data's turn).
        var userBlock: [String] = []
        func flushUserBlock() {
            guard !userBlock.isEmpty else { return }
            out.append(ChatMessage(role: .user, content: userBlock.joined(separator: "\n")))
            userBlock.removeAll(keepingCapacity: true)
        }

        if !rollingSummary.isEmpty {
            userBlock.append("Earlier in the conversation: \(rollingSummary)")
        }

        let windowed = Array(turns.suffix(max(0, window)))
        for turn in windowed {
            if turn.speakerID == me.id {
                // My own line — I am the assistant. Close any pending user block.
                flushUserBlock()
                var content = turn.content
                if turn.wasCutOff { content += "  [cut off]" }
                out.append(ChatMessage(role: .assistant, content: content))
            } else {
                // Another persona OR the user — a name-prefixed external line.
                var line = "\(turn.speakerName): \(turn.content)"
                if turn.wasCutOff { line += " [cut off]" }
                userBlock.append(line)
            }
        }
        flushUserBlock()

        // First turn of the scene — nothing to react to yet. Seed a concrete,
        // benign kickoff instead of an EMPTY messages array (which lets a weak
        // local model confabulate a request — occasionally a harmful one).
        if out.isEmpty {
            out.append(ChatMessage(role: .user, content: "You're opening the scene. Say your first line now — in character, on the established scene and topic, as one short spoken sentence."))
        }

        // Strict templates also require the FIRST message to be `user`. If the
        // window happens to start on my own line, lead with a tiny primer rather
        // than an illegal leading assistant message.
        if out.first?.role == .assistant {
            out.insert(ChatMessage(role: .user, content: "(continuing the conversation)"), at: 0)
        }

        // If my own line is the most recent, nudge for a NEW line rather than an
        // echo — and keep alternation (the trailing message stays `user`).
        if windowed.last?.speakerID == me.id {
            out.append(ChatMessage(role: .user, content: "(continue)"))
        }

        return out
    }

    /// Instance convenience used by the turn loop.
    func messagesForPersona(_ me: Persona) -> [ChatMessage] {
        // Render everything not yet folded into the rolling summary (at least the
        // verbatim window), capped at maxContextTurns so a stalled summarizer
        // can't blow the model's context window.
        let unsummarized = max(verbatimWindow, turns.count - summarizedUpTo)
        let effectiveWindow = min(unsummarized, max(verbatimWindow, Self.maxContextTurns))
        return Self.renderPOV(turns: turnsForModel(), for: me, rollingSummary: rollingSummary, window: effectiveWindow)
    }

    /// The transcript as the MODEL must see it: the user's display name ("You")
    /// is swapped for a non-pronoun proper noun (`userPeer.modelName`) so the
    /// model doesn't read "You" as the addressee's name and echo it back
    /// capitalized ("Your skepticism"). The raw `turns` — used by the transcript,
    /// export, and history — keep "You". Identity (no copy) when the two names
    /// already match, i.e. the user set a real name. Every model-facing path
    /// (POV, director, rolling summary) renders through this, so "You:" can never
    /// reach the model by construction.
    func turnsForModel() -> [EnsembleTurn] {
        guard userPeer.name != userPeer.modelName else { return turns }
        return turns.map { turn in
            guard turn.speakerID == nil else { return turn }
            var t = turn
            t.speakerName = userPeer.modelName
            return t
        }
    }

    // MARK: - Soft context dump (Director's Chair)

    /// Shrink what models see on the next turn without deleting the on-screen
    /// transcript. Keeps the last `verbatimWindow` turns verbatim, folds older
    /// material into a short rolling summary (scene/mood + brief line list),
    /// cancels any in-flight summarizer. Export / History still use full `turns`.
    @discardableResult
    func softDumpContext() -> Bool {
        guard !turns.isEmpty else {
            showNotice("Nothing to reset — transcript is empty")
            return false
        }
        summaryTask?.cancel()
        summaryTask = nil

        let keep = max(4, verbatimWindow)
        let before = turns.count
        if turns.count > keep {
            let dropped = Array(turns.prefix(turns.count - keep))
            rollingSummary = Self.buildSoftDumpBrief(
                droppedTurns: dropped,
                scene: scene,
                mood: mood,
                castNames: (cast + departedSpeakers).map(\.name)
            )
            summarizedUpTo = turns.count - keep
        } else {
            // Already short — just clear any bloated summary so the next call
            // is lean.
            rollingSummary = ""
            summarizedUpTo = 0
        }

        let kept = turns.count - summarizedUpTo
        showNotice("Context reset — models keep last \(kept) turns")
        presentContextDumpToast(
            "Context reset — last \(kept) of \(before) turns kept for the models"
        )
        return true
    }

    /// Compact “state of play” from turns that fall outside the new window.
    /// Pure/static for unit tests — no LLM call.
    static func buildSoftDumpBrief(
        droppedTurns: [EnsembleTurn],
        scene: String,
        mood: String,
        castNames: [String],
        maxLines: Int = 8,
        maxChars: Int = 600
    ) -> String {
        var parts: [String] = []
        let sceneTrim = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        let moodTrim = mood.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sceneTrim.isEmpty || !moodTrim.isEmpty {
            let sm = [sceneTrim.isEmpty ? nil : "scene: \(sceneTrim)",
                      moodTrim.isEmpty ? nil : "mood: \(moodTrim)"]
                .compactMap { $0 }
                .joined(separator: "; ")
            parts.append(sm)
        }
        if !castNames.isEmpty {
            parts.append("cast: " + castNames.joined(separator: ", "))
        }
        parts.append("Director reset context; continue in character from recent lines.")

        // Prefer the last few dropped lines (most relevant) over the oldest.
        let samples = droppedTurns
            .filter { !$0.isSceneBeat }
            .suffix(maxLines)
        for turn in samples {
            let body = turn.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !body.isEmpty else { continue }
            let clip = body.count > 80 ? String(body.prefix(77)) + "…" : body
            parts.append("\(turn.speakerName): \(clip)")
        }

        var brief = parts.joined(separator: " · ")
        if brief.count > maxChars {
            brief = String(brief.prefix(maxChars - 1)) + "…"
        }
        return brief
    }

    /// App-level toast for context dump (mirrors boot toast).
    private func presentContextDumpToast(_ message: String) {
        appState.toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if appState.toastMessage == message {
                appState.toastMessage = nil
            }
        }
    }
}
