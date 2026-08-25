//
//  EnsembleSettingsView.swift
//  mimika-ai-voice-studio
//
//  Ensemble run knobs (turn order, pace, limits, context, scene play). Hosted in the Director's Chair panel on the Ensemble toolbar so they stay reachable mid-run. Cast & Settings keeps roster / scene-mood / voices only.
//
//  WP-CAST-1: info.circle popovers on every setting; Turn order + Randomness bodies are context-aware to the current picker values.
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

            // The model is configured once in App Settings (Local LLM Endpoint), not here — one source of truth, no per-cast override.
            row("Turn order", helpTitle: "Turn order", helpBody: turnOrderHelp,
                accessibilityID: "ensemble.settings.help.turnOrder") {
                Picker("", selection: $viewModel.turnOrder) {
                    ForEach(TurnMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
            row("Randomness", helpTitle: "Randomness", helpBody: randomnessHelp,
                accessibilityID: "ensemble.settings.help.randomness") {
                Picker("", selection: $viewModel.rngMode) {
                    Text("Shuffle once").tag(RNGMode.shuffleOnce)
                    Text("Reroll each turn").tag(RNGMode.rerollPerTurn)
                }
                .pickerStyle(.menu).labelsHidden()
                // Conductor only consults RNG for Round Robin seat order. Director / Weighted Random ignore it — grey the control out.
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
                .pickerStyle(.menu).labelsHidden()
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
            }
            row("Context window", helpTitle: "Context window", helpBody: contextWindowHelp,
                accessibilityID: "ensemble.settings.help.contextWindow") {
                Stepper("\(viewModel.verbatimWindow) turns", value: $viewModel.verbatimWindow, in: 4...40, step: 2)
            }
            // Compact fill denominator — not Solo "Max Tokens" (reply length). Override only affects the meter; raise n_ctx in LM Studio for real capacity.
            row("Server context", helpTitle: "Server context", helpBody: serverContextHelp,
                accessibilityID: "ensemble.settings.help.serverContext") {
                HStack(spacing: Theme.space2) {
                    TextField("Auto", value: contextLimitOverrideBinding, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .accessibilityIdentifier("ensemble.settings.contextLimitOverride")
                    Text(serverContextCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

            toggleRow(
                title: "Include me in turn order",
                isOn: includeUserBinding,
                helpTitle: "Include me in turn order",
                helpBody: includeUserHelp,
                accessibilityID: "ensemble.settings.help.includeUser"
            )
            .opacity(viewModel.hasRealUserCharacterName ? 1 : 0.55)
        }
        .frame(width: Self.formWidth, alignment: .leading)
    }

    private var includeUserBinding: Binding<Bool> {
        Binding(
            get: { viewModel.includeUserInTurnOrder },
            set: { viewModel.setIncludeUserInTurnOrder($0) }
        )
    }

    /// Empty field = auto (use LM Studio loaded n_ctx / architecture max).
    private var contextLimitOverrideBinding: Binding<Int?> {
        Binding(
            get: { viewModel.contextLimitOverrideTokens },
            set: { value in
                viewModel.contextLimitOverrideTokens = value.flatMap { $0 > 0 ? $0 : nil }
                viewModel.refreshContextFillEstimate()
            }
        )
    }

    private var serverContextCaption: String {
        let effective = viewModel.effectiveContextLimitTokens
        let loaded = viewModel.modelContextLimitTokens
        let arch = viewModel.modelArchitectureMaxTokens
        if viewModel.contextLimitOverrideTokens != nil {
            return "override · using \(Self.formatTokenCount(effective))"
        }
        if let loaded, let arch, arch > loaded {
            return "loaded \(Self.formatTokenCount(loaded)) · model max \(Self.formatTokenCount(arch))"
        }
        if let loaded {
            return "loaded \(Self.formatTokenCount(loaded))"
        }
        if let arch {
            return "model max \(Self.formatTokenCount(arch))"
        }
        return "using \(Self.formatTokenCount(effective))"
    }

    static func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1_000)k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
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
                // Conductor uses cast list order when not shuffleOnce — it does not re-shuffle every turn despite the menu label.
                return "Uses the cast’s current list order as the speaking cycle (no shuffle). Direct name-mentions still jump the queue."
            }
        }
    }

    private var scenePlayHelp: String {
        switch viewModel.scenePlayMode {
        case .free:
            return "Free: the cast riffs freely. Scene and mood are light hints. Wild cards, digressions, and off-rails turns are welcome — flip back to Scene-first when you want them on the set scene again."
        case .sceneFirst:
            return "Scene-first (default): each line should advance the established scene and mood (orders, reports, in-world heat). Still always follows you if you deliberately redirect — it is not a content filter. Switch to Free anytime for chaos."
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

    private var serverContextHelp: String {
        "Token ceiling for the Compact fill meter (and for knowing when you're near full). "
            + "Auto uses LM Studio’s *loaded* context length for this session — not Solo’s Max Tokens "
            + "(that’s reply length). If loaded is e.g. 8k but the model max is 262k, raise Context Length "
            + "when loading the model in LM Studio. Optional override only re-scales the meter; it cannot "
            + "expand the server’s real KV cache."
    }

    private var voicedPlaybackHelp: String {
        "When on, each cast line is synthesized and played through the app’s TTS pipeline. When off, the transcript still advances text-only — faster, silent rehearsal."
    }

    private var rollingSummaryHelp: String {
        "When on, turns that fall outside the context window are compressed into a short “earlier in the conversation…” summary so long episodes stay coherent without sending the full history every turn."
    }

    private var includeUserHelp: String {
        if viewModel.hasRealUserCharacterName {
            return "When on, the director/conductor can pick you (\(viewModel.userPeer.modelName)) as the next speaker. You’ll get a cue and a short window to type or speak. Requires your character name in Cast & Settings."
        }
        return "Set your character name in Cast & Settings (YOU section) first — then the director can tap you to speak mid-scene."
    }

    // MARK: - Layout

    // Fixed row geometry. This is a PERFORMANCE contract, not cosmetics.
    //
    // Every control here is AppKit-backed (NSPopUpButton / NSStepper / NSTextField). Left flexible, SwiftUI's StackLayout re-proposes sizes to each one and every probe round-trips into AppKit. A 30 s Time Profiler trace of the open Chair showed ~13.5 nested `LayoutEngineBox.sizeThatFits` per sample, ~5.9 `_FlexFrameLayout` (that IS `.frame(maxWidth:)`), and a main thread hung continuously — clicks and keystrokes took seconds. Rigid widths give the layout engine nothing to search. Do not put `maxWidth: .infinity` back on the form, a row, or any AppKit-backed control in one. (A plain Text inside an already-fixed column is fine — it resolves against a known width.)
    //
    // labelWidth + space3 + controlWidth == formWidth, and formWidth fits the Chair's 480pt card (448 inner − 16 gap − ~56 Boot/Direct/Compact column).
    private static let formWidth: CGFloat = 372
    private static let labelWidth: CGFloat = 132
    private static let controlWidth: CGFloat = 228

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
                // Higher contrast than textSecondary — glass + transcript behind wash out the usual muted gray.
                Text(label).font(Theme.fontXS).foregroundStyle(Self.chairLabelColor)
                SettingInfoButton(title: helpTitle, message: helpBody, accessibilityID: accessibilityID)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            content()
                .frame(width: Self.controlWidth, alignment: .leading)
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
    static let chairLabelColor = Color(red: 0.92, green: 0.92, blue: 0.94)
}

// MARK: - SettingInfoButton

/// Small info.circle that owns its own popover — one instance per setting so we don't need a single shared open-help enum.
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
