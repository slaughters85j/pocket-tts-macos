//
//  EnsembleSettingsView.swift
//  mimika-ai-voice-studio
//
//  Ensemble run knobs (turn order, pace, limits, context, scene play). Hosted
//  in the Director's Chair panel on the Ensemble toolbar so they stay
//  reachable mid-run. Cast & Settings keeps roster / scene-mood / voices only.
//
//  WP-CAST-1: info.circle popovers on every setting; Turn order + Randomness
//  bodies are context-aware to the current picker values.
//

import SwiftUI

// MARK: - EnsembleSettingsView

struct EnsembleSettingsView: View {
    @Bindable var viewModel: EnsembleViewModel
    /// When false, skip the "RUN SETTINGS" caption (Director's Chair supplies its own header).
    var showsSectionTitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            if showsSectionTitle {
                Text("RUN SETTINGS").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            }

            // The model is configured once in App Settings (Local LLM Endpoint),
            // not here — one source of truth, no per-cast override.
            row("Turn order", helpTitle: "Turn order", helpBody: turnOrderHelp,
                accessibilityID: "ensemble.settings.help.turnOrder") {
                Picker("", selection: $viewModel.turnOrder) {
                    ForEach(TurnMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            row("Randomness", helpTitle: "Randomness", helpBody: randomnessHelp,
                accessibilityID: "ensemble.settings.help.randomness") {
                Picker("", selection: $viewModel.rngMode) {
                    Text("Shuffle once").tag(RNGMode.shuffleOnce)
                    Text("Reroll each turn").tag(RNGMode.rerollPerTurn)
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                // Conductor only consults RNG for Round Robin seat order.
                // Director / Weighted Random ignore it — grey the control out.
                .disabled(!randomnessApplies)
                .opacity(randomnessApplies ? 1 : 0.45)
            }
            row("Scene play", helpTitle: "Scene play", helpBody: scenePlayHelp,
                accessibilityID: "ensemble.settings.help.scenePlay") {
                Picker("", selection: $viewModel.scenePlayMode) {
                    ForEach(ScenePlayMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            row("Pace", helpTitle: "Pace", helpBody: paceHelp,
                accessibilityID: "ensemble.settings.help.pace") {
                HStack(spacing: Theme.space2) {
                    Slider(value: paceBinding, in: 0...2.5, step: 0.1)
                    Text(String(format: "%.1fs", viewModel.paceSeconds))
                        .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            row("Max turns", helpTitle: "Max turns", helpBody: maxTurnsHelp,
                accessibilityID: "ensemble.settings.help.maxTurns") {
                Stepper("\(viewModel.maxTurns)", value: $viewModel.maxTurns, in: 4...300, step: 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            row("Context window", helpTitle: "Context window", helpBody: contextWindowHelp,
                accessibilityID: "ensemble.settings.help.contextWindow") {
                Stepper("\(viewModel.verbatimWindow) turns", value: $viewModel.verbatimWindow, in: 4...40, step: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            toggleRow(
                title: "Speak turns aloud",
                isOn: $viewModel.voicedPlayback,
                helpTitle: "Speak turns aloud",
                helpBody: voicedPlaybackHelp,
                accessibilityID: "ensemble.settings.help.voicedPlayback"
            )
            toggleRow(
                title: "Rolling summary on long sessions",
                isOn: $viewModel.rollingSummaryEnabled,
                helpTitle: "Rolling summary",
                helpBody: rollingSummaryHelp,
                accessibilityID: "ensemble.settings.help.rollingSummary"
            )
        }
    }

    // MARK: - Context-aware help bodies

    /// Randomness only reshapes Round Robin's seat order (`Conductor.roundRobinNext`).
    private var randomnessApplies: Bool {
        viewModel.turnOrder == .roundRobin
    }

    private var turnOrderHelp: String {
        switch viewModel.turnOrder {
        case .director:
            return "An LLM (the conductor model from App Settings) chooses who speaks next each turn — favours someone with a clear reason to react, push back, or who has been quiet. On any director failure, falls back to weighted-random so the loop never stalls. Direct name-mentions still override."
        case .weightedRandom:
            return "Picks the next speaker at random, weighted by each persona’s talkativeness weight, and never the person who just spoke (so nobody answers themselves). Free — no extra LLM call. Direct name-mentions still override."
        case .roundRobin:
            return "Cycles through the cast in a fixed order. The Randomness setting below controls whether that order is shuffled once at the start or follows the cast list order. Direct name-mentions still override."
        }
    }

    private var randomnessHelp: String {
        switch viewModel.turnOrder {
        case .director, .weightedRandom:
            return "Not used in the current turn-order mode. Director and Weighted Random pick speakers on their own rules. Switch Turn order to Round Robin to use Shuffle once or list order."
        case .roundRobin:
            switch viewModel.rngMode {
            case .shuffleOnce:
                return "Builds one shuffled speaking order when the run starts (or the cast changes), then walks that order for the rest of the run."
            case .rerollPerTurn:
                // Conductor uses cast list order when not shuffleOnce — it does
                // not re-shuffle every turn despite the menu label.
                return "Uses the cast’s current list order as the speaking cycle (no shuffle). Direct name-mentions still jump the queue."
            }
        }
    }

    private var scenePlayHelp: String {
        switch viewModel.scenePlayMode {
        case .free:
            return "Free (default): the cast riffs freely. Scene and mood are light hints. Wild cards, digressions, and off-rails turns are welcome — flip to Scene-first when you want them to play the set scene more faithfully."
        case .sceneFirst:
            return "Scene-first: each line should advance the established scene and mood (orders, reports, in-world heat). Still always follows you if you deliberately redirect — it is not a content filter. Switch back to Free anytime for chaos."
        }
    }

    private var paceHelp: String {
        "Silence between the end of one spoken turn and the start of the next. 0s = back-to-back; higher values = more breathing room."
    }

    private var maxTurnsHelp: String {
        "Auto-stop after this many AI cast turns in the current run. Your own lines don’t count toward the cap. Raise it for long episodes; lower it for a short scene."
    }

    private var contextWindowHelp: String {
        "How many recent turns each speaker still sees verbatim. Older material may be folded into the rolling summary when that toggle is on. Larger = more memory and more tokens per turn."
    }

    private var voicedPlaybackHelp: String {
        "When on, each cast line is synthesized and played through the app’s TTS pipeline. When off, the transcript still advances text-only — faster, silent rehearsal."
    }

    private var rollingSummaryHelp: String {
        "When on, turns that fall outside the context window are compressed into a short “earlier in the conversation…” summary so long episodes stay coherent without sending the full history every turn."
    }

    // MARK: - Layout

    /// Manual binding for the `paceSeconds` computed bridge (Duration ↔ seconds).
    private var paceBinding: Binding<Double> {
        Binding(get: { viewModel.paceSeconds }, set: { viewModel.paceSeconds = $0 })
    }

    private func row<Content: View>(
        _ label: String,
        helpTitle: String,
        helpBody: String,
        accessibilityID: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Theme.space3) {
            HStack(spacing: Theme.space1) {
                // Higher contrast than textSecondary — glass + transcript behind
                // wash out the usual muted gray.
                Text(label).font(Theme.fontXS).foregroundStyle(Self.chairLabelColor)
                SettingInfoButton(title: helpTitle, message: helpBody, accessibilityID: accessibilityID)
            }
            .frame(width: 132, alignment: .leading)
            content()
        }
    }

    private func toggleRow(
        title: String,
        isOn: Binding<Bool>,
        helpTitle: String,
        helpBody: String,
        accessibilityID: String
    ) -> some View {
        HStack(spacing: Theme.space2) {
            Toggle(title, isOn: isOn)
                .font(Theme.fontSM).foregroundStyle(Theme.textPrimary)
            SettingInfoButton(title: helpTitle, message: helpBody, accessibilityID: accessibilityID)
            Spacer(minLength: 0)
        }
    }

    /// Near-primary light gray for row labels on the glass chair card.
    fileprivate static let chairLabelColor = Color(red: 0.92, green: 0.92, blue: 0.94)
}

// MARK: - Director's Chair

/// Floating glass card over the transcript (ZStack overlay — does not push layout).
/// Sketch: stem from the toolbar chair, settings left, Boot affordance right.
struct DirectorsChairPanel: View {
    @Bindable var viewModel: EnsembleViewModel
    var onCollapse: () -> Void

    @State private var showsBootComposer = false
    @State private var bootTargetID: UUID?
    @State private var bootReason: String = ""
    @FocusState private var bootReasonFocused: Bool

    private let cardRadius: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            // Stem — reads as “dropping from” the toolbar chair.
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 3, height: 10)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: Theme.space3) {
                HStack(alignment: .top, spacing: Theme.space4) {
                    VStack(alignment: .leading, spacing: Theme.space2) {
                        HStack(spacing: Theme.space2) {
                            Image(systemName: "chair.lounge.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text("Director's Chair")
                                .font(Theme.fontSMBold)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                            Button(action: collapseChair) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Collapse Director's Chair")
                            .accessibilityIdentifier("ensemble.directorsChair.collapse")
                        }

                        EnsembleSettingsView(viewModel: viewModel, showsSectionTitle: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    bootControl
                }

                // Full-width row under settings so the BOOT card can center.
                if showsBootComposer {
                    bootComposer
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }
            }
            .padding(Theme.space4)
            .frame(maxWidth: showsBootComposer ? 560 : 480, alignment: .leading)
            .directorsChairGlass(cornerRadius: cardRadius)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Theme.space6)
        .padding(.top, 2)
        .animation(.easeInOut(duration: 0.25), value: showsBootComposer)
        .onChange(of: viewModel.cast.map(\.id)) { _, ids in
            if let id = bootTargetID, !ids.contains(id) {
                bootTargetID = ids.first
            } else if bootTargetID == nil {
                bootTargetID = ids.first
            }
        }
        .onAppear {
            if bootTargetID == nil {
                bootTargetID = viewModel.cast.first?.id
            }
        }
        .onDisappear {
            bootReasonFocused = false
        }
        .accessibilityIdentifier("ensemble.directorsChair.panel")
    }

    private var canBoot: Bool {
        viewModel.cast.count > CastPackageBuilder.minCastSize
            && viewModel.pendingBoot == nil
    }

    private var bootControl: some View {
        Button {
            if showsBootComposer {
                collapseBootComposer()
            } else {
                if bootTargetID == nil {
                    bootTargetID = viewModel.cast.first?.id
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    showsBootComposer = true
                }
            }
        } label: {
            VStack(spacing: Theme.space1) {
                Image(systemName: "figure.kickboxing")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(showsBootComposer ? Theme.accentHover : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Theme.accent.opacity(showsBootComposer ? 0.22 : 0.12))
                            .overlay(Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                    )
                Text("Boot")
                    .font(Theme.fontXS)
                    .foregroundStyle(EnsembleSettingsView.chairLabelColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canBoot && !showsBootComposer)
        .opacity(canBoot || showsBootComposer ? 1 : 0.45)
        .help(canBoot
              ? "Boot — force a cast member's exit line, then remove them"
              : (viewModel.pendingBoot != nil
                 ? "A boot is already armed"
                 : "Need at least two speakers to boot"))
        .accessibilityIdentifier("ensemble.directorsChair.boot")
        .padding(.top, Theme.space6)
    }

    private var bootComposer: some View {
        VStack(alignment: .center, spacing: Theme.space2) {
            Text("BOOT")
                .font(Theme.fontXS)
                .foregroundStyle(EnsembleSettingsView.chairLabelColor)
                .frame(maxWidth: .infinity)
            Text("They speak next with this instruction, then leave the cast. Everyone else is told they're gone.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Picker("Speaker", selection: bootTargetBinding) {
                ForEach(viewModel.cast) { persona in
                    Text(persona.name).tag(Optional(persona.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .accessibilityIdentifier("ensemble.directorsChair.bootTarget")

            HStack(spacing: Theme.space2) {
                TextField("Reason — e.g. die heroically, leave the bridge, stop the crude jokes",
                         text: $bootReason)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.fontSM)
                    .focused($bootReasonFocused)
                    .accessibilityIdentifier("ensemble.directorsChair.bootReason")

                Button("Send") {
                    sendBoot()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(bootTargetID == nil || !canBoot)
                .accessibilityIdentifier("ensemble.directorsChair.bootSend")
            }
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
    }

    private var bootTargetBinding: Binding<UUID?> {
        Binding(
            get: { bootTargetID },
            set: { bootTargetID = $0 }
        )
    }

    private func sendBoot() {
        guard let id = bootTargetID else { return }
        // Resign field focus before collapsing the composer.
        bootReasonFocused = false
        guard viewModel.bootCastMember(id: id, reason: bootReason) else { return }
        bootReason = ""
        collapseBootComposer()
    }

    /// Defocus the reason field first so the field teardown doesn't fight the
    /// composer hide animation (focus resign → then remove).
    private func collapseBootComposer() {
        bootReasonFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.25)) {
                showsBootComposer = false
            }
        }
    }

    private func collapseChair() {
        bootReasonFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.5)) {
                showsBootComposer = false
            }
            onCollapse()
        }
    }
}

/// Liquid Glass when the OS supports it; material fallback otherwise.
private extension View {
    @ViewBuilder
    func directorsChairGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .background {
                    shape
                        .fill(.clear)
                        .glassEffect(.clear, in: shape)
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        }
    }
}

/// Toolbar affordance that toggles the Director's Chair panel.
struct DirectorsChairToggleButton: View {
    @Binding var isOpen: Bool

    /// Warm stone/cream — readable on dark chrome without vanishing as pure black.
    private static let chairIdle = Color(red: 0.78, green: 0.72, blue: 0.64)

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.5)) {
                isOpen.toggle()
            }
        } label: {
            Image(systemName: "chair.lounge.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOpen ? Theme.accent : Self.chairIdle)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOpen ? Theme.accent.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Collapse Director's Chair" : "Director's Chair — run settings over the live transcript")
        .accessibilityLabel("Director's Chair")
        .accessibilityValue(isOpen ? "Open" : "Closed")
        .accessibilityIdentifier("ensemble.directorsChair.toggle")
    }
}

// MARK: - SettingInfoButton

/// Small info.circle that owns its own popover — one instance per setting so
/// we don't need a single shared open-help enum.
private struct SettingInfoButton: View {
    let title: String
    let message: String
    let accessibilityID: String
    @State private var show = false

    var body: some View {
        Button(action: { show = true }) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warningFG)
        }
        .buttonStyle(.plain)
        .help("About \(title)")
        .accessibilityLabel("About \(title)")
        .accessibilityIdentifier(accessibilityID)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: Theme.space2) {
                Text(title)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.space3)
            .frame(width: 280, alignment: .leading)
        }
    }
}
