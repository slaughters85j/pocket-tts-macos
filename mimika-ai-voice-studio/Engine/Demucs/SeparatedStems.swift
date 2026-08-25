//
//  SeparatedStems.swift
//  mimika-ai-voice-studio
//
//  Result of running a `SourceSeparator`: `vocals` feeds diarization and per-speaker isolation, and `music` — everything else, summed per channel — rides through to the Background `SpeakerTrack` so audio underneath revoiced speech survives.
//
//  Both stems stay at HTDemucs's native 44.1 kHz stereo for the whole isolation and revoice path. Do NOT narrow this back to mono or 24 kHz: that was the original contract and it cost ~5 LU against the source mix, because the `(L+R)/2` downmix cancels energy on uncorrelated stereo content and the resample discards the 12–22 kHz octave.
//
//  The price is memory — roughly 635 MB per stem for a 30-minute clip against 85 MB at mono 24 kHz. Start here when profiling working-set.

import Foundation

// MARK: - SeparatedStems

/// Two stereo 44.1 kHz Float32 PCM buffers plus the metadata downstream length checks need.
///
/// `nonisolated` because it is pure data; without the opt-out it inherits MainActor isolation from the project's `SWIFT_DEFAULT_ACTOR_ISOLATION` and `actor DemucsSourceSeparator` needs a hop on every produce.
nonisolated struct SeparatedStems: Sendable, Equatable {

    // MARK: - Fields

    /// Lead-vocal stem. Channels 6 (L) and 7 (R) of HTDemucs's flattened `[1, 8, T]` output, OLA-stitched at the source rate.
    let vocals: AudioBuffer

    /// Background stem: HTDemucs's drums, bass and "other" SUMMED per channel — music, ambience and SFX alike.
    ///
    /// Sum, never average. Averaging drops the background ~9.5 dB against vocals and erases the very preservation the user paid the separation cost for. Headroom and soft-clip are handled downstream in `MultiSpeakerRevoicer`'s final sum.
    let music: AudioBuffer

    // MARK: - Derived

    /// Hz. Always `44_100` — HTDemucs's native rate.
    var sampleRate: Int { vocals.sampleRate }

    /// Sample count per channel. The init guarantees both stems match; reading `vocals` keeps a downstream length check deterministic on the stem the pipeline actually consumes.
    var sampleCount: Int { vocals.sampleCount }

    /// Duration in seconds.
    var durationSec: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / Double(sampleRate)
    }

    // MARK: - Init

    /// Asserts both stems share channel count, length and sample rate. Production always produces stereo at 44.1; the channel count is not pinned so mock separators can pass mono without a stereo upmix at the call site.
    init(vocals: AudioBuffer, music: AudioBuffer) {
        precondition(
            vocals.channelCount == music.channelCount,
            "SeparatedStems requires matching channel counts (got " +
            "vocals.channelCount=\(vocals.channelCount) " +
            "music.channelCount=\(music.channelCount))"
        )
        precondition(
            vocals.sampleCount == music.sampleCount,
            "SeparatedStems requires equal-length stems (got " +
            "vocals=\(vocals.sampleCount) music=\(music.sampleCount))"
        )
        precondition(
            vocals.sampleRate == music.sampleRate,
            "SeparatedStems requires equal sample rates (got " +
            "vocals=\(vocals.sampleRate) music=\(music.sampleRate))"
        )
        self.vocals = vocals
        self.music = music
    }

    /// Legacy convenience init for tests + mock separators that produce mono [Float] PCM. Wraps each array in `AudioBuffer.mono(...)` at the supplied sample rate. The `MockSourceSeparator` and the older test fixtures use this path; production code uses the AudioBuffer designated init.
    init(vocals: [Float], music: [Float], sampleRate: Int) {
        self.init(
            vocals: AudioBuffer.mono(vocals, sampleRate: sampleRate),
            music: AudioBuffer.mono(music, sampleRate: sampleRate)
        )
    }
}
