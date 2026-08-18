//
//  DirectorsChairComposer.swift
//  mimika-ai-voice-studio
//
//  Shared Boot / Direct composer card for the Director's Chair. Extracted from DirectorsChairPanel because the two cards were near-identical copies AND because their text fields lived on the panel: every keystroke re-evaluated the whole Chair body — Liquid Glass card plus the full run-settings form.
//

import SwiftUI

// MARK: - ChairComposerStyle

/// Static copy + accessibility IDs for one composer flavor. Keeps the card itself free of Boot/Direct branching.
struct ChairComposerStyle {
    let title: String
    let blurb: String
    let placeholder: String
    /// Direct needs an instruction; Boot accepts an empty reason.
    let requiresText: Bool
    let targetAccessibilityID: String
    let fieldAccessibilityID: String
    let sendAccessibilityID: String

    static let boot = ChairComposerStyle(
        title: "BOOT",
        blurb: "They speak next with this instruction, then leave the cast. Everyone else is told they're gone.",
        placeholder: "Reason — e.g. die heroically, leave the bridge, stop the crude jokes",
        requiresText: false,
        targetAccessibilityID: "ensemble.directorsChair.bootTarget",
        fieldAccessibilityID: "ensemble.directorsChair.bootReason",
        sendAccessibilityID: "ensemble.directorsChair.bootSend"
    )

    static let direct = ChairComposerStyle(
        title: "DIRECT",
        blurb: "Private note for one cast member. They speak next (Strict sampling). Stay in character — steer, ban a phrase, or change the beat.",
        placeholder: "e.g. stop the emoji jokes, get back to the sensor anomaly",
        requiresText: true,
        targetAccessibilityID: "ensemble.directorsChair.directTarget",
        fieldAccessibilityID: "ensemble.directorsChair.directInstruction",
        sendAccessibilityID: "ensemble.directorsChair.directSend"
    )
}

// MARK: - ChairComposerCard

/// One composer card. Owns its `text` and focus so a keystroke invalidates this card only — never the glass panel hosting it.
struct ChairComposerCard: View {
    let style: ChairComposerStyle
    let cast: [Persona]
    /// View-model gate (`canBoot` / `canDirect`), evaluated by the panel.
    let canSend: Bool
    @Binding var targetID: UUID?
    /// Returns true when the action was accepted — the card then clears itself.
    var onSend: (String) -> Bool

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .center, spacing: Theme.space2) {
            Text(style.title)
                .font(Theme.fontXS)
                .foregroundStyle(EnsembleSettingsView.chairLabelColor)
                .frame(maxWidth: .infinity)
            Text(style.blurb)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Picker("Speaker", selection: $targetID) {
                ForEach(cast) { persona in
                    Text(persona.name).tag(Optional(persona.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .accessibilityIdentifier(style.targetAccessibilityID)

            HStack(spacing: Theme.space2) {
                TextField(style.placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.fontSM)
                    .focused($focused)
                    .accessibilityIdentifier(style.fieldAccessibilityID)

                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!isSendable)
                    .accessibilityIdentifier(style.sendAccessibilityID)
            }
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        // Resign before teardown — AppKit fights a focused field being removed mid-animation (this is why the panel's collapse is delayed 60 ms).
        .onDisappear { focused = false }
    }

    private var isSendable: Bool {
        guard targetID != nil, canSend else { return false }
        guard style.requiresText else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        focused = false
        if onSend(text) { text = "" }
    }
}
