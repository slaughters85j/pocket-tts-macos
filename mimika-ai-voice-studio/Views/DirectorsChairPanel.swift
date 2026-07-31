//
//  DirectorsChairPanel.swift
//  mimika-ai-voice-studio
//
//  Director's Chair floating glass panel + toolbar toggle. Hosts
//  EnsembleSettingsView (run knobs) plus Boot / Direct / Compact tools.
//

import SwiftUI

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

    @State private var showsDirectComposer = false
    @State private var directTargetID: UUID?
    @State private var directInstruction: String = ""
    @FocusState private var directInstructionFocused: Bool

    private let cardRadius: CGFloat = 20

    private var showsAnyComposer: Bool { showsBootComposer || showsDirectComposer }

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

                    // Boot → Direct → Compact stacked on the right.
                    VStack(spacing: Theme.space3) {
                        bootControl
                        directControl
                        compactContextControl
                    }
                }

                // Full-width row under settings so composer cards can center.
                if showsBootComposer {
                    bootComposer
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }
                if showsDirectComposer {
                    directComposer
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }
            }
            .padding(Theme.space4)
            .frame(maxWidth: showsAnyComposer ? 560 : 480, alignment: .leading)
            .directorsChairGlass(cornerRadius: cardRadius)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Theme.space6)
        .padding(.top, 2)
        .animation(.easeInOut(duration: 0.25), value: showsBootComposer)
        .animation(.easeInOut(duration: 0.25), value: showsDirectComposer)
        .onChange(of: viewModel.cast.map(\.id)) { _, ids in
            if let id = bootTargetID, !ids.contains(id) {
                bootTargetID = ids.first
            } else if bootTargetID == nil {
                bootTargetID = ids.first
            }
            if let id = directTargetID, !ids.contains(id) {
                directTargetID = ids.first
            } else if directTargetID == nil {
                directTargetID = ids.first
            }
        }
        .onAppear {
            if bootTargetID == nil {
                bootTargetID = viewModel.cast.first?.id
            }
            if directTargetID == nil {
                directTargetID = viewModel.cast.first?.id
            }
        }
        .onDisappear {
            bootReasonFocused = false
            directInstructionFocused = false
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
                // One composer at a time.
                if showsDirectComposer { collapseDirectComposer() }
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
        .padding(.top, Theme.space4)
    }

    private var canDirect: Bool {
        !viewModel.cast.isEmpty && viewModel.pendingDirective == nil
    }

    private var directControl: some View {
        Button {
            if showsDirectComposer {
                collapseDirectComposer()
            } else {
                if directTargetID == nil {
                    directTargetID = viewModel.cast.first?.id
                }
                if showsBootComposer { collapseBootComposer() }
                withAnimation(.easeInOut(duration: 0.25)) {
                    showsDirectComposer = true
                }
            }
        } label: {
            VStack(spacing: Theme.space1) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(showsDirectComposer || viewModel.pendingDirective != nil
                                     ? Theme.accentHover : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Theme.accent.opacity(
                                showsDirectComposer || viewModel.pendingDirective != nil ? 0.22 : 0.12
                            ))
                            .overlay(Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                    )
                Text("Direct")
                    .font(Theme.fontXS)
                    .foregroundStyle(EnsembleSettingsView.chairLabelColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canDirect && !showsDirectComposer)
        .opacity(canDirect || showsDirectComposer ? 1 : 0.45)
        .help(viewModel.pendingDirective != nil
              ? "A direction is already armed for the next forced turn"
              : "Direct — private note to one cast member (Strict sampling)")
        .accessibilityIdentifier("ensemble.directorsChair.direct")
    }

    /// Compact — fold older model context; icon under Boot with a blue progress ring.
    private var compactContextControl: some View {
        let fill = CGFloat(viewModel.contextFillPercent ?? 0) / 100.0
        let ringLine: CGFloat = 3.0
        return Button {
            _ = viewModel.compactContext()
        } label: {
            VStack(spacing: Theme.space1) {
                ZStack {
                    // Soft disc (same footprint as Boot) so the ring sits “around” a button.
                    Circle()
                        .fill(Self.compactRingBlue.opacity(viewModel.turns.isEmpty ? 0.06 : 0.12))
                    // Dim track
                    Circle()
                        .stroke(Self.compactRingBlue.opacity(0.28), lineWidth: ringLine)
                    // Progress arc (0…fill), 12 o’clock start — system activity-ring style
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fill)))
                        .stroke(
                            Self.compactRingBlue,
                            style: StrokeStyle(lineWidth: ringLine, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.35), value: viewModel.contextFillPercent)
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(compactIconColor)
                }
                .frame(width: 40, height: 40)
                Text("Compact")
                    .font(Theme.fontXS)
                    .foregroundStyle(EnsembleSettingsView.chairLabelColor)
                if let pct = viewModel.contextFillPercent {
                    Text("~\(pct)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(compactIconColor)
                    Text(EnsembleSettingsView.formatTokenCount(viewModel.effectiveContextLimitTokens))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.turns.isEmpty)
        .opacity(viewModel.turns.isEmpty ? 0.45 : 1)
        .help(compactContextHelpText)
        .accessibilityIdentifier("ensemble.directorsChair.compactContext")
        .onAppear {
            viewModel.refreshContextFillEstimate()
            #if DEBUG
            let limit = viewModel.effectiveContextLimitTokens
            let prompt = viewModel.estimateModelFacingPromptTokens()
            print(
                "[Compact] meter ready fill~\(viewModel.contextFillPercent.map(String.init) ?? "?")% "
                + "promptTokens=\(prompt) limit=\(limit) "
                + "loaded=\(viewModel.modelContextLimitTokens.map(String.init) ?? "?") "
                + "archMax=\(viewModel.modelArchitectureMaxTokens.map(String.init) ?? "?") "
                + "override=\(viewModel.contextLimitOverrideTokens.map(String.init) ?? "nil") "
                + "turns=\(viewModel.turns.count) summarizedUpTo=\(viewModel.summarizedUpTo)"
            )
            #endif
        }
    }

    private var compactContextHelpText: String {
        var s = Self.compactContextHelp
        let loaded = viewModel.modelContextLimitTokens
        let arch = viewModel.modelArchitectureMaxTokens
        if let loaded, let arch, arch > loaded {
            s += " Server loaded \(EnsembleSettingsView.formatTokenCount(loaded)); model max \(EnsembleSettingsView.formatTokenCount(arch)) — raise Context Length in LM Studio to use more."
        }
        return s
    }

    /// Bright system-style blue for the context fill ring (track + progress).
    private static let compactRingBlue = Color(red: 0.22, green: 0.55, blue: 1.0)

    private var compactIconColor: Color {
        guard let pct = viewModel.contextFillPercent else { return Theme.accent }
        if pct >= 90 { return Theme.errorFG }
        if pct >= 75 { return Theme.warningFG }
        return Theme.accent
    }

    fileprivate static let compactContextHelp =
        "Compact older model context: next calls keep the last Context window turns plus a short brief. Transcript / export stay complete. ~% uses a Qwen reference tokenizer vs LM Studio’s loaded context length (Server context in Run Settings; toast at ~90%). Not Solo Max Tokens."

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

    private var directComposer: some View {
        VStack(alignment: .center, spacing: Theme.space2) {
            Text("DIRECT")
                .font(Theme.fontXS)
                .foregroundStyle(EnsembleSettingsView.chairLabelColor)
                .frame(maxWidth: .infinity)
            Text("Private note for one cast member. They speak next (Strict sampling). Stay in character — steer, ban a phrase, or change the beat.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Picker("Speaker", selection: directTargetBinding) {
                ForEach(viewModel.cast) { persona in
                    Text(persona.name).tag(Optional(persona.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .accessibilityIdentifier("ensemble.directorsChair.directTarget")

            HStack(spacing: Theme.space2) {
                TextField("e.g. stop the emoji jokes, get back to the sensor anomaly",
                         text: $directInstruction)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.fontSM)
                    .focused($directInstructionFocused)
                    .accessibilityIdentifier("ensemble.directorsChair.directInstruction")

                Button("Send") {
                    sendDirect()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(directTargetID == nil
                          || directInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !canDirect)
                .accessibilityIdentifier("ensemble.directorsChair.directSend")
            }
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
    }

    private var directTargetBinding: Binding<UUID?> {
        Binding(
            get: { directTargetID },
            set: { directTargetID = $0 }
        )
    }

    private func sendDirect() {
        guard let id = directTargetID else { return }
        directInstructionFocused = false
        guard viewModel.issueDirective(id: id, instruction: directInstruction) else { return }
        directInstruction = ""
        collapseDirectComposer()
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

    private func collapseDirectComposer() {
        directInstructionFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.25)) {
                showsDirectComposer = false
            }
        }
    }

    private func collapseChair() {
        bootReasonFocused = false
        directInstructionFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.5)) {
                showsBootComposer = false
                showsDirectComposer = false
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
        // ~15% more body under clear glass so the chair reads over the transcript.
        let scrim = 0.15
        if #available(macOS 26.0, *) {
            self
                .background {
                    ZStack {
                        // Clear glass alone is very see-through over the transcript;
                        // a dark scrim lifts opacity without killing the liquid look.
                        shape.fill(Color.black.opacity(scrim))
                        shape
                            .fill(.clear)
                            .glassEffect(.clear, in: shape)
                    }
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        } else {
            self
                // One step denser than ultraThin ≈ same “a bit less translucent” ask.
                .background(.thinMaterial, in: shape)
                .overlay {
                    shape.fill(Color.black.opacity(scrim * 0.6))
                }
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
