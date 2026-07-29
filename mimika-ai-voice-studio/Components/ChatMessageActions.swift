//
//  ChatMessageActions.swift
//  mimika-ai-voice-studio
//
//  Hover actions and in-place editor for Solo Chat transcript messages.
//

import AppKit
import SwiftUI

// MARK: - Message actions

/// Compact actions displayed beneath a hovered Solo Chat message.
struct ChatMessageActionBar: View {
    let message: ChatMessage
    let canModify: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                title: "Copy message",
                systemImage: "doc.on.doc",
                isDisabled: message.content.isEmpty,
                action: copyMessage
            )
            actionButton(
                title: "Edit message",
                systemImage: "pencil",
                isDisabled: !canModify,
                action: onEdit
            )
            actionButton(
                title: "Delete message",
                systemImage: "trash",
                isDisabled: !canModify,
                action: onDelete
            )
        }
    }

    /// Builds one consistently sized message action.
    private func actionButton(
        title: String,
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(isDisabled ? 0.34 : 0.78))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(
            "chat.message.\(message.id.uuidString).\(systemImage)"
        )
    }

    /// Copies the unrendered message text, preserving Markdown.
    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
    }
}

// MARK: - Message editor

/// Sheet for changing one transcript message without regenerating later turns.
struct ChatMessageEditorSheet: View {
    let message: ChatMessage
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var text: String

    init(
        message: ChatMessage,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.message = message
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: message.content)
    }

    var body: some View {
        ModalContainer(title: "Edit Message", onClose: onCancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                Text("Updates this transcript message without regenerating later responses.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)

                MacTextEditor(
                    text: $text,
                    isEditable: true,
                    accessibilityID: "chat.messageEditor.field"
                )
                .themeInputField()

                HStack(spacing: Theme.space3) {
                    Spacer()

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)

                    Button("Save") {
                        onSave(text)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.fontSM)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(canSave ? Theme.accent : Color.gray.opacity(0.5))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: Theme.radiusSmall,
                            style: .continuous
                        )
                    )
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("chat.messageEditor.save")
                }
            }
        }
        .frame(width: 500, height: 300)
    }

    /// Text may be empty only when the existing message retains images.
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.attachments.isEmpty
    }
}
