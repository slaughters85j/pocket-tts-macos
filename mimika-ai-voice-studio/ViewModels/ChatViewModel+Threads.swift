//
//  ChatViewModel+Threads.swift
//  mimika-ai-voice-studio
//
//  Solo Chat persist / load / new-thread against ChatThreadStore.
//

import Foundation

extension ChatViewModel {

    // MARK: - Lifecycle

    /// Bind the shared sidebar and show Solo rows.
    func attachThreadBrowser(_ browser: ChatThreadBrowser) {
        threadBrowser = browser
        browser.kind = .solo
        browser.reload()
    }

    /// Create a thread on first real content; debounce-save afterwards.
    /// Mint the id on-thread and persist off-main — never `ioQueue.sync` here.
    func noteSoloThreadActivity() {
        if currentThreadID == nil {
            var record = ChatThreadRecord(
                kind: .solo,
                title: soloThreadTitle(from: messages)
            )
            record.soloMessages = messages
            currentThreadID = record.id
            threadBrowser?.applySaved(record)
            threadBrowser?.select(record.id)
            let browser = threadBrowser
            ChatThreadStore.saveAsync(record) { saved in
                browser?.applySaved(saved)
            }
            requestSoloThemeIfNeeded()
        } else {
            scheduleSoloThreadSave()
        }
    }

    /// Detach the live session so the next send starts a new thread.
    func beginFreshSoloThread() {
        threadSaveTask?.cancel()
        flushSoloThreadSave()
        currentThreadID = nil
        threadBrowser?.select(nil)
    }

    /// User-facing New Chat: park the current thread, empty the transcript.
    func startNewSoloConversation() {
        guard activeTurn == nil else {
            showToast("Please wait until the model finishes responding.")
            return
        }
        beginFreshSoloThread()
        messages.removeAll()
        pendingAttachments = []
        previewAttachment = nil
        showsVisionRecovery = false
        deferredVisionRecovery = false
        lastAutomaticVisionRecoveryKey = nil
        status = .idle
    }

    /// Drop live state if the open thread was deleted from the sidebar.
    func detachIfShowing(_ id: UUID) {
        guard currentThreadID == id else { return }
        threadSaveTask?.cancel()
        threadSaveTask = nil
        currentThreadID = nil
        messages.removeAll()
        pendingAttachments = []
        previewAttachment = nil
        status = .idle
    }

    /// Persist then restore a Solo thread's transcript.
    func loadSoloThread(id: UUID) {
        #if DEBUG
        print("[ChatThreads] solo load begin id=\(id.uuidString.prefix(8)) current=\(currentThreadID?.uuidString.prefix(8) ?? "nil") activeTurn=\(activeTurn != nil)")
        #endif
        guard activeTurn == nil else {
            #if DEBUG
            print("[ChatThreads] solo load blocked — model still responding")
            #endif
            showToast("Please wait until the model finishes responding.")
            return
        }
        flushSoloThreadSave()
        threadBrowser?.select(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let record = await ChatThreadStore.loadAsync(id: id, kind: .solo) else {
                #if DEBUG
                print("[ChatThreads] solo load missing file id=\(id.uuidString.prefix(8)) stillSelected=\(self.threadBrowser?.selectedID == id)")
                #endif
                guard self.threadBrowser?.selectedID == id else { return }
                self.showToast("Couldn't open that thread")
                return
            }
            guard self.threadBrowser?.selectedID == id else {
                #if DEBUG
                print("[ChatThreads] solo load stale — dropped id=\(id.uuidString.prefix(8)) nowSelected=\(self.threadBrowser?.selectedID?.uuidString.prefix(8) ?? "nil")")
                #endif
                return
            }
            self.messages = record.soloMessages
            self.pendingAttachments = []
            self.previewAttachment = nil
            self.showsVisionRecovery = false
            self.currentThreadID = record.id
            self.status = .idle
            #if DEBUG
            print("[ChatThreads] solo load applied id=\(record.id.uuidString.prefix(8)) title=\(record.title) messages=\(record.soloMessages.count)")
            #endif
        }
    }

    // MARK: - Save

    private func scheduleSoloThreadSave() {
        threadSaveTask?.cancel()
        threadSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.flushSoloThreadSave()
        }
    }

    private func flushSoloThreadSave() {
        guard let id = currentThreadID else { return }
        let entry = threadBrowser?.entries.first(where: { $0.id == id })
        var record = ChatThreadRecord(id: id, kind: .solo)
        record.theme = entry?.theme ?? ""
        record.createdAt = entry?.createdAt ?? record.createdAt
        record.soloMessages = messages
        record.pinned = entry?.pinned ?? record.pinned
        // A user rename wins over the title derived from the first message.
        if entry?.titleIsCustom == true, let custom = entry?.title, !custom.isEmpty {
            record.title = custom
            record.titleIsCustom = true
        } else {
            record.title = soloThreadTitle(from: messages)
        }
        let browser = threadBrowser
        ChatThreadStore.saveAsync(record) { saved in
            browser?.applySaved(saved)
        }
        requestSoloThemeIfNeeded()
    }

    private func soloThreadTitle(from messages: [ChatMessage]) -> String {
        let first = messages.first {
            $0.role == .user
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, !first.isEmpty else { return "New chat" }
        return String(first.prefix(48))
    }

    // MARK: - Theme

    private func requestSoloThemeIfNeeded() {
        guard let id = currentThreadID else { return }
        let existing = threadBrowser?.entries.first(where: { $0.id == id })?.theme ?? ""
        guard existing.isEmpty else { return }
        let usable = messages.filter {
            $0.role != .system
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard usable.count >= 2 else { return }
        guard activeTurn == nil else { return }
        // One at a time. Without this, a theme call that fails or returns empty
        // leaves `existing` empty, so the NEXT turn starts another one — and a
        // local server serves a single generation at a time, so those pile up in
        // front of the user's next turn and delay its first token (and therefore
        // the first spoken sentence). The catch below is silent, so nothing
        // surfaces it. Cancel-and-replace instead of stacking.
        guard themeTask == nil else { return }
        let source = ChatThreadStore.themeSourceText(from: messages)
        let model = soloThemeModel
        guard !model.isEmpty else { return }
        themeTask = Task { [weak self] in
            defer { self?.themeTask = nil }
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
                ChatThreadStore.updateTheme(id: id, kind: .solo, theme: theme)
                self.threadBrowser?.reload()
            } catch {
                // Theme is decorative — never block the session. Logged so a
                // persistently failing theme model is visible rather than silent.
                #if DEBUG
                print("[ChatThreads] solo theme failed: \(error)")
                #endif
            }
        }
    }

    /// Stop a decorative theme request from holding the local model's single
    /// generation slot while the user is trying to take a turn.
    func cancelSoloThemeRequest() {
        themeTask?.cancel()
        themeTask = nil
    }

    private var soloThemeModel: String {
        if case let .connected(model) = connectionState { return model }
        return settings.model
    }
}
