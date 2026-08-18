//
//  ThinkTagFilter.swift
//  mimika-ai-voice-studio
//
//  Removes inline `<think>…</think>` spans from a STREAMED content feed.
//
//  Reasoning models split into two families. Most emit their chain-of-thought on a separate SSE field (`reasoning` / `reasoning_content`), which the client handles on its own. The rest inline it in `content` wrapped in `<think>` tags — and for those the app would otherwise SPEAK the model's thoughts aloud in a cast member's voice.
//
//  Streaming makes this stateful: a tag routinely arrives split across deltas ("<th" then "ink>"), so the filter holds back any trailing text that could still turn into a tag and releases it once it cannot.
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
    /// Held text is emitted only when the stream ended OUTSIDE a think span — a partial `<thi` that never completed was ordinary text after all. An unclosed span is discarded: the model was still thinking when it was cut off, and none of that is speakable.
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
