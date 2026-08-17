//
//  ChatViewChrome.swift
//  mimika-ai-voice-studio
//
//  Toolbar chips, export controls, run status and the workspace container for
//  ChatView. Split out of ChatView.swift, which had grown past the 400-line
//  limit with a self-contained block of chrome at its tail.
//
//  Every type here exists for ONE reason: its own Observation scope. Chat's
//  toolbar reads connection state, run state and `canExport`, all of which
//  change on a 1 s poll or on every streamed token. Inlined in ChatView's body
//  they rebuilt the sidebar and the Director's Chair's Liquid Glass with them.
//  Keep them separate, and keep `turns` out of anything but EnsembleExportControls.
//

import SwiftUI

// MARK: - Workspace (own Observation scope)

/// Transcript + Chair. Isolated so ChatView toolbar/sidebar invalidation
/// cannot rebuild Liquid Glass, and so the Chair is not handed a fresh
/// collapse closure on every token.
struct ChatWorkspace: View {
    @Bindable var ensembleViewModel: EnsembleViewModel
    let player: StreamingPlayer
    let ensembleViewMode: ViewMode
    @Binding var showsDirectorsChair: Bool

    var body: some View {
        ZStack(alignment: .top) {
            EnsembleSurfaceView(
                viewModel: ensembleViewModel,
                player: player,
                viewMode: ensembleViewMode
            )
            if showsDirectorsChair {
                DirectorsChairPanel(
                    viewModel: ensembleViewModel,
                    isPresented: $showsDirectorsChair
                )
                .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.5), value: showsDirectorsChair)
    }
}

// MARK: - Isolated toolbar chips

/// Own Observation scope so connection polls do not rebuild ChatView (Chair glass).
struct ChatConnectionPill: View {
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
struct EnsembleReasoningLock: View {
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

/// Trailing Ensemble chrome. Nothing here may read `turns` — that fires on every
/// streamed token and would rebuild the sidebar + Director's Chair glass with it.
/// `canExport` is quarantined in `EnsembleExportControls`.
struct EnsembleToolbarControls: View {
    @Bindable var viewModel: EnsembleViewModel
    @Bindable var browser: ChatThreadBrowser
    @Binding var viewMode: ViewMode
    @Binding var showsSetup: Bool
    @Binding var showsCastEditor: Bool
    var onOpenMultiTalk: () -> Void

    var body: some View {
        EnsembleRunStatusLabel(viewModel: viewModel)
        EnsembleExportControls(viewModel: viewModel, onOpenMultiTalk: onOpenMultiTalk)

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

// MARK: - Ensemble export chrome (isolated)

/// Own Observation scope for `canExport`, which reads `turns` and re-runs
/// TextNormalizer. Sharing a body with the rest of the toolbar meant every
/// streamed token re-evaluated all of it.
struct EnsembleExportControls: View {
    @Bindable var viewModel: EnsembleViewModel
    var onOpenMultiTalk: () -> Void

    var body: some View {
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
    }
}

// MARK: - Ensemble run status (isolated)

/// Own Observation scope so `runState` / speaker updates do not rebuild the Chat toolbar.
struct EnsembleRunStatusLabel: View {
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
