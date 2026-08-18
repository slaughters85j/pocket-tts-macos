//
//  ThinkTagFilter.swift
//  mimika-ai-voice-studio
//
//  Removes inline `<think>…</think>` spans from a STREAMED content feed.
//
//  Most reasoning models use a separate `reasoning_content` field, which the client handles. The rest inline thoughts in `content` as `<think>` spans, which would otherwise be spoken aloud in a cast member's voice.
//
//  Stateful because tags arrive split across deltas ("<th" then "ink>"): trailing text that could still become a tag is held back until it can't.
//

import Foundation

// MARK: - ThinkTagFilter

/// Streaming filter that drops `<think>…</think>` spans and passes everything else through unchanged.
///
/// Value type with `mutating` methods — one instance per stream, no sharing.
nonisolated struct ThinkTagFilter {

    // MARK: Constants

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    // MARK: State

    /// True once an opening tag has been seen and its close has not yet arrived.
    private var insideThink = false

    /// Text received but not yet safe to emit — it may be the start of a tag.
    private var pending = ""

    // MARK: Init

    init() {}

    // MARK: Filtering

    /// Feeds one streamed delta and returns the text that is safe to emit now.
    mutating func filter(_ delta: String) -> String {
        pending += delta
        var emitted = ""

        while true {
            if insideThink {
                guard let close = pending.range(of: Self.closeTag) else {
                    // Keep only a possible partial closing tag; the rest is thinking, so discard it.
                    pending = Self.trailingPartial(of: pending, matching: Self.closeTag)
                    return emitted
                }
                pending = String(pending[close.upperBound...])
                insideThink = false
                continue
            }

            guard let open = pending.range(of: Self.openTag) else {
                // No tag in flight. Emit everything except a suffix that could still become one.
                let held = Self.trailingPartial(of: pending, matching: Self.openTag)
                emitted += String(pending.dropLast(held.count))
                pending = held
                return emitted
            }
            emitted += String(pending[pending.startIndex..<open.lowerBound])
            pending = String(pending[open.upperBound...])
            insideThink = true
        }
    }

    /// Releases anything still held once the stream ends.
    ///
    /// A held partial tag that never completed was ordinary text, so it is emitted. An unclosed span is discarded — the model was cut off mid-thought and none of that is speakable.
    mutating func flush() -> String {
        defer {
            pending = ""
            insideThink = false
        }
        return insideThink ? "" : pending
    }

    // MARK: Helpers

    /// Longest suffix of `text` that is also a prefix of `tag` — the part that might still become a tag.
    ///
    /// Returns "" when no suffix qualifies. A full occurrence never reaches here; callers handle that case first.
    private static func trailingPartial(of text: String, matching tag: String) -> String {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return "" }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if tag.hasPrefix(suffix) { return suffix }
        }
        return ""
    }
}
