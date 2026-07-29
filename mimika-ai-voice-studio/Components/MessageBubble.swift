//
//  MessageBubble.swift
//  mimika-ai-voice-studio
//
//  Per-message chat bubble. User bubbles are right-aligned in Apple blue;
//  assistant bubbles are left-aligned in the app accent.

import Foundation
import SwiftUI

// MARK: - Message bubble

/// Directional chat bubble for one visible Solo Chat message.
struct MessageBubble: View {
    let message: ChatMessage
    var isResponding = false
    var canModify = true
    var onPreviewImage: (ChatImageAttachment) -> Void = { _ in }
    var onEdit: (ChatMessage) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }

    @State private var isHovered = false

    @ScaledMetric(relativeTo: .body) private var bubbleRadius: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var tailWidth: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var tailDrop: CGFloat = 7
    @ScaledMetric(relativeTo: .body) private var horizontalPadding: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    var body: some View {
        if message.role == .system {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 60)
                }

                VStack(
                    alignment: message.role == .user ? .trailing : .leading,
                    spacing: Theme.space2
                ) {
                    if !message.attachments.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 112, maximum: 112))],
                            spacing: Theme.space2
                        ) {
                            ForEach(message.attachments) { attachment in
                                ChatAttachmentThumbnail(
                                    attachment: attachment,
                                    deliveryState: message.deliveryState,
                                    preview: { onPreviewImage(attachment) }
                                )
                            }
                        }
                    }

                    if message.role == .assistant,
                       isResponding,
                       displayedContent.isEmpty {
                        AssistantResponseShimmer()
                    } else if message.role == .assistant, !displayedContent.isEmpty {
                        AssistantMarkdownText(source: displayedContent)
                    } else if !displayedContent.isEmpty {
                        Text(displayedContent)
                            .font(Theme.fontSM)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.leading, leadingPadding)
                .padding(.trailing, trailingPadding)
                .padding(.top, verticalPadding)
                .padding(.bottom, verticalPadding + tailDrop)
                .background {
                    ChatBubbleShape(
                        side: bubbleSide,
                        cornerRadius: bubbleRadius,
                        tailWidth: tailWidth,
                        tailDrop: tailDrop
                    )
                    .fill(bubbleColor)
                }
                .frame(maxWidth: 560, alignment: alignment)

                if message.role == .assistant {
                    Spacer(minLength: 60)
                }
            }
            .padding(.bottom, 29)
            .overlay(
                alignment: message.role == .user ? .bottomTrailing : .bottomLeading
            ) {
                ChatMessageActionBar(
                    message: message,
                    canModify: canModify,
                    onEdit: { onEdit(message) },
                    onDelete: { onDelete(message.id) }
                )
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityIdentifier("chat.message.\(message.id.uuidString)")
        }
    }

    /// Leading response whitespace is hidden without rewriting transcript history.
    private var displayedContent: String {
        String(message.content.drop(while: { $0.isWhitespace }))
    }

    private var bubbleColor: Color {
        message.role == .user
            ? Color(red: 0.0, green: 0.478, blue: 1.0)
            : Theme.accent
    }

    private var leadingPadding: CGFloat {
        horizontalPadding + (message.role == .assistant ? tailWidth : 0)
    }

    private var trailingPadding: CGFloat {
        horizontalPadding + (message.role == .user ? tailWidth : 0)
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleSide: ChatBubbleSide {
        message.role == .user ? .right : .left
    }
}

// MARK: - Assistant response state

/// Temporary response label with the standard left-to-right shimmer effect.
private struct AssistantResponseShimmer: View {
    private let label = "Model responding to user"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(label)
            .font(Theme.fontSM)
            .foregroundStyle(Color.white.opacity(reduceMotion ? 0.68 : 0.38))
            .overlay {
                if !reduceMotion {
                    ShimmerHighlight(label: label)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(label)
    }
}

/// Animated translucent-to-opaque gradient band masked to the response label.
private struct ShimmerHighlight: View {
    let label: String

    @State private var isInitialState = true

    var body: some View {
        Text(label)
            .font(Theme.fontSM)
            .foregroundStyle(Color.white)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.35), location: 0.3),
                        .init(color: .white, location: 0.5),
                        .init(color: .white.opacity(0.35), location: 0.7),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: isInitialState
                        ? UnitPoint(x: -0.3, y: 0.5)
                        : UnitPoint(x: 1, y: 0.5),
                    endPoint: isInitialState
                        ? UnitPoint(x: 0, y: 0.5)
                        : UnitPoint(x: 1.3, y: 0.5)
                )
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                        .delay(0.25)
                        .repeatForever(autoreverses: false)
                ) {
                    isInitialState = false
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Bubble shape

/// Side where the integrated bubble tail points toward its speaker.
private nonisolated enum ChatBubbleSide {
    case left
    case right
}

/// One continuous rounded outline with a curved tail in its lower corner.
private nonisolated struct ChatBubbleShape: Shape {
    let side: ChatBubbleSide
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailDrop: CGFloat

    func path(in rect: CGRect) -> Path {
        let rightPath = rightFacingPath(in: rect)
        guard side == .left else { return rightPath }

        let mirror = CGAffineTransform(translationX: rect.width, y: 0)
            .scaledBy(x: -1, y: 1)
        return rightPath.applying(mirror)
    }

    /// Build once for a right-facing bubble; left-facing bubbles mirror it exactly.
    private func rightFacingPath(in rect: CGRect) -> Path {
        let bodyWidth = max(0, rect.width - tailWidth)
        let bodyHeight = max(0, rect.height - tailDrop)
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: bodyWidth,
            height: bodyHeight
        )
        let radius = min(
            cornerRadius,
            body.width / 2,
            body.height / 2
        )
        let tailRise = min(max(15, radius * 0.95), max(0, body.height - radius))
        let tailBase = min(10, max(8, radius * 0.55))
        let tip = CGPoint(x: rect.maxX, y: rect.maxY)

        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))

        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.minY + radius),
            control: CGPoint(x: body.maxX, y: body.minY)
        )

        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - tailRise))
        path.addCurve(
            to: tip,
            control1: CGPoint(
                x: body.maxX,
                y: body.maxY - tailRise * 0.1
            ),
            control2: CGPoint(
                x: tip.x - tailWidth * 0.1,
                y: tip.y - tailDrop * 0.15
            )
        )
        path.addCurve(
            to: CGPoint(x: body.maxX - tailBase, y: body.maxY),
            control1: CGPoint(
                x: tip.x - tailWidth * 0.2,
                y: tip.y
            ),
            control2: CGPoint(
                x: body.maxX - tailBase * 0.1,
                y: body.maxY
            )
        )

        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.maxY - radius),
            control: CGPoint(x: body.minX, y: body.maxY)
        )

        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + radius, y: body.minY),
            control: CGPoint(x: body.minX, y: body.minY)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Assistant Markdown

/// Native Markdown prose plus distinct fenced code panels for assistant replies.
private struct AssistantMarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .prose(markdown):
                    Text(attributedMarkdown(markdown))
                        .font(Theme.fontSM)
                        .foregroundStyle(.white)
                        .tint(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .code(_, content):
                    Text(content.isEmpty ? " " : content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.space2)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }

    private var segments: [ChatMarkdownSegment] {
        ChatMarkdownParser.parse(source)
    }

    /// Parse inline and block Markdown attributes, falling back to literal prose.
    private func attributedMarkdown(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}
