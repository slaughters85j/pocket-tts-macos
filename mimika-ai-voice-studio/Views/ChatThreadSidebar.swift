//
//  ChatThreadSidebar.swift
//  mimika-ai-voice-studio
//
//  Messages-style thread list: title, model theme one-liner, created date.
//  Pin / delete via context menu. Kind is owned by ChatThreadBrowser.
//

import SwiftUI

// MARK: - ChatThreadSidebar

struct ChatThreadSidebar: View {
    @Bindable var browser: ChatThreadBrowser
    var onSelect: (ChatThreadIndexEntry) -> Void
    var onDeleted: (ChatThreadIndexEntry) -> Void = { _ in }
    var onNew: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(browser.kind == .solo ? "Solo threads" : "Ensemble threads")
                    .font(Theme.fontXS)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let onNew = onNew {
                    Button(action: onNew) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(browser.kind == .solo
                          ? "Start a new Solo thread"
                          : "New Ensemble threads start from New Cast or Reuse Last")
                    .accessibilityIdentifier("chat.threads.new")
                }
            }
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)

            Divider().background(Theme.borderColor)

            if browser.entries.isEmpty {
                Text(browser.kind == .solo
                     ? "Send a message to start a thread."
                     : "Start or reuse a cast to start a thread.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(Theme.space4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(browser.entries) { entry in
                            threadRow(entry)
                            Divider().background(Theme.borderColor.opacity(0.6))
                        }
                    }
                }
            }
        }
        .frame(width: 248)
        .background(Theme.bgSecondary)
        .accessibilityIdentifier("chat.threads.sidebar")
    }

    private func threadRow(_ entry: ChatThreadIndexEntry) -> some View {
        let selected = browser.selectedID == entry.id
        return Button {
            onSelect(entry)
        } label: {
            HStack(alignment: .top, spacing: Theme.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if entry.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text(entry.title)
                            .font(Theme.fontSM)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Text(entry.theme.isEmpty ? " " : entry.theme)
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(ChatThreadBrowser.createdDateLabel(entry.createdAt))
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .layoutPriority(1)
            }
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Theme.accent.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(entry.pinned ? "Unpin" : "Pin") {
                browser.togglePinned(entry)
            }
            Button("Delete", role: .destructive) {
                browser.delete(entry)
                onDeleted(entry)
            }
        }
        .accessibilityIdentifier("chat.threads.row.\(entry.id.uuidString)")
    }
}
