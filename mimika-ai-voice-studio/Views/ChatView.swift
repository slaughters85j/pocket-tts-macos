//
//  ChatView.swift
//  mimika-ai-voice-studio
//

import SwiftUI

// MARK: - Chat

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var ensembleViewModel: EnsembleViewModel
    @Binding var subMode: ChatSubMode
    let player: StreamingPlayer
    let voices: [BundledVoice]
    let appState: AppState
    let onOpenSettings: () -> Void
    var onOpenInMultiTalk: ((PendingReuse) -> Void)?

    @State private var ensembleViewMode: ViewMode = .transcript
    @State private var showsEnsembleSetup = false
    @State private var showsEnsembleCastEditor = false
    @State private var showsMultiTalkVoiceMap = false
    @State private var showsDirectorsChair = false
    /// Keep the glass card in the tree after first open so reopen skips layout.
    @State private var chairMounted = false
    @State private var showsResetConfirmation = false
    @State private var isAudioMuted = false
    @State private var editingMessage: ChatMessage?
    @State private var threadBrowser = ChatThreadBrowser()

    var body: some View {
        HStack(spacing: 0) {
            if !threadBrowser.isCollapsed {
                ChatThreadSidebar(
                    browser: threadBrowser,
                    onSelect: openThread,
                    onDeleted: detachIfDeleted,
                    onNew: subMode == .solo
                        ? { viewModel.startNewSoloConversation() }
                        : nil
                )
                Divider().background(Theme.borderColor)
            }
            VStack(spacing: 0) {
                topBar
                Divider().background(Theme.borderColor)
                // Transcript/composer stay full-height; the Chair floats over them
                // (sketch: ZStack overlay + glass, not a layout-pushing strip).
                ZStack(alignment: .top) {
                    mainChatSurface
                    if chairMounted {
                        DirectorsChairPanel(viewModel: ensembleViewModel) {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                showsDirectorsChair = false
                            }
                        }
                        .opacity(subMode == .ensemble && showsDirectorsChair ? 1 : 0)
                        .allowsHitTesting(subMode == .ensemble && showsDirectorsChair)
                        .zIndex(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.5), value: showsDirectorsChair)
            }
        }
        .onChange(of: subMode) { _, newMode in
            // Solo and Ensemble keep separate thinking defaults/stores;
            // refresh the shared control when the user flips the sub-mode.
            viewModel.refreshReasoningForChatSubMode()
            if newMode != .ensemble {
                showsDirectorsChair = false
            }
            attachThreads(for: newMode)
        }
        .onAppear {
            viewModel.startHealthChecks()
            // Land on the mode-scoped thinking default (Ensemble → Off).
            viewModel.refreshReasoningForChatSubMode()
            attachThreads(for: subMode)
            Task { isAudioMuted = await player.isMuted }
        }
        .onDisappear {
            viewModel.stopSoloChatSession()
            // Mute is Chat-only chrome. Leaving the tab (→ Single Voice /
            // Multi-Talk / …) must clear it or the shared player stays silent
            // with no indicator on the other tabs.
            isAudioMuted = false
            Task { await player.setMuted(false) }
        }
        .sheet(isPresented: $showsEnsembleSetup) {
            EnsembleSetupView(
                viewModel: ensembleViewModel,
                voices: voices,
                appState: appState,
                onDone: { showsEnsembleSetup = false }
            )
        }
        .sheet(isPresented: $showsEnsembleCastEditor) {
            EnsembleCastEditorSheet(
                viewModel: ensembleViewModel,
                voices: voices,
                onClose: { showsEnsembleCastEditor = false }
            )
        }
        .sheet(isPresented: $showsMultiTalkVoiceMap) {
            EnsembleMultiTalkVoiceMapSheet(
                viewModel: ensembleViewModel,
                voices: voices,
                onCancel: { showsMultiTalkVoiceMap = false },
                onConfirm: {
                    showsMultiTalkVoiceMap = false
                    ensembleViewModel.openInMultiTalk(
                        userVoiceMap: ensembleViewModel.multiTalkUserVoiceDraft
                    )
                }
            )
        }
        .sheet(item: $viewModel.previewAttachment) { attachment in
            ChatImagePreviewView(
                attachment: attachment,
                close: { viewModel.previewAttachment = nil }
            )
        }
        .sheet(item: $editingMessage) { message in
            ChatMessageEditorSheet(
                message: message,
                onCancel: { editingMessage = nil },
                onSave: { content in
                    viewModel.updateTranscriptMessage(
                        id: message.id,
                        content: content
                    )
                    editingMessage = nil
                }
            )
        }
        .confirmationDialog(
            viewModel.visionRecoveryDialogTitle,
            isPresented: $viewModel.showsVisionRecovery,
            titleVisibility: .visible
        ) {
            Button("Start New Chat", role: .destructive) {
                viewModel.startNewChatForVisionRecovery()
            }
            Button("Strip Image History", role: .destructive) {
                viewModel.stripImageHistory()
            }
            Button("Revert Model") {
                viewModel.revertToPreviousVisionModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how to handle images already sent to the previous Vision model.")
        }
        .alert("Clear Chat?", isPresented: $showsResetConfirmation) {
            Button("Clear Chat", role: .destructive) {
                viewModel.resetTranscript()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every message in the current chat.")
        }
    }

    // MARK: - Main surface (under Director's Chair overlay)

    @ViewBuilder
    private var mainChatSurface: some View {
        if subMode == .solo {
            VStack(spacing: 0) {
                if viewModel.viewMode == .orb {
                    OrbView(amplitudeSource: player.currentAmplitude)
                        .background(Color.black)
                } else {
                    transcript
                }
                Divider().background(Theme.borderColor)
                ChatComposerView(viewModel: viewModel)
            }
        } else {
            EnsembleSurfaceView(
                viewModel: ensembleViewModel,
                player: player,
                viewMode: ensembleViewMode
            )
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.space3) {
            Button {
                threadBrowser.isCollapsed.toggle()
            } label: {
                Image(systemName: threadBrowser.isCollapsed
                      ? "sidebar.left"
                      : "sidebar.leading")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(threadBrowser.isCollapsed ? "Show threads" : "Hide threads")
            .accessibilityIdentifier("chat.threads.toggle")

            Picker("", selection: $subMode) {
                Text("Solo").tag(ChatSubMode.solo)
                Text("Ensemble").tag(ChatSubMode.ensemble)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("chat.subModeToggle")

            ChatConnectionPill(
                solo: viewModel,
                ensemble: ensembleViewModel,
                isEnsemble: subMode == .ensemble
            )

            ModelCapabilityBadges(state: viewModel.capabilityState)
            EnsembleReasoningLock(
                chat: viewModel,
                ensemble: ensembleViewModel,
                isEnsemble: subMode == .ensemble
            )

            // Ensemble-only: live run knobs without leaving the conversation.
            if subMode == .ensemble {
                DirectorsChairToggleButton(isOpen: chairOpenBinding)
            }

            Spacer()

            Button(action: toggleAudioMute) {
                Image(systemName: isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(isAudioMuted ? "Unmute audio" : "Mute audio")
            .accessibilityLabel(isAudioMuted ? "Unmute audio" : "Mute audio")
            .accessibilityIdentifier("chat.audioMute")

            if subMode == .solo {
                soloControls
            } else {
                EnsembleToolbarControls(
                    viewModel: ensembleViewModel,
                    browser: threadBrowser,
                    viewMode: $ensembleViewMode,
                    showsSetup: $showsEnsembleSetup,
                    showsCastEditor: $showsEnsembleCastEditor,
                    onOpenMultiTalk: openEnsembleInMultiTalk
                )
            }
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
    }

    /// Toggles the shared player output used by both Solo and Ensemble.
    private func toggleAudioMute() {
        Task {
            isAudioMuted = await player.toggleMuted()
        }
    }

    @ViewBuilder
    private var soloControls: some View {
        Button(action: { viewModel.startNewSoloConversation() }) {
            Label("New Chat", systemImage: "square.and.pencil")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.hasActiveTurn)
        .help("Start a new Solo thread. The current conversation stays in the list.")
        .accessibilityIdentifier("chat.newThread")

        Button(action: { viewModel.saveTranscript() }) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSaveTranscript)
        .help("Save transcript")

        Button(action: { onOpenInMultiTalk?(viewModel.multiTalkPayload()) }) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canOpenInMultiTalk)
        .help("Open in Multi-Talk")

        Button(action: { showsResetConfirmation = true }) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.messages.isEmpty || viewModel.hasActiveTurn)
        .help("Clear chat")
        .accessibilityIdentifier("chat.clearTranscript")

        Button(action: { viewModel.toggleViewMode() }) {
            Image(systemName: viewModel.viewMode == .orb ? "list.bullet" : "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(viewModel.viewMode == .orb ? "Show transcript" : "Show orb")
        .accessibilityIdentifier("chat.viewModeToggle")

        Button(action: { Task { await viewModel.checkConnection() } }) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Refresh connection")

        Button(action: onOpenSettings) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityIdentifier("settings.openButton")
    }

    // MARK: Ensemble controls

    /// First open mounts the Chair; later toggles only flip visibility.
    private var chairOpenBinding: Binding<Bool> {
        Binding(
            get: { showsDirectorsChair },
            set: { newValue in
                if newValue { chairMounted = true }
                showsDirectorsChair = newValue
            }
        )
    }



    private func attachThreads(for mode: ChatSubMode) {
        if mode == .solo {
            viewModel.attachThreadBrowser(threadBrowser)
        } else {
            ensembleViewModel.attachThreadBrowser(threadBrowser)
        }
    }

    private func detachIfDeleted(_ entry: ChatThreadIndexEntry) {
        viewModel.detachIfShowing(entry.id)
        ensembleViewModel.detachIfShowing(entry.id)
    }

    private func openThread(_ entry: ChatThreadIndexEntry) {
        #if DEBUG
        let current = entry.kind == .solo
            ? viewModel.currentThreadID
            : ensembleViewModel.currentThreadID
        print("[ChatThreads] click kind=\(entry.kind.rawValue) title=\(entry.title) id=\(entry.id.uuidString.prefix(8)) selected=\(threadBrowser.selectedID?.uuidString.prefix(8) ?? "nil") current=\(current?.uuidString.prefix(8) ?? "nil") same=\(current == entry.id)")
        #endif
        switch entry.kind {
        case .solo:
            viewModel.loadSoloThread(id: entry.id)
        case .ensemble:
            ensembleViewModel.loadEnsembleThread(id: entry.id)
        }
    }

    /// Map human character aliases to voices, then hand the episode to Multi-Talk.
    /// Cast-only episodes (no user lines) skip the sheet.
    private func openEnsembleInMultiTalk() {
        if ensembleViewModel.prepareMultiTalkVoiceMap() {
            showsMultiTalkVoiceMap = true
        } else {
            ensembleViewModel.openInMultiTalk()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.space3) {
                    if viewModel.messages.isEmpty {
                        Text("Send a message to start chatting. Replies will be spoken in the selected voice as they stream in.")
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, Theme.space6 * 2)
                            .padding(.horizontal, Theme.space6)
                    }
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            isResponding: viewModel.activeTurn?.assistantMessageID == message.id,
                            canModify: !viewModel.hasActiveTurn,
                            onPreviewImage: { viewModel.previewAttachment = $0 },
                            onEdit: { editingMessage = $0 },
                            onDelete: { viewModel.deleteTranscriptMessage(id: $0) }
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: 4).id("tail")
                }
                .padding(.horizontal, Theme.space6)
                .padding(.vertical, Theme.space4)
            }
            .onChange(of: viewModel.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("tail", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("tail", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
        .background(Theme.bgPrimary)
    }
}

// MARK: - Isolated toolbar chips

/// Own Observation scope so connection polls do not rebuild ChatView (Chair glass).
private struct ChatConnectionPill: View {
    @Bindable var solo: ChatViewModel
    @Bindable var ensemble: EnsembleViewModel
    let isEnsemble: Bool

    var body: some View {
        ConnectionStatusPill(
            state: isEnsemble ? ensemble.connectionState : solo.connectionState
        )
    }
}

/// Own Observation scope so `runState` / `isRunning` do not rebuild ChatView.
private struct EnsembleReasoningLock: View {
    @Bindable var chat: ChatViewModel
    @Bindable var ensemble: EnsembleViewModel
    let isEnsemble: Bool

    var body: some View {
        ModelReasoningControl(
            viewModel: chat,
            isExternallyLocked: isEnsemble && ensemble.isRunning
        )
    }
}

/// Trailing Ensemble chrome. `canExport` reads `turns` — must not live in ChatView.body
/// or every token rebuilds the sidebar + Director's Chair glass.
private struct EnsembleToolbarControls: View {
    @Bindable var viewModel: EnsembleViewModel
    @Bindable var browser: ChatThreadBrowser
    @Binding var viewMode: ViewMode
    @Binding var showsSetup: Bool
    @Binding var showsCastEditor: Bool
    var onOpenMultiTalk: () -> Void

    var body: some View {
        EnsembleRunStatusLabel(viewModel: viewModel)

        if viewModel.canExport {
            Button(action: { viewModel.saveTranscript() }) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Export transcript (.md)")
            .accessibilityIdentifier("ensemble.saveTranscript")

            Button(action: onOpenMultiTalk) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open episode in Multi-Talk — map your character voices first")
            .accessibilityIdentifier("ensemble.openMultiTalk")
        }

        Button(action: { viewMode = viewMode == .orb ? .transcript : .orb }) {
            Image(systemName: viewMode == .orb ? "list.bullet" : "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(viewMode == .orb ? "Show transcript" : "Show orb")
        .accessibilityIdentifier("ensemble.viewModeToggle")

        if !viewModel.cast.isEmpty {
            Button(action: { showsCastEditor = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Edit cast, voices, scene & mood")
            .accessibilityIdentifier("ensemble.editCast")
        }

        if viewModel.hasSavedCast || browser.selectedID != nil {
            Button(action: { viewModel.reuseLastCast() }) {
                Label("Reuse Last", systemImage: "clock.arrow.circlepath")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help(reuseLastHelp)
            .accessibilityIdentifier("ensemble.reuseLast")
        }

        Button(action: { showsSetup = true }) {
            Label("New Cast", systemImage: "person.3.sequence.fill")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help("Generate a new cast with the persona-writer")
        .accessibilityIdentifier("ensemble.newCast")
    }

    private var reuseLastHelp: String {
        let scene = viewModel.scene.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = viewModel.cast.map(\.name).joined(separator: ", ")
        if scene.isEmpty && names.isEmpty {
            return "Restart this cast in a new thread — the current thread stays as history"
        }
        if scene.isEmpty {
            return "Restart — \(names)"
        }
        return "Restart — \(names). Scene: \(scene)"
    }
}

// MARK: - Ensemble run status (isolated)

/// Own Observation scope so `runState` / speaker updates do not rebuild the Chat toolbar.
private struct EnsembleRunStatusLabel: View {
    @Bindable var viewModel: EnsembleViewModel

    var body: some View {
        HStack(spacing: Theme.space3) {
            if let color = speakerColor {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var statusText: String {
        switch viewModel.runState {
        case .idle: return "Idle"
        case .picking: return "Choosing next speaker…"
        case .generating: return "\(viewModel.currentSpeakerName ?? "Someone") is thinking…"
        case .speaking: return "\(viewModel.currentSpeakerName ?? "Someone") is talking…"
        case .awaitingStep: return "Paused — Step or Resume"
        case .userTurn: return "Your turn…"
        case let .error(message): return "Error: \(message)"
        }
    }

    private var speakerColor: Color? {
        guard
            let id = viewModel.currentSpeakerID,
            let index = viewModel.cast.firstIndex(where: { $0.id == id })
        else { return nil }
        return Theme.speakerColor(at: index)
    }
}
