//
//  SentenceDetector.swift
//  mimika-ai-voice-studio
//
//  Accumulates streamed LLM tokens and emits complete sentences ready for TTS. Algorithm mirrors the Electron app's llm-handler.ts sentence detector:
//
//    * Buffer incoming deltas.
//    * Look for `.!?` followed by whitespace, *but only after* the buffer reaches MIN_SENTENCE_LEN characters.
//    * A `.` additionally has to survive `isSentenceBoundary` — abbreviations and initials are not sentence ends.
//
//  The MIN_SENTENCE_LEN guard is about position only; it was never abbreviation handling despite what this comment used to claim. "Mr. Smith" past character 20 split happily, so "an order from Lt. Commander …" was spoken as "an order from Lt." followed by a multi-second stall while the rest of the line synthesized.
//    * Fallback: hard newline split at HARD_LIMIT chars (don't let one long run-on sentence delay audio forever).
//    * flush() emits whatever's left, regardless of length.

import Foundation

nonisolated final class SentenceDetector {

    private static let minSentenceLength = 20
    private static let hardLimit = 200

    private var buffer: String = ""

    /// Append a delta and return any complete sentences it produced. Multiple sentences in one delta produce multiple results.
    func append(_ delta: String) -> [String] {
        buffer += delta
        var emitted: [String] = []
        while let next = extractSentence() {
            emitted.append(next)
        }
        return emitted
    }

    /// Drain whatever's still in the buffer (call once the LLM stream ends).
    func flush() -> String? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return tail.isEmpty ? nil : tail
    }

    // MARK: - Sentence boundaries

    /// Titles that are essentially always followed by a name, so their `.` is never a sentence end ("Lt. Commander", "Dr. Crusher").
    ///
    /// Deliberately NOT derived from `TextNormalizer.abbreviations`. That map exists to expand abbreviations for pronunciation, which is a different question from "does this period end a sentence", and most of it answers the second one wrong: `Inc.` `Corp.` `Ltd.` `Co.` `St.` `min.` `max.` `avg.` `est.` `approx.` `Jr.` and all twelve months routinely DO close a sentence ("…filed with Acme Corp. Then he left."). Suppressing those merges two sentences into one chunk and delays the first spoken audio — the same symptom this whole fix exists to remove, just in the other direction. Titles are the only entries where the name-continuation is reliable enough to be worth the trade.
    private static let nonTerminalAbbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "rev",
        "lt", "lcpl", "sgt", "cpl", "capt", "cmdr", "col", "gen", "adm", "gov",
    ]

    /// Longest entry above ("lcpl") plus slack — bounds the backward scan.
    private static let maxAbbreviationLength = 6

    /// Whether the terminator at `index` — already known to be followed by whitespace — actually ends a sentence.
    ///
    /// One rule: a known abbreviation or a lone initial before it means it didn't ("Lt. Commander", "J. Smith"). `!` and `?` always split.
    //
    // Land mine: do NOT add "and the next word is lowercase means it didn't". That looks like a free win and is not. It suppresses EVERY period before a lowercase word with no cap, so a turn written in lowercase — a normal register for the Relaxed / Butterfly Chaser presets — yields zero sentences and speaks nothing until `flush()` at end of stream. It also makes streaming and batch disagree: mid-stream the following word is not buffered yet, so the check is skipped and the split happens, while the same text re-fed whole does not split. `truncatedSpokenText` re-segments in batch and takes `prefix(spokenSentences)` from the streaming count, so the divergence makes barge-in keep lines the user never heard.
    private static func isSentenceBoundary(_ chars: [Character], at index: Int) -> Bool {
        guard chars[index] == "." else { return true }

        // Bounded — no abbreviation in the table exceeds "LCpl". Unbounded, this walked the whole preceding run (base64 blobs, CJK with no spaces).
        var start = index
        let floor = max(0, index - Self.maxAbbreviationLength)
        while start > floor, chars[start - 1].isLetter || chars[start - 1].isNumber {
            start -= 1
        }
        guard start < index else { return true }
        let word = String(chars[start..<index])
        // A lone capital is an initial ("J. Smith"), never a sentence end.
        if word.count == 1, word.first?.isUppercase == true { return false }
        return !nonTerminalAbbreviations.contains(word.lowercased())
    }

    // MARK: - Private

    /// Try to pull one complete sentence out of the buffer. Returns nil if no sentence boundary is yet visible.
    private func extractSentence() -> String? {
        guard buffer.count >= Self.minSentenceLength else { return nil }

        // Scan for a terminator (`.`, `!`, `?`) followed by whitespace OR end of buffer (so a final delta with trailing terminator still splits).
        let chars = Array(buffer)
        var splitAt: Int? = nil
        for i in (Self.minSentenceLength - 1)..<chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                let nextIsWhitespace = (i + 1 < chars.count) && chars[i + 1].isWhitespace
                if nextIsWhitespace, Self.isSentenceBoundary(chars, at: i) {
                    splitAt = i
                    break
                }
            }
        }

        if let splitAt {
            let endIndex = buffer.index(buffer.startIndex, offsetBy: splitAt + 1)
            let sentence = String(buffer[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[endIndex...])
            return sentence.isEmpty ? nil : sentence
        }

        // Hard-limit fallback: if we've buffered a *lot* without seeing a terminator, split on the latest newline (or whitespace) past the min-length threshold.
        if buffer.count >= Self.hardLimit {
            if let breakRange = buffer.range(
                of: "\n",
                options: .backwards,
                range: buffer.index(buffer.startIndex, offsetBy: Self.minSentenceLength)..<buffer.endIndex
            ) {
                let sentence = String(buffer[..<breakRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(buffer[breakRange.upperBound...])
                return sentence.isEmpty ? nil : sentence
            }
        }

        return nil
    }
}
