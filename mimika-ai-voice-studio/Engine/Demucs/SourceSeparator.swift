//
//  SourceSeparator.swift
//  mimika-ai-voice-studio
//
//  Pluggable source separation, used by the Speaker Isolator pipeline to keep background music and ambience alive underneath revoiced speech. Mirrors the `DiarizationProvider` / `STTProvider` shapes. The view model holds `(any SourceSeparator)?`, so `nil` simply means separation is off — no NoOp stub needed.
//
//  Contract:
//    * `separate(_:)` takes an `AudioBuffer`, stereo 44.1 kHz preferred; a backend MAY upmix mono if its model requires stereo. Stems come back at the model's native rate — see `SeparatedStems`.
//    * Empty input THROWS rather than returning empty stems. Diarization needs a sample to align against, and empty stems would report "no speakers found" when the truth is "your file is empty".
//    * `isModelDownloaded()` must be cheap enough for a SwiftUI `body` and must never touch the network.
//    * `ensureModelsReady(progress:)` is the slow path, idempotent, and throws on download or verification failure.
//    * Both `progress` callbacks are `@Sendable`: the UI is on `@MainActor` while the downloader runs off-actor.

import Foundation

protocol SourceSeparator: Sendable {

    // MARK: - Separation

    /// Run the model on `input` and return the vocals and music stems.
    ///
    /// Implementations MAY chunk internally — HTDemucs has a fixed 7.8 s window, so a 5-minute clip is ~38 forward passes. `onProgress` fires BEFORE each chunk with its index, the total, and a rolling ETA (nil on the first chunk, before any timing sample exists).
    func separate(
        _ input: AudioBuffer,
        onProgress: (@Sendable (_ chunk: Int, _ total: Int, _ etaSec: Int?) -> Void)?
    ) async throws -> SeparatedStems

    // MARK: - Model lifecycle

    /// True when the weights are installed and loadable with no further network I/O. Called from a SwiftUI `body`, so no disk hash and no model compile — a sentinel-file check.
    ///
    /// `nonisolated` so the pipeline actor can call it without an `await` hop, despite the project's `-default-isolation MainActor`.
    nonisolated func isModelDownloaded() -> Bool

    /// Download and install the model. A no-op when `isModelDownloaded()` is already true.
    ///
    /// - Parameter progress: fed the `URLSession` download's `Foundation.Progress`; `nil` to just wait for completion.
    ///
    /// - Throws: on any network, SHA, unzip or install failure. On throw NO half-installed state may remain on disk — the implementation cleans its staging dir, see `DemucsModelManager`.
    func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws
}

extension SourceSeparator {
    /// For callers that don't need per-chunk progress.
    func separate(_ input: AudioBuffer) async throws -> SeparatedStems {
        try await separate(input, onProgress: nil)
    }
}
