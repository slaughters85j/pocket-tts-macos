//
//  SilencePreservingScriptBuilder.swift
//  mimika-ai-voice-studio
//
//  Rebuilds a diarized transcript as a script the TTSEngine already understands, emitting `[Xs]` pause markers between text segments so the original gaps survive. `TextNormalizer.parsePauseMarkers` → `TTSEngine.yieldSilence` renders those markers as zero-filled PCM with 80 ms boundary fades, so speech lands at roughly its original position with no buffer pre-allocation.
//
//  Roughly, not exactly: synthesized speech length varies, so a segment that outruns the gap before the next one pushes everything after it to the right. When the timeline has to hold exactly — video lip-sync — use `TimelineAlignedRenderer`, which synthesizes per segment into a pre-allocated master at fixed offsets.
//
//  Pure logic — no I/O, no actor isolation.

import Foundation

nonisolated enum SilencePreservingScriptBuilder {

    /// Minimum gap, in seconds, that is emitted as an explicit `[Xs]` pause marker. Shorter gaps are folded into the surrounding text (a single space). 50 ms matches the typical human gap-perception floor and is comfortably above STT segmentation jitter.
    static let defaultMinSilenceSec: Double = 0.05

    /// Build a TTSEngine-compatible script from timestamped transcription segments. The resulting string can be passed directly to `TTSEngine.synthesize(text:voiceID:options:)`.
    ///
    /// - Parameters:
    ///   - segments: Transcribed utterances in any order. Sorted internally.
    ///   - totalDurationSec: When non-nil, a trailing `[Xs]` is appended if the input audio extends past the last segment by at least `minSilenceSec`. When nil, no trailing pause is emitted.
    ///   - minSilenceSec: Gap floor (see `defaultMinSilenceSec`).
    ///
    /// - Returns: A script like `"[1.5s] Hello there [0.3s] friend [0.8s]"`. Empty segments are skipped without advancing the cursor (their time is folded into the surrounding gap, matching the Python container's pre-silence semantics).
    static func build(
        segments: [TranscribedSegment],
        totalDurationSec: Double? = nil,
        minSilenceSec: Double = defaultMinSilenceSec
    ) -> String {
        let sorted = segments.sorted { $0.startSec < $1.startSec }

        var script = ""
        var cursor: Double = 0

        for segment in sorted {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let gap = segment.startSec - cursor
            if gap >= minSilenceSec {
                if !script.isEmpty { script += " " }
                script += "[\(formatSeconds(gap))s]"
            }

            if !script.isEmpty { script += " " }
            script += trimmed

            // max(...) handles the (rare) overlap case from multi-speaker inputs — Python's pydub `overlay` lets later segments replace earlier audio at the same position, "last wins". We instead refuse to regress the cursor so the script emits both segments without backtracking. Single-speaker STT (the primary Voice Changer use case) never overlaps.
            cursor = max(cursor, segment.endSec)
        }

        if let total = totalDurationSec {
            let trailing = total - cursor
            if trailing >= minSilenceSec {
                if !script.isEmpty { script += " " }
                script += "[\(formatSeconds(trailing))s]"
            }
        }

        return script
    }

    /// Format a duration with at most two decimals, stripping trailing zeros so "1.00s" becomes "1s" and "1.50s" becomes "1.5s". Both forms are accepted by the `\[(\d+(?:\.\d+)?)s\]` parser regex in MultiTalkScriptParser / TextNormalizer.parsePauseMarkers.
    static func formatSeconds(_ s: Double) -> String {
        let formatted = String(format: "%.2f", s)
        var trimmed = formatted
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }
}
