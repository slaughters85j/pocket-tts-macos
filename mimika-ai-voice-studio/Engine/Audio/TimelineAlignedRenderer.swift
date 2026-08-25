//
//  TimelineAlignedRenderer.swift
//  mimika-ai-voice-studio
//
//  Synthesizes each transcribed segment independently and composites them into one master PCM buffer at their ORIGINAL start timestamps, so output length matches the input exactly and every utterance stays lip-synced. The alternative — SilencePreservingScriptBuilder plus a single synthesize call — keeps pause durations intact but lets total length drift with the voice's pace.
//
//  A segment's slot runs from its `startSec` to the NEXT segment's `startSec`, not its own `endSec`. A slow voice can therefore spill into the following silence before truncation bites, which clips less while still pinning every start.
//
//  With `matchOriginalPace` on, each take is measured against min(slot, original span + 0.35 s drift budget); the slot alone under-constrains a segment followed by a long gap and lets its end drift ~1 s off the lips.
//      overshoot ≤ 1.05  → passthrough, the cross-fade absorbs it
//      overshoot > 1.05  → compress by min(overshoot, 1.30), WSOLA's quality ceiling; anything past the slot clips with a fade
//  Pace-off bypasses the gate and clips on every overshoot.
//
//  Two refinements, pace-on only. ELASTIC CHAINING: a chunk may start where the previous chunk's audio actually ended, bounded by `chainMaxDeviationSec`, with its slot extended by the same amount — so a sentence's chunks share its slack instead of each compressing alone at a zero-slack boundary. ONSET GUARD: compression never touches a chunk's first `onsetGuardSec`, where WSOLA artifacts are most audible.

import Foundation

