//
//  ChatComposerView.swift
//  mimika-ai-voice-studio
//
//  Solo Chat's text, dictation, attachment, send, and stop controls.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Composer

/// Acceptance-aware Solo Chat composer with shared picker/drop imports.
struct ChatComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var dropIsTargeted = false
    @State private var editorHeight: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            statusMessages
            if !viewModel.pendingAttachments.isEmpty {
                attachmentTray
            }
            controls
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(
                    dropIsTargeted ? Theme.accent : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard viewModel.shouldHandleImageDrop(urls) else { return false }
            Task { await viewModel.importImageURLs(urls) }
            return true
        } isTargeted: { dropIsTargeted = $0 }
    }

    // MARK: Status

    @ViewBuilder
    private var statusMessages: some View {
        if case let .disconnected(reason) = viewModel.connectionState {
            Text("Can't reach the LLM endpoint (\(reason)). Open App Settings (⌘,) or start your local LLM.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.warningFG)
        }
        if case let .error(message) = viewModel.status {
            Text("Error: \(message)")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.errorFG)
        }
        if viewModel.canResolveImageHistory {
            Button("Resolve Image History…") {
                viewModel.presentImageHistoryResolution()
            }
            .buttonStyle(.link)
            .font(Theme.fontXS)
            .accessibilityIdentifier("chat.composer.resolveImageHistory")
        }
    }

    // MARK: Attachments

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.space2) {
                ForEach(viewModel.pendingAttachments) { attachment in
                    ChatAttachmentThumbnail(
                        attachment: attachment,
                        deliveryState: nil,
                        remove: { viewModel.removePendingAttachment(id: attachment.id) },
                        preview: { viewModel.previewAttachment = attachment }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("chat.composer.attachmentTray")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: Theme.space3) {
            ZStack(alignment: .topLeading) {
                if viewModel.draft.isEmpty {
                    Text("Send a message…")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4 + 4)
                        .padding(.vertical, Theme.space3)
                        .allowsHitTesting(false)
                }
                MacTextEditor(
                    text: $viewModel.draft,
                    isEditable: !viewModel.isComposerLocked,
                    accessibilityID: "chat.composer.field",
                    onSubmit: { viewModel.send() },
                    onContentHeightChange: { contentHeight in
                        editorHeight = min(max(contentHeight + 4, 42), 84)
                    }
                )
                .padding(.horizontal, Theme.space4 - 4)
                .padding(.vertical, 2)
            }
            .frame(height: editorHeight)
            .themeInputField()

            if viewModel.supportsVision {
                Button(action: chooseImages) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isComposerLocked)
                .help("Add images")
                .accessibilityIdentifier("chat.composer.addImages")
            }

            if viewModel.isDictationAvailable {
                micButton
                    .disabled(viewModel.isComposerLocked)
            }

            if viewModel.hasActiveTurn {
                Button(action: { viewModel.cancel() }) {
                    Text("Stop")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space3)
                        .background(Color.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.composer.cancel")
            }

            Button(action: { viewModel.send() }) {
                Text("Send")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space3)
                    .background(sendIsReady ? Theme.accent : Color.gray.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canAttemptSend)
            .accessibilityIdentifier("chat.composer.send")
        }
    }

    /// Send is visually ready only when it will submit immediately.
    private var sendIsReady: Bool {
        viewModel.canAttemptSend && !viewModel.hasActiveTurn
    }

    // MARK: Picker

    /// Open one native multi-image picker for all supported formats.
    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Add Images"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
            + [UTType(filenameExtension: "webp")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        Task { await viewModel.importImageURLs(panel.urls) }
    }

    // MARK: Dictation

    private var micButton: some View {
        Button(action: { viewModel.dictationButtonTapped() }) {
            ZStack {
                Circle()
                    .fill(micButtonBackground)
                    .frame(width: 36, height: 36)
                if viewModel.dictation == .listening {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                        let time = context.date.timeIntervalSinceReferenceDate
                        let scale = 1.0 + 0.25 * (0.5 + 0.5 * sin(time * 4))
                        Circle()
                            .stroke(Theme.errorFG.opacity(0.5), lineWidth: 2)
                            .frame(width: 36, height: 36)
                            .scaleEffect(scale)
                            .opacity(2.0 - scale)
                    }
                }
                Image(systemName: micButtonIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help(micButtonHelp)
        .accessibilityIdentifier("chat.composer.micButton")
        .accessibilityLabel(micButtonHelp)
    }

    private var micButtonIcon: String {
        switch viewModel.dictation {
        case .idle, .unavailable: return "mic.fill"
        case .listening: return "stop.fill"
        case .ready: return "paperplane.fill"
        }
    }

    private var micButtonBackground: Color {
        switch viewModel.dictation {
        case .idle: return Theme.bgTertiary
        case .listening: return Theme.errorFG
        case .ready: return Theme.accent
        case .unavailable: return Color.gray.opacity(0.5)
        }
    }

    private var micButtonHelp: String {
        switch viewModel.dictation {
        case .idle: return "Start dictating"
        case .listening: return "Stop listening"
        case .ready: return "Send dictated message"
        case let .unavailable(message): return message
        }
    }
}

// MARK: - Attachment thumbnail

/// Shared composer/transcript image thumbnail with delivery and removal overlays.
struct ChatAttachmentThumbnail: View {
    let attachment: ChatImageAttachment
    let deliveryState: ChatDeliveryState?
    var remove: (() -> Void)?
    let preview: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                if let image = NSImage(data: attachment.thumbnailData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 80)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            .buttonStyle(.plain)

            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Remove \(attachment.filename)")
            }

            if deliveryState != nil {
                deliveryIndicator
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
        .frame(width: 112, height: 80)
        .help(attachment.filename)
        .accessibilityIdentifier("chat.attachment.\(attachment.id.uuidString)")
    }

    @ViewBuilder
    private var deliveryIndicator: some View {
        switch deliveryState {
        case .pending:
            ProgressView()
                .controlSize(.mini)
                .padding(3)
                .background(.black.opacity(0.45), in: Circle())
        case .accepted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.successFG)
                .background(.black.opacity(0.35), in: Circle())
                .accessibilityLabel("Sent")
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Preview

/// In-window attachment preview backed by the bounded display bitmap.
struct ChatImagePreviewView: View {
    let attachment: ChatImageAttachment
    let close: () -> Void

    var body: some View {
        ModalContainer(title: attachment.filename, onClose: close) {
            Group {
                if let image = NSImage(data: attachment.previewData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("Preview unavailable")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(minWidth: 480, maxWidth: 900, minHeight: 360, maxHeight: 700)
            .padding(Theme.space4)
        }
    }
}
