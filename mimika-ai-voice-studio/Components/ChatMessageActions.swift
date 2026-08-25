//
//  ChatMessageActions.swift
//  mimika-ai-voice-studio
//
//  Hover actions and in-place editor for transcript entries. Shared by Solo Chat messages and Ensemble turns — the bar takes the text and an id rather than a ChatMessage so both transcripts can use one implementation.
//

import AppKit
import SwiftUI

// MARK: - Message actions

/// Compact actions displayed beneath a hovered transcript entry.
struct ChatMessageActionBar: View {
    /// Raw text to copy — unrendered, so Markdown survives.
    let content: String
    /// Stable id for accessibility identifiers.
    let entryID: UUID
    let canModify: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                title: "Copy message",
                systemImage: "doc.on.doc",
                isDisabled: content.isEmpty,
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
            "chat.message.\(entryID.uuidString).\(systemImage)"
        )
    }

    /// Copies the unrendered message text, preserving Markdown.
    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }
}

// MARK: - Hover container

/// Reveals `ChatMessageActionBar` beneath a transcript entry on hover.
///
/// Owns its own hover state on purpose: with this on the parent, hovering any row would invalidate the entire transcript, which already re-renders on every streamed token.
struct TranscriptHoverActions<Content: View>: View {
    let entryID: UUID
    /// Raw text the copy action puts on the pasteboard.
    let copyText: String
    let canModify: Bool
    var alignment: Alignment = .bottomTrailing
    var onEdit: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .overlay(alignment: alignment) {
                ChatMessageActionBar(
                    content: copyText,
                    entryID: entryID,
                    canModify: canModify,
                    onEdit: onEdit,
                    onDelete: onDelete
                )
                // Bare glyphs, no plate — matches Solo's bubble actions.
                .padding(Theme.space2)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Message editor

/// Sheet for changing one transcript entry without regenerating later turns.
struct ChatMessageEditorSheet: View {
    let onCancel: () -> Void
    let onSave: (String) -> Void
    /// Entries that carry images may be saved with empty text.
    private let allowsEmpty: Bool

    @State private var text: String

    init(
        content: String,
        allowsEmpty: Bool = false,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.allowsEmpty = allowsEmpty
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: content)
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

    /// Text may be empty only when the entry retains images.
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || allowsEmpty
    }
}