nonisolated enum TimelineAlignedRenderer {

    static let sampleRate: Int = 24_000

    // MARK: - Pace-quality tuning (WP-VIT-1)

    /// Elastic-chaining bound: how far a segment's START may be pushed LATER than its original timestamp when the previous same-speaker segment's audio spilled past it. Back-to-back capped chunks (zero slack after the 1.5 s drift cap) were the main source of clip-with-fade word loss — chaining lets a run of chunks borrow slack from the whole sentence while keeping every chunk's start within this bound of the original (inside the timing-QA loop's 0.5 s tolerance, so drift stays caught). Applies only when `matchOriginalPace` is on; pace-off keeps pristine placement.
    static let chainMaxDeviationSec: Double = 0.35

    /// Onset guard forwarded to `WSOLATimeCompressor.compress`: the first stretch of each compressed segment passes through 1:1 so the voice onset (transient, aperiodic — where WSOLA artifacts are most audible as a scratchy line front) is never compressed.
    static let onsetGuardSec: Double = 0.2

    /// Best-of-N synthesis budget: total takes allowed per segment when a take overshoots its slot past the 1.60× clip-with-fade zone (pace-on only). The shortest take is kept. Re-rolls cost synth time only on offending segments; measured length swing on identical text is large enough that one re-roll usually clears the clip zone (observed 2.72 s vs 1.63 s for the same words).
    static let maxSynthTakes: Int = 3

    /// Where a segment may actually start: at its original timestamp, or later if the previous segment's audio (`nextAvailable`) spilled past it — but never more than `maxDeviation` late, and never earlier than the original. Pure; unit-tested.
    static func chainedOffset(
        original: Int,
        nextAvailable: Int,
        maxDeviation: Int
    ) -> Int {
        min(max(original, nextAvailable), original + maxDeviation)
    }

    /// Render `segments` into a master PCM buffer that's exactly `totalDurationSec` long. Each segment is synthesized independently and copied into the master at its original `startSec` offset; segments that overrun their slot are truncated.
    ///
    /// - Parameters:
    ///   - segments: chronologically sorted internally.
    ///   - totalDurationSec: input-audio length; defines the master buffer size. Must be > 0.
    ///   - voiceID: passed through to the engine.
    ///   - engine: any TTSEngineProtocol implementation (Pocket-TTS, Fish — both work).
    ///   - options: forwarded to engine.synthesize per segment.
    ///   - onProgress: optional callback `(currentSegment, totalSegments)` fired as each segment begins synthesis. Caller uses this to drive a determinate progress bar.
    ///
    /// - Returns: 24 kHz mono Float32 [-1, +1] sample buffer of exactly `Int(totalDurationSec * 24_000)` samples. Returns an empty array if `totalDurationSec <= 0`.
    static func render(
        segments: [TranscribedSegment],
        totalDurationSec: Double,
        voiceID: String,
        engine: any TTSEngineProtocol,
        options: SynthesisOptions = SynthesisOptions(),
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> [Float] {
        guard totalDurationSec > 0 else { return [] }

        let totalSamples = Int(totalDurationSec * Double(sampleRate))
        var master = [Float](repeating: 0.0, count: totalSamples)

        let sorted = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startSec < $1.startSec }
        let total = sorted.count

        // Elastic chaining state: the sample index where the previous segment's placed audio actually ended. Only consulted when `matchOriginalPace` is on.
        var nextAvailableOffset = 0
        let maxDeviationSamples = Int(chainMaxDeviationSec * Double(sampleRate))

        for (i, segment) in sorted.enumerated() {
            if Task.isCancelled { break }
            onProgress?(i + 1, total)

            // Strip known STT non-speech markers ([music], [silence], [laughter], etc.) before sending to TTS — otherwise the synthesizer speaks them literally ("bracket music bracket"). The stripping is a fixed-whitelist pass so it won't touch legitimate bracketed content like pause markers; see TextNormalizer.stripWhisperArtifacts.
            let cleaned = TextNormalizer.stripWhisperArtifacts(segment.text)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            // If stripping left nothing (the segment was purely an artifact like just "[music]"), skip — would emit dead air at the segment offset instead of a "bracket music bracket" reading.
            if trimmed.isEmpty { continue }

            // 1. Offset and slot, computed BEFORE synthesis so a bad take can be re-rolled against its real slot. Pace-on chains elastically: the slot extends by the spill, and the next chunk is pushed by exactly that much, so regions never overlap.
            let originalOffset = Int(segment.startSec * Double(sampleRate))
            let offsetSamples = options.matchOriginalPace
                ? chainedOffset(original: originalOffset,
                                nextAvailable: nextAvailableOffset,
                                maxDeviation: maxDeviationSamples)
                : originalOffset
            guard offsetSamples >= 0, offsetSamples < totalSamples else { continue }
            if offsetSamples > originalOffset {
                print(String(format: "[Renderer] seg %d/%d: chained start +%.2fs (previous segment spilled)",
                             i + 1, total,
                             Double(offsetSamples - originalOffset) / Double(sampleRate)))
            }

            let slotEndSamples: Int = {
                if i + 1 < sorted.count {
                    let nextOriginal = Int(sorted[i + 1].startSec * Double(sampleRate))
                    // Pace-on: the next chunk can absorb up to maxDeviation of push, so this chunk may run that far past the next original start. Last chunk (and pace-off) never extends past hard limits.
                    return options.matchOriginalPace
                        ? min(nextOriginal + maxDeviationSamples, totalSamples)
                        : nextOriginal
                } else {
                    return totalSamples
                }
            }()
            let slotSampleCount = max(0, slotEndSamples - offsetSamples)

            // Pace-fit TARGET: bound the segment's END drift by the same +chainMaxDeviationSec budget that bounds its start. The slot alone is the wrong target when it's much larger than the segment (last segment of a speaker, segment before a long gap, cap-exempt number runs): the synth then plays out at natural length and the segment's END drifts unboundedly off the lips (measured ~1 s on a protected year phrase). For back-to-back chunks slot < span+budget, so the min keeps the validated chaining behavior unchanged there.
            let spanSamples = max(0, Int((segment.endSec - segment.startSec) * Double(sampleRate)))
            let pacedTargetSamples = max(1, min(slotSampleCount,
                                                spanSamples + maxDeviationSamples))

            // 2. Synthesize, best-of-N. Sampling swings a segment's length ±40% on identical text, and one long roll lands in the clip zone where words get discarded, so a would-be clip re-rolls up to `maxSynthTakes` and keeps the shortest.
            var segSamples: [Float] = []
            var takes = 0
            while true {
                var take: [Float] = []
                let stream = engine.synthesize(text: trimmed, voiceID: voiceID, options: options)
                for await frame in stream {
                    if Task.isCancelled { break }
                    take.append(contentsOf: frame.samples)
                    if frame.isFinal { break }
                }
                if Task.isCancelled { break }
                takes += 1
                if segSamples.isEmpty || (!take.isEmpty && take.count < segSamples.count) {
                    segSamples = take
                }
                guard options.matchOriginalPace,
                      slotSampleCount > 0,
                      !segSamples.isEmpty,
                      takes < maxSynthTakes,
                      Double(segSamples.count) > 1.60 * Double(pacedTargetSamples)
                else { break }
                print(String(format: "[Renderer] seg %d/%d: take %d overshoots %.2fx (>1.60x of paced target) → re-rolling",
                             i + 1, total, takes,
                             Double(segSamples.count) / Double(pacedTargetSamples)))
            }
            if Task.isCancelled { break }

            // 2.5. Pace-fit gate against the paced target rather than the raw slot, so a segment with a huge slot is still pulled back toward the original lips. Chronic takes get the 1.30x compression BEFORE the slot clip, so more words survive the fade.
            if options.matchOriginalPace,
               slotSampleCount > 0,
               Double(segSamples.count) > 1.05 * Double(pacedTargetSamples) {
                let overshoot = Double(segSamples.count) / Double(pacedTargetSamples)
                let targetSec = Double(pacedTargetSamples) / Double(sampleRate)
                let synthSec = Double(segSamples.count) / Double(sampleRate)
                let ratio = min(overshoot, 1.30)
                print(String(format: "[Renderer] seg %d/%d: target=%.2fs synth=%.2fs overshoot=%.2fx → compress @ %.2fx%@",
                             i + 1, total, targetSec, synthSec, overshoot, ratio,
                             overshoot > 1.60 ? " (chronic — residual clips at the slot)" : ""))
                // Onset guard: never compress the (transient, aperiodic) first stretch — that's where WSOLA artifacts read as a scratchy line front.
                segSamples = WSOLATimeCompressor.compress(
                    segSamples,
                    ratio: ratio,
                    onsetGuardSamples: Int(onsetGuardSec * Double(sampleRate))
                )
            }

            let copyCount = min(segSamples.count, slotSampleCount, totalSamples - offsetSamples)
            guard copyCount > 0 else { continue }

            // 3. Copy into master, optionally with an 80 ms cross-fade in/out so truncated tails don't click. The fades only matter when the synth overruns the slot (we're cutting off mid-syllable); when synth is shorter than the slot the natural EOS tail in segSamples already handles decay.
            let fadeSamples = min(1920, copyCount)  // 80 ms @ 24 kHz
            for j in 0..<copyCount {
                var sample = segSamples[j]
                // Fade-in over the first `fadeSamples` so a leading attack doesn't pop. Mostly a no-op since TTS frames start at zero, but cheap insurance.
                if j < fadeSamples {
                    let ramp = Float(j) / Float(fadeSamples)
                    sample *= ramp
                }
                // Fade-out over the last `fadeSamples` when we're actually truncating (segSamples ran longer than the copied region). If we're copying the full segSamples the natural decay handles it.
                if segSamples.count > copyCount {
                    let tailIndex = copyCount - 1 - j
                    if tailIndex < fadeSamples {
                        let ramp = Float(tailIndex) / Float(fadeSamples)
                        sample *= ramp
                    }
                }
                master[offsetSamples + j] = sample
            }

            // Elastic-chaining bookkeeping: the next chunk may start where this one's audio actually ended (bounded above).
            nextAvailableOffset = offsetSamples + copyCount
        }

        return master
    }
}
