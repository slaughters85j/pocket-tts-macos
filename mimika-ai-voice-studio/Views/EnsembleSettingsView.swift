//
//  EnsembleSettingsView.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — Ensemble run settings: the global knobs (turn order, pace, limits,
//  context) bound to the view model. Embedded in the cast editor sheet so the
//  one "sliders" control configures both the cast and the run.
//
//  WP-CAST-1: info.circle popovers on every setting; Turn order + Randomness
//  bodies are context-aware to the current picker values.
//

import SwiftUI

struct EnsembleSettingsView: View {
    @Bindable var viewModel: EnsembleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("RUN SETTINGS").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)

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
                Text(label).font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
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
