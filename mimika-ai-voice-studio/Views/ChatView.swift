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
                .fixedSize(horizontal: true, vertical: false)
                Divider().background(Theme.borderColor)
            }
            VStack(spacing: 0) {
                topBar
                Divider().background(Theme.borderColor)
                if subMode == .solo {
                    mainChatSurface
                } else {
                    // Own view so token/toolbar Observation cannot recreate glass.
                    ChatWorkspace(
                        ensembleViewModel: ensembleViewModel,
                        player: player,
                        ensembleViewMode: ensembleViewMode,
                        showsDirectorsChair: $showsDirectorsChair
                    )
                }
            }
            // REQUIRED, not cosmetic. Without a flexible frame this VStack's ideal
            // width depends on its whole subtree, so the enclosing HStack probes it
            // with several proposals — and every probe re-measures the top bar, the
            // transcript, AND the Director's Chair's ~10 AppKit controls. That is
            // what made the sidebar poison app-wide performance: collapsing the
            // sidebar left one HStack child and the stall vanished. Taking the
            // proposal verbatim ends the search at one pass.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                content: message.content,
                allowsEmpty: !message.attachments.isEmpty,
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

    // MARK: - Main surface

    /// Solo only — Ensemble's transcript lives in `ChatWorkspace` with the Chair.
    private var mainChatSurface: some View {
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
                DirectorsChairToggleButton(isOpen: $showsDirectorsChair)
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

// The workspace container, toolbar chips, export controls and run-status label live in
// `ChatViewChrome.swift`. Each is a separate view for its own Observation scope — see that file.

