//
//  ChatThreadRenameSheet.swift
//  mimika-ai-voice-studio
//
//  Rename a Solo / Ensemble thread and edit its one-line description. Renaming
//  marks the title custom, so the per-turn save stops re-deriving it from the
//  first message (see ChatThreadIndexEntry.titleIsCustom).
//

import SwiftUI

// MARK: - ChatThreadRenameSheet

struct ChatThreadRenameSheet: View {
    let entry: ChatThreadIndexEntry
    let onCancel: () -> Void
    let onSave: (String, String) -> Void

    @State private var title: String
    @State private var theme: String
    @FocusState private var titleFocused: Bool

    init(
        entry: ChatThreadIndexEntry,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String) -> Void
    ) {
        self.entry = entry
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _theme = State(initialValue: entry.theme)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ModalContainer(title: "Rename thread", onClose: onCancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                field(
                    label: "Name",
                    caption: "Shown in the sidebar.",
                    text: $title,
                    placeholder: "Thread name",
                    accessibilityID: "chat.threads.rename.title"
                )
                .focused($titleFocused)

                field(
                    label: "Description",
                    caption: "The one-line blurb under the name. Leave empty to clear it.",
                    text: $theme,
                    placeholder: "Short description",
                    accessibilityID: "chat.threads.rename.theme"
                )

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space3)
                        .accessibilityIdentifier("chat.threads.rename.cancel")

                    Button {
                        onSave(trimmedTitle, theme)
                    } label: {
                        Text("Save")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4)
                            .padding(.vertical, Theme.space2)
                            .background(trimmedTitle.isEmpty ? Color.gray.opacity(0.5) : Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedTitle.isEmpty)
                    .accessibilityIdentifier("chat.threads.rename.save")
                }
            }
            .padding(Theme.space6)
        }
        .frame(minWidth: 460)
        .onAppear { titleFocused = true }
        .accessibilityIdentifier("chat.threads.rename.sheet")
    }

    // MARK: - Layout

    private func field(
        label: String,
        caption: String,
        text: Binding<String>,
        placeholder: String,
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.space1) {
            Text(label)
                .font(Theme.fontXS)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
                .themeInputField()
                .onSubmit {
                    if !trimmedTitle.isEmpty { onSave(trimmedTitle, theme) }
                }
                .accessibilityIdentifier(accessibilityID)
            Text(caption)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
