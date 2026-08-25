//
//  MicrophoneRecorder.swift
//  mimika-ai-voice-studio
//
//  Captures mono reference audio from the system microphone for the Voice Manager's "Record Voice" flow. Reuses the same AVAudioEngine input-tap approach as the dictation pipeline (Engine/STT/DictationController) and the already-granted `com.apple.security.device.audio-input` entitlement + NSMicrophoneUsageDescription.
//
//  The audio render thread writes mono samples into a lock-guarded `RecordingSampleSink`; the view model polls it on the main actor for the live level + elapsed time and drains it when recording stops. Capture is capped (default 30 s) so a forgotten recording can't grow unbounded.
//

import AVFoundation

// MARK: - RecordingSampleSink
// Thread-safe bridge between the realtime audio tap (writer) and the main-actor view model (reader). `@unchecked Sendable` because all access is serialized by `lock`.

// `nonisolated` opts the sink out of this module's default-MainActor isolation so the realtime audio tap can call `append` directly; thread-safety is provided by `lock`, hence `@unchecked Sendable`.
nonisolated final class RecordingSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var capped = false
    private var lastLevel: Float = 0

    func reset(capacity: Int) {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: false)
        buffer.reserveCapacity(capacity)
        capped = false
        lastLevel = 0
    }

    /// Down-mix `pcm` to mono and append RAW, stopping at `cap` frames. Runs on the realtime audio thread — keep it allocation-light and lock-brief. Deliberately NO gain and NO waveshaping here: an earlier `tanh(x * 4)` capture boost saturated speech peaks on healthy-level mics, and the baked-in distortion destabilized the voice-clone conditioning (sentence repeats / long pauses / garble). Leveling is linear-only and happens later: a peak normalize at save (`VoiceRecorderViewModel.writeTempWAV`) plus the import path's RMS normalization.
    func append(_ pcm: AVAudioPCMBuffer, cap: Int) {
        guard let channels = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(pcm.format.channelCount)

        var mono = [Float](repeating: 0, count: frames)
        if channelCount <= 1 {
            let src = channels[0]
            for i in 0..<frames { mono[i] = src[i] }
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                mono[i] = sum / Float(channelCount)
            }
        }

        var sumSq: Float = 0
        for v in mono { sumSq += v * v }
        let rms = (sumSq / Float(frames)).squareRoot()

        lock.lock(); defer { lock.unlock() }
        lastLevel = rms
        guard !capped else { return }
        let room = cap - buffer.count
        if room <= 0 { capped = true; return }
        if frames >= room {
            buffer.append(contentsOf: mono[0..<room])
            capped = true
        } else {
            buffer.append(contentsOf: mono)
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    var isCapped: Bool { lock.lock(); defer { lock.unlock() }; return capped }
    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }
    func drain() -> [Float] { lock.lock(); defer { lock.unlock() }; return buffer }
}

// MARK: - MicrophoneRecorder

@MainActor
final class MicrophoneRecorder {

    // MARK: Errors
    enum RecorderError: LocalizedError {
        case engineFailed(Error)

        var errorDescription: String? {
            switch self {
            case let .engineFailed(error):
                return "Couldn't start the microphone: \(error.localizedDescription)"
            }
        }
    }

    let maxSeconds: Double
    private(set) var sampleRate: Double = 44_100
    private(set) var isRecording = false

    /// Capture is unity-gain by design. A previous per-sample `tanh(x * 4.0)` boost (meant to lift quiet USB condenser mics before Int16 quantization) drove healthy-level captures into saturation and baked waveshaping distortion into the voice reference — the review player and quality analyzer both saw the post-tanh samples, so nothing could catch it. Quiet-mic headroom is now recovered LINEARLY at save time (peak normalize in `VoiceRecorderViewModel.writeTempWAV`); the meter applies its own display-side scaling.

    private let engine = AVAudioEngine()
    private let sink = RecordingSampleSink()
    private var capFrames = 0

    init(maxSeconds: Double = 45) {
        self.maxSeconds = maxSeconds
    }

    // MARK: Permission

    /// Resolve microphone authorization, prompting once if undetermined. Mirrors `DictationController.requestAuthorization`'s device-audio check.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: Capture

    func start() throws {
        let input = engine.inputNode
        // `outputFormat(forBus:)` — using `inputFormat` here trips CoreAudio preconditions on some devices (same note as DictationController).
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        capFrames = Int(maxSeconds * sampleRate)
        sink.reset(capacity: capFrames)

        // The tap block runs on the realtime audio thread, so it MUST be nonisolated. Under this module's default-MainActor isolation, a bare closure written inside this @MainActor method is inferred @MainActor — which makes the Swift runtime assert main-queue execution and trap when the audio thread invokes it. Typing the block `@Sendable` forces nonisolation; it captures only Sendable values (the lock-guarded sink + cap), so the audio thread never touches main-actor state.
        let theSink = sink
        let cap = capFrames
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            theSink.append(buffer, cap: cap)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tapBlock)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error)
        }
        isRecording = true
    }

    /// Stop the engine and return the captured mono samples at `sampleRate`.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return sink.drain() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return sink.drain()
    }

    // MARK: Live readouts (polled by the view model)

    var currentFrameCount: Int { sink.count }
    var currentLevel: Float { sink.level }
    var reachedCap: Bool { sink.isCapped }
}
