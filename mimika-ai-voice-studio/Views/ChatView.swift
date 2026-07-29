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
    @State private var showsResetConfirmation = false
    @State private var isAudioMuted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(Theme.borderColor)
            if subMode == .solo {
                if viewModel.viewMode == .orb {
                    OrbView(amplitudeSource: player.currentAmplitude)
                        .background(Color.black)
                } else {
                    transcript
                }
                Divider().background(Theme.borderColor)
                ChatComposerView(viewModel: viewModel)
            } else {
                EnsembleSurfaceView(
                    viewModel: ensembleViewModel,
                    player: player,
                    viewMode: ensembleViewMode
                )
            }
        }
        .onAppear {
            if subMode == .solo { viewModel.startHealthChecks() }
            Task { isAudioMuted = await player.isMuted }
        }
        .onDisappear { viewModel.stopSoloChatSession() }
        .onChange(of: subMode) { _, mode in
            if mode == .solo {
                viewModel.startHealthChecks()
            } else {
                viewModel.stopHealthChecks()
            }
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
        .sheet(item: $viewModel.previewAttachment) { attachment in
            ChatImagePreviewView(
                attachment: attachment,
                close: { viewModel.previewAttachment = nil }
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

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.space3) {
            Picker("", selection: $subMode) {
                Text("Solo").tag(ChatSubMode.solo)
                Text("Ensemble").tag(ChatSubMode.ensemble)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("chat.subModeToggle")

            ConnectionStatusPill(
                state: subMode == .solo
                    ? viewModel.connectionState
                    : ensembleViewModel.connectionState
            )

            if subMode == .solo {
                ModelCapabilityBadges(state: viewModel.capabilityState)
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
                ensembleControls
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

    @ViewBuilder
    private var ensembleControls: some View {
        if let color = ensembleSpeakerColor {
            Circle().fill(color).frame(width: 8, height: 8)
        }
        Text(ensembleStatusText)
            .font(Theme.fontXS)
            .foregroundStyle(Theme.textSecondary)

        if ensembleViewModel.canExport {
            Button(action: { ensembleViewModel.saveTranscript() }) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Export transcript (.md)")
            .accessibilityIdentifier("ensemble.saveTranscript")

            Button(action: { ensembleViewModel.saveEpisodeToHistory() }) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Save episode to History")
            .accessibilityIdentifier("ensemble.saveHistory")

            Button(action: { ensembleViewModel.openInMultiTalk() }) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open episode in Multi-Talk")
            .accessibilityIdentifier("ensemble.openMultiTalk")
        }

        Button(action: { ensembleViewMode = ensembleViewMode == .orb ? .transcript : .orb }) {
            Image(systemName: ensembleViewMode == .orb ? "list.bullet" : "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(ensembleViewMode == .orb ? "Show transcript" : "Show orb")
        .accessibilityIdentifier("ensemble.viewModeToggle")

        if !ensembleViewModel.cast.isEmpty {
            Button(action: { showsEnsembleCastEditor = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Edit cast voices & delivery")
            .accessibilityIdentifier("ensemble.editCast")
        }

        if ensembleViewModel.hasSavedCast {
            Button(action: { ensembleViewModel.reuseLastCast() }) {
                Label("Reuse Last", systemImage: "clock.arrow.circlepath")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Reload your most recent cast")
            .accessibilityIdentifier("ensemble.reuseLast")
        }

        Button(action: { showsEnsembleSetup = true }) {
            Label("New Cast", systemImage: "person.3.sequence.fill")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help("Generate a new cast with the persona-writer")
        .accessibilityIdentifier("ensemble.newCast")
    }

    private var ensembleStatusText: String {
        switch ensembleViewModel.runState {
        case .idle: return "Idle"
        case .picking: return "Choosing next speaker…"
        case .generating: return "\(ensembleViewModel.currentSpeakerName ?? "Someone") is thinking…"
        case .speaking: return "\(ensembleViewModel.currentSpeakerName ?? "Someone") is talking…"
        case .awaitingStep: return "Paused — Step or Resume"
        case .userTurn: return "Your turn…"
        case let .error(message): return "Error: \(message)"
        }
    }

    private var ensembleSpeakerColor: Color? {
        guard
            let id = ensembleViewModel.currentSpeakerID,
            let index = ensembleViewModel.cast.firstIndex(where: { $0.id == id })
        else { return nil }
        return Theme.speakerColor(at: index)
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
                            onPreviewImage: { viewModel.previewAttachment = $0 }
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
