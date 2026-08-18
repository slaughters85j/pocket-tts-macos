//
//  DirectorsChairPanel.swift
//  mimika-ai-voice-studio
//
//  Director's Chair floating glass panel + toolbar toggle. Hosts EnsembleSettingsView (run knobs) plus Boot / Direct / Compact tools.
//

import SwiftUI

// MARK: - Director's Chair

/// Floating glass card over the transcript (ZStack overlay — does not push layout). Sketch: stem from the toolbar chair, settings left, Boot affordance right.
struct DirectorsChairPanel: View {
    @Bindable var viewModel: EnsembleViewModel
    /// Binding instead of a closure — a new `() -> Void` every parent body eval was recreating this view (and Liquid Glass) on each token.
    @Binding var isPresented: Bool

    // Composer text + focus live on `ChairComposerCard`, not here — typing must not re-evaluate this body (glass card + the whole run-settings form).
    @State private var showsBootComposer = false
    @State private var bootTargetID: UUID?

    @State private var showsDirectComposer = false
    @State private var directTargetID: UUID?

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
                        // Isolated view: fill % / turns must not rebuild the glass card.
                        DirectorsChairCompactMeter(viewModel: viewModel)
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
        .onChange(of: viewModel.cast.count) { _, _ in
            let ids = viewModel.cast.map(\.id)
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

    fileprivate static let compactContextHelp =
        "Compact older model context: next calls keep the last Context window turns plus a short brief. Transcript / export stay complete. ~% uses a Qwen reference tokenizer vs LM Studio’s loaded context length (Server context in Run Settings; toast at ~90%). Not Solo Max Tokens."

    private var bootComposer: some View {
        ChairComposerCard(
            style: .boot,
            cast: viewModel.cast,
            canSend: canBoot,
            targetID: $bootTargetID,
            onSend: sendBoot
        )
    }

    private func sendBoot(reason: String) -> Bool {
        guard let id = bootTargetID else { return false }
        guard viewModel.bootCastMember(id: id, reason: reason) else { return false }
        collapseBootComposer()
        return true
    }

    private var directComposer: some View {
        ChairComposerCard(
            style: .direct,
            cast: viewModel.cast,
            canSend: canDirect,
            targetID: $directTargetID,
            onSend: sendDirect
        )
    }

    private func sendDirect(instruction: String) -> Bool {
        guard let id = directTargetID else { return false }
        guard viewModel.issueDirective(id: id, instruction: instruction) else { return false }
        collapseDirectComposer()
        return true
    }

    /// The card resigns focus on send / disappear; the 60 ms beat still keeps that teardown from fighting the composer hide animation.
    private func collapseBootComposer() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.25)) {
                showsBootComposer = false
            }
        }
    }

    private func collapseDirectComposer() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.25)) {
                showsDirectComposer = false
            }
        }
    }

    private func collapseChair() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.5)) {
                showsBootComposer = false
                showsDirectComposer = false
            }
            isPresented = false
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
                        // Clear glass alone is very see-through over the transcript; a dark scrim lifts opacity without killing the liquid look.
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

// MARK: - Compact meter (isolated)

/// Own Observation scope so token/fill updates do not rebuild the glass card.
private struct DirectorsChairCompactMeter: View {
    @Bindable var viewModel: EnsembleViewModel

    private let ringLine: CGFloat = 3.0
    private static let compactRingBlue = Color(red: 0.22, green: 0.55, blue: 1.0)

    var body: some View {
        let fill = CGFloat(viewModel.contextFillPercent ?? 0) / 100.0
        let empty = !viewModel.hasTurns
        return Button {
            _ = viewModel.compactContext()
        } label: {
            VStack(spacing: Theme.space1) {
                ZStack {
                    Circle()
                        .fill(Self.compactRingBlue.opacity(empty ? 0.06 : 0.12))
                    Circle()
                        .stroke(Self.compactRingBlue.opacity(0.28), lineWidth: ringLine)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fill)))
                        .stroke(
                            Self.compactRingBlue,
                            style: StrokeStyle(lineWidth: ringLine, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(compactIconColor)
                }
                .frame(width: 40, height: 40)
                Text("Compact")
                    .font(Theme.fontXS)
                    .foregroundStyle(EnsembleSettingsView.chairLabelColor)
                if let pct = viewModel.contextFillPercent {
                    // Bare percentage — no "~" or "≈" prefix. At 10pt on a 4K display an approximation glyph reads as a minus sign in front of the digits; it was reported as a negative value twice. "Approximate" is already said in the help popover, where there is room to say it in words. Don't add it back.
                    Text("\(pct)%")
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
        .disabled(empty)
        .opacity(empty ? 0.45 : 1)
        .help(helpText)
        .accessibilityIdentifier("ensemble.directorsChair.compactContext")
    }

    private var compactIconColor: Color {
        guard let pct = viewModel.contextFillPercent else { return Theme.accent }
        if pct >= 90 { return Theme.errorFG }
        if pct >= 75 { return Theme.warningFG }
        return Theme.accent
    }

    private var helpText: String {
        var s = DirectorsChairPanel.compactContextHelp
        let loaded = viewModel.modelContextLimitTokens
        let arch = viewModel.modelArchitectureMaxTokens
        if let loaded, let arch, arch > loaded {
            s += " Server loaded \(EnsembleSettingsView.formatTokenCount(loaded)); model max \(EnsembleSettingsView.formatTokenCount(arch)) — raise Context Length in LM Studio to use more."
        }
        return s
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
