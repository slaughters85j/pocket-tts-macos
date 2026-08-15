//
//  EnsembleViewModel+Threads.swift
//  mimika-ai-voice-studio
//
//  Ensemble persist / load / restart against ChatThreadStore. Restart
//  (Reuse Last) always creates a new thread from a cast snapshot.
//

import Foundation

extension EnsembleViewModel {

    // MARK: - Bind

    /// Bind the shared sidebar and show Ensemble rows.
    func attachThreadBrowser(_ browser: ChatThreadBrowser) {
        threadBrowser = browser
        browser.kind = .ensemble
        browser.reload()
    }

    // MARK: - Create / save

    /// Open a new thread (New Cast or Restart). Optional snapshot seeds
    /// the file so a restart has cast even before the first spoken line.
    func beginEnsembleThread(title: String, snapshot: EnsembleThreadPayload? = nil) {
        detachAfterFlushingCurrentThread()
        var record = ChatThreadStore.create(kind: .ensemble, title: title)
        record.ensemble = snapshot ?? currentCastSnapshot(turns: turns)
        record = ChatThreadStore.save(record)
        currentThreadID = record.id
        threadBrowser?.applySaved(record)
    }

    /// Persist the open thread with its *current* turns, then detach so the
    /// next mutation cannot overwrite that file.
    func detachAfterFlushingCurrentThread() {
        threadSaveTask?.cancel()
        flushEnsembleThreadSave()
        currentThreadID = nil
    }

    func noteEnsembleThreadActivity() {
        if currentThreadID == nil {
            beginEnsembleThread(
                title: scene.isEmpty ? "New ensemble" : scene,
                snapshot: currentCastSnapshot(turns: turns)
            )
            requestEnsembleThemeIfNeeded()
        } else {
            scheduleEnsembleThreadSave()
        }
    }

    func scheduleEnsembleThreadSave() {
        threadSaveTask?.cancel()
        threadSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.flushEnsembleThreadSave()
            self.requestEnsembleThemeIfNeeded()
        }
    }

    func flushEnsembleThreadSave() {
        guard let id = currentThreadID else { return }
        var record = ChatThreadStore.load(id: id, kind: .ensemble)
            ?? ChatThreadRecord(id: id, kind: .ensemble)
        record.ensemble = currentCastSnapshot(turns: turns)
        record.title = ensembleThreadTitle()
        record.pinned = threadBrowser?.entries.first(where: { $0.id == id })?.pinned ?? record.pinned
        record = ChatThreadStore.save(record)
        threadBrowser?.applySaved(record)
    }

    func currentCastSnapshot(turns: [EnsembleTurn]) -> EnsembleThreadPayload {
        EnsembleThreadPayload(
            scene: scene,
            mood: mood,
            userPeer: userPeer,
            userCharacterRoster: userCharacterRoster,
            cast: cast,
            departedSpeakers: departedSpeakers,
            turns: turns
        )
    }

    // MARK: - Load / restart helpers

    func loadEnsembleThread(id: UUID) {
        stop()
        if currentThreadID != id {
            detachAfterFlushingCurrentThread()
        }
        guard let record = ChatThreadStore.load(id: id, kind: .ensemble),
              let payload = record.ensemble
        else {
            showNotice("Couldn't open that thread")
            return
        }
        applyCastSnapshot(payload, resetTurns: false)
        currentThreadID = record.id
        threadBrowser?.select(record.id)
    }

    func applyCastSnapshot(_ payload: EnsembleThreadPayload, resetTurns: Bool) {
        stop()
        scene = payload.scene
        mood = payload.mood
        userPeer = payload.userPeer
        userCharacterRoster = payload.userCharacterRoster
        seedUserCharacterRosterFromActivePeer()
        cast = payload.cast
        departedSpeakers = payload.departedSpeakers
        if resetTurns {
            turns = []
        } else {
            turns = payload.turns
        }
        rollingSummary = ""
        summarizedUpTo = 0
        summaryTask?.cancel(); summaryTask = nil
        shuffledOrder = []
        orderCursor = 0
        producedThisRun = 0
        pendingBoot = nil
        pendingDirective = nil
        lastDepartureNote = nil
    }

    func detachIfShowing(_ id: UUID) {
        guard currentThreadID == id else { return }
        currentThreadID = nil
        stop()
        turns = []
    }

    func selectedThreadCastSnapshot() -> EnsembleThreadPayload? {
        guard let id = threadBrowser?.selectedID ?? currentThreadID,
              let record = ChatThreadStore.load(id: id, kind: .ensemble)
        else { return nil }
        return record.ensemble
    }

    // MARK: - Theme

    func requestEnsembleThemeIfNeeded() {
        guard let id = currentThreadID else { return }
        let existing = threadBrowser?.entries.first(where: { $0.id == id })?.theme ?? ""
        guard existing.isEmpty else { return }
        let spoken = turns.filter { !$0.isSceneBeat && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard spoken.count >= 2 else { return }
        let source = ChatThreadStore.themeSourceText(from: turns)
        let model = resolvedModel
        guard !model.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await makeClient().completeChat(
                    messages: [ChatMessage(role: .user, content: source)],
                    model: model,
                    systemPrompt: ChatThreadStore.themeSystemPrompt,
                    temperature: 0.3
                )
                let theme = ChatThreadStore.cleanedTheme(raw)
                guard !theme.isEmpty, self.currentThreadID == id else { return }
                ChatThreadStore.updateTheme(id: id, kind: .ensemble, theme: theme)
                self.threadBrowser?.reload()
            } catch {}
        }
    }

    private func ensembleThreadTitle() -> String {
        let sceneBit = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sceneBit.isEmpty { return String(sceneBit.prefix(48)) }
        if let first = turns.first(where: {
            !$0.isSceneBeat && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return String(first.content.prefix(48))
        }
        return "New ensemble"
    }
}
