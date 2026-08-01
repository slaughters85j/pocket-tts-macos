//
//  EnsembleCharacterPickerBar.swift
//  mimika-ai-voice-studio
//
//  Compact "Speaking as" strip above the Ensemble composer. Seeds from the
//  Cast & Settings user name; green + adds an alias that becomes the active
//  human peer (overrides cast settings for subsequent turns).
//

import SwiftUI

// MARK: - EnsembleCharacterPickerBar

/// Quick character switcher for the human peer — picker + green add control.
struct EnsembleCharacterPickerBar: View {
    @Bindable var viewModel: EnsembleViewModel

    @State private var isAdding = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space1) {
            HStack(spacing: Theme.space2) {
                Image(systemName: "theatermasks.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)

                Text("Speaking as")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)

                characterMenu

                Spacer(minLength: Theme.space2)

                if !isAdding {
                    addButton
                }
            }

            if isAdding {
                addNameRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isAdding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ensemble.composer.characterPicker")
    }

    // MARK: - Menu

    /// Menu of remembered names; always includes the current active peer so the
    /// label stays honest even if the roster was empty (default "You").
    private var characterMenu: some View {
        Menu {
            ForEach(menuNames, id: \.self) { name in
                Button {
                    viewModel.selectUserCharacter(name == "You" ? "" : name)
                } label: {
                    HStack {
                        Text(name)
                        if name == viewModel.userPeer.name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.userPeer.name)
                    .font(Theme.fontXS)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, 4)
            .background(Theme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("ensemble.composer.characterMenu")
        .accessibilityLabel("Speaking as \(viewModel.userPeer.name)")
        .help("Switch which character name you speak as")
    }

    /// Roster first, then active name if missing (e.g. default "You").
    private var menuNames: [String] {
        var names = viewModel.userCharacterRoster
        let active = viewModel.userPeer.name
        if !names.contains(where: { $0.caseInsensitiveCompare(active) == .orderedSame }) {
            names.append(active)
        }
        return names
    }

    // MARK: - Add

    private var addButton: some View {
        Button {
            isAdding = true
            draft = ""
            draftFocused = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.successFG)
        }
        .buttonStyle(.plain)
        .help("Add a character name to speak as")
        .accessibilityIdentifier("ensemble.composer.addCharacter")
        .accessibilityLabel("Add character name")
    }

    private var addNameRow: some View {
        HStack(spacing: Theme.space2) {
            TextField("Character name…", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
                .themeInputField()
                .focused($draftFocused)
                .onSubmit { commitAdd() }
                .accessibilityIdentifier("ensemble.composer.addCharacterField")

            Button("Add") { commitAdd() }
                .font(Theme.fontXS)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
                .background(canCommit ? Theme.successFG : Theme.successFG.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .accessibilityIdentifier("ensemble.composer.addCharacterConfirm")

            Button("Cancel") { cancelAdd() }
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("ensemble.composer.addCharacterCancel")
        }
    }

    private var canCommit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commitAdd() {
        guard viewModel.addUserCharacter(draft) else { return }
        draft = ""
        isAdding = false
        draftFocused = false
    }

    private func cancelAdd() {
        draft = ""
        isAdding = false
        draftFocused = false
    }
}
