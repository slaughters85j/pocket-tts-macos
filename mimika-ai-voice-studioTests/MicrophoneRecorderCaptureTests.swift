//
//  MicrophoneRecorderCaptureTests.swift
//  mimika-ai-voice-studioTests
//
//  Regression tests for the raw (unity-gain) mic capture path. The original capture sink applied `tanh(x * 4.0)` per sample, which saturated speech peaks on healthy-level mics and baked waveshaping distortion into the voice reference — the cause of repeats / long pauses / garble on in-app recorded voices. These tests pin the capture as a bit-transparent passthrough, the save-time leveling as strictly linear, and the analyzer thresholds as raw-calibrated.
//

import AVFoundation
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class MicrophoneRecorderCaptureTests: XCTestCase {

    // MARK: - Helpers

    private func monoBuffer(_ samples: [Float], sampleRate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }

    private func stereoBuffer(left: [Float], right: [Float]) -> AVAudioPCMBuffer {
        precondition(left.count == right.count)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
        buf.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
        return buf
    }

    // MARK: - RecordingSampleSink: raw passthrough

    func testMonoCaptureIsBitTransparent() {
        // Values chosen so the old tanh(4x) path would visibly mangle them (0.5 → 0.964, 0.9 → 0.9985); raw capture must return them untouched.
        let input: [Float] = [0.0, 0.05, -0.1, 0.25, -0.5, 0.5, 0.9, -0.9, 1.0]
        let sink = RecordingSampleSink()
        sink.reset(capacity: 64)
        sink.append(monoBuffer(input), cap: 64)
        XCTAssertEqual(sink.drain(), input, "capture must be a raw passthrough — no gain, no waveshaping")
    }

    func testStereoDownmixIsPlainChannelAverage() {
        let left: [Float] = [0.2, -0.4, 0.8, 0.0]
        let right: [Float] = [0.4, -0.2, 0.0, -0.6]
        let sink = RecordingSampleSink()
        sink.reset(capacity: 16)
        sink.append(stereoBuffer(left: left, right: right), cap: 16)
        let mono = sink.drain()
        XCTAssertEqual(mono.count, 4)
        for i in 0..<4 {
            XCTAssertEqual(mono[i], (left[i] + right[i]) / 2, accuracy: 1e-6)
        }
    }

    func testCapTruncatesAndLatches() {
        let sink = RecordingSampleSink()
        sink.reset(capacity: 10)
        sink.append(monoBuffer([Float](repeating: 0.1, count: 16)), cap: 10)
        XCTAssertEqual(sink.count, 10)
        XCTAssertTrue(sink.isCapped)
        // Further appends must be dropped once capped.
        sink.append(monoBuffer([0.2, 0.2]), cap: 10)
        XCTAssertEqual(sink.count, 10)
    }

    // MARK: - Save-time peak normalization (linear only)

    func testPeakNormalizeScalesQuietTakeUp() {
        let out = VoiceRecorderViewModel.peakNormalized([0.1, -0.25, 0.05], targetPeak: 0.708)
        XCTAssertEqual(out[1], -0.708, accuracy: 1e-6)
        // Strictly linear: every sample scaled by the same factor.
        let scale = out[0] / 0.1
        XCTAssertEqual(out[2], 0.05 * scale, accuracy: 1e-6)
    }

    func testPeakNormalizeScalesHotTakeDown() {
        let out = VoiceRecorderViewModel.peakNormalized([0.9, -0.3], targetPeak: 0.708)
        XCTAssertEqual(out[0], 0.708, accuracy: 1e-6)
        XCTAssertEqual(out[1], -0.236, accuracy: 1e-3)
    }

    func testPeakNormalizeIsNoOpForSilence() {
        let silence: [Float] = [0, 0, 0]
        XCTAssertEqual(VoiceRecorderViewModel.peakNormalized(silence, targetPeak: 0.708), silence)
    }

    // MARK: - RecordingQualityAnalyzer: raw-signal calibration

    /// Bursty speech-like signal: alternating 100 ms sine bursts and 100 ms silence, so the SNR estimator sees a clean signal/noise split.
    private func burstySignal(amplitude: Float, seconds: Double = 1.5, sampleRate: Double = 24_000) -> [Float] {
        let total = Int(seconds * sampleRate)
        let burst = Int(0.1 * sampleRate)
        var out = [Float](repeating: 0, count: total)
        for i in 0..<total where (i / burst) % 2 == 0 {
            out[i] = amplitude * sin(2 * .pi * 220 * Float(i) / Float(sampleRate))
        }
        return out
    }

    func testAnalyzerAcceptsHealthyRawLevel() {
        // Raw peaks ~0.15 (RMS ≈ −22 dB): healthy under the raw-signal calibration; the old post-gain thresholds are gone.
        let feedback = RecordingQualityAnalyzer.analyze(samples: burstySignal(amplitude: 0.15), sampleRate: 24_000)
        XCTAssertEqual(feedback.severity, .good, "unexpected: \(feedback.message)")
    }

    func testAnalyzerFlagsGenuinelyQuietRawCapture() {
        let feedback = RecordingQualityAnalyzer.analyze(samples: burstySignal(amplitude: 0.002), sampleRate: 24_000)
        XCTAssertEqual(feedback.severity, .warning)
        XCTAssertTrue(feedback.message.contains("quiet"), "unexpected: \(feedback.message)")
    }

    func testAnalyzerFlagsConverterClipping() {
        // Full-scale peaks are reachable again now that no tanh ceiling sits in front of the analyzer.
        let clipped = burstySignal(amplitude: 1.0)
        let feedback = RecordingQualityAnalyzer.analyze(samples: clipped, sampleRate: 24_000)
        XCTAssertEqual(feedback.severity, .warning)
        XCTAssertTrue(feedback.message.contains("loud"), "unexpected: \(feedback.message)")
    }
}
