//
//  TTSEngineFrameBudgetTests.swift
//  mimika-ai-voice-studioTests
//
//  Regression tests for the K/V state-capacity clamp (TTSEngine.kvFrameBudget) and the VoiceLoader T_voice bound. The AR loop writes K/V at position `tPrompt + step` into a 512-slot state; before the clamp, a long voice prefix (recorded voices bake up to 200 positions) plus a long chunk could push writes past the last slot — a hard SIGABRT on the ANE (MLE5BindEmptyMemoryObjectToPort), silent attention corruption on GPU/CPU.
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class TTSEngineFrameBudgetTests: XCTestCase {

    private let maxSeq = 512        // K.maxSeq (file-private in TTSEngine.swift)
    private let defaultMaxFrames = 256

    // MARK: - kvFrameBudget

    func testShortPromptKeepsFullFrameBudget() {
        // Stock voice (alba, T_voice=125) + a typical 25-token sentence:
        // tPrompt=150 leaves 362 slots — budget stays at maxFrames.
        XCTAssertEqual(TTSEngine.kvFrameBudget(maxFrames: defaultMaxFrames, tPrompt: 150), 256)
    }

    func testStockWorstCaseIsClampedBelowOverflow() {
        // Longest stock prefix (azelma, 161) + max subdivided chunk (120 tokens): tPrompt=281. Unclamped the loop would reach offset 281+255=536 > 512; the budget must stop it at 231.
        let budget = TTSEngine.kvFrameBudget(maxFrames: defaultMaxFrames, tPrompt: 281)
        XCTAssertEqual(budget, 231)
        XCTAssertLessThanOrEqual(281 + budget, maxSeq)
    }

    func testRecordedVoiceWorstCaseIsClampedBelowOverflow() {
        // Recorded/imported voice at the tVoiceMax=200 cap + the model's full 128-token text limit: tPrompt=328 — the field-crash configuration. Budget must be 184 so the last write lands at position 511.
        let budget = TTSEngine.kvFrameBudget(maxFrames: defaultMaxFrames, tPrompt: 328)
        XCTAssertEqual(budget, 184)
        XCTAssertEqual(328 + budget, maxSeq)
    }

    func testCorruptOversizedPromptYieldsZeroNotNegative() {
        // A corrupt voice header claiming a prefix at/past capacity must produce 0 (loop doesn't run), never a negative Range bound.
        XCTAssertEqual(TTSEngine.kvFrameBudget(maxFrames: defaultMaxFrames, tPrompt: maxSeq), 0)
        XCTAssertEqual(TTSEngine.kvFrameBudget(maxFrames: defaultMaxFrames, tPrompt: 600), 0)
    }

    func testCallerMaxFramesStillWinsWhenSmaller() {
        XCTAssertEqual(TTSEngine.kvFrameBudget(maxFrames: 100, tPrompt: 150), 100)
        XCTAssertEqual(TTSEngine.kvFrameBudget(maxFrames: 100, tPrompt: 490), 22)
    }

    func testBudgetNeverAllowsWritePastLastSlot() {
        // Invariant sweep: for every reachable tPrompt, the final write position tPrompt + (budget - 1) stays inside [0, maxSeq).
        for tPrompt in stride(from: 0, through: 700, by: 7) {
            let budget = TTSEngine.kvFrameBudget(maxFrames: defaultMaxFrames, tPrompt: tPrompt)
            XCTAssertGreaterThanOrEqual(budget, 0)
            if budget > 0 {
                XCTAssertLessThan(tPrompt + budget - 1, maxSeq, "overflow at tPrompt=\(tPrompt)")
            }
        }
    }

    // MARK: - VoiceLoader T_voice bound

    /// Build a minimal safetensors blob whose header metadata claims the given T_voice. Tensor data is absent — the T_voice guard runs before any tensor read, so an in-range value fails later with `missingTensor` (proving the guard passed) while an out-of-range value must fail with `badMetadata`.
    private func writeStubSafetensors(tVoice: Int) throws -> URL {
        let info = "{\"voice\": \"stub\", \"T_voice\": \(tVoice), \"n_layers\": 6, \"n_heads\": 16, \"d_head\": 64, \"max_seq\": 512, \"dtype\": \"float16\"}"
        let headerObj: [String: Any] = ["__metadata__": ["info": info]]
        let headerJSON = try JSONSerialization.data(withJSONObject: headerObj)
        var blob = Data()
        var len = UInt64(headerJSON.count).littleEndian
        withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
        blob.append(headerJSON)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-voice-\(tVoice)-\(UUID().uuidString).safetensors")
        try blob.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoaderRejectsOversizedTVoice() throws {
        let url = try writeStubSafetensors(tVoice: 600)
        XCTAssertThrowsError(try VoiceLoader.loadVoice(from: url)) { error in
            guard case VoiceLoaderError.badMetadata = error else {
                return XCTFail("expected badMetadata, got \(error)")
            }
        }
    }

    func testLoaderRejectsNonPositiveTVoice() throws {
        let url = try writeStubSafetensors(tVoice: 0)
        XCTAssertThrowsError(try VoiceLoader.loadVoice(from: url)) { error in
            guard case VoiceLoaderError.badMetadata = error else {
                return XCTFail("expected badMetadata, got \(error)")
            }
        }
    }

    func testLoaderAcceptsMaxLegitimateTVoice() throws {
        // 200 (= PocketTTSVoiceEncoder.tVoiceMax) must pass the metadata guard; the stub has no tensor data so the next failure is missingTensor — which is the proof the T_voice bound accepted it.
        let url = try writeStubSafetensors(tVoice: 200)
        XCTAssertThrowsError(try VoiceLoader.loadVoice(from: url)) { error in
            guard case VoiceLoaderError.missingTensor = error else {
                return XCTFail("expected missingTensor (guard passed), got \(error)")
            }
        }
    }

    // MARK: - Dead (all-zero) KV rejection

    /// Full stub with real tensor payloads in the trimmed `[1, T, 16, 64]` shape. `allZero: true` reproduces the on-disk signature of the macOS 27 GPU bake failure (voice_prompt_phase state reads back entirely zero under .cpuAndGPU).
    private func writeFullStubSafetensors(tVoice: Int, allZero: Bool) throws -> URL {
        let elems = 1 * tVoice * 16 * 64
        let bytesPerTensor = elems * 2
        var tensors: [String: Any] = [:]
        var names: [String] = []
        for i in 0..<6 { names.append("kv_k_\(i)"); names.append("kv_v_\(i)") }
        names.sort()
        var offset = 0
        for n in names {
            tensors[n] = [
                "dtype": "F16",
                "shape": [1, tVoice, 16, 64],
                "data_offsets": [offset, offset + bytesPerTensor],
            ]
            offset += bytesPerTensor
        }
        let info = "{\"voice\": \"stub\", \"T_voice\": \(tVoice), \"n_layers\": 6, \"n_heads\": 16, \"d_head\": 64, \"max_seq\": 512, \"dtype\": \"float16\"}"
        tensors["__metadata__"] = ["info": info]
        let headerJSON = try JSONSerialization.data(withJSONObject: tensors)
        var blob = Data()
        var len = UInt64(headerJSON.count).littleEndian
        withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
        blob.append(headerJSON)
        var payload = [Float16](repeating: 0, count: elems * 12)
        if !allZero { payload[3] = Float16(0.5) }
        payload.withUnsafeBytes { blob.append(contentsOf: $0) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-full-\(allZero)-\(UUID().uuidString).safetensors")
        try blob.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoaderRejectsDeadAllZeroKV() throws {
        let url = try writeFullStubSafetensors(tVoice: 4, allZero: true)
        XCTAssertThrowsError(try VoiceLoader.loadVoice(from: url)) { error in
            guard case let VoiceLoaderError.badMetadata(_, why) = error else {
                return XCTFail("expected badMetadata, got \(error)")
            }
            XCTAssertTrue(why.contains("empty"), "unexpected reason: \(why)")
        }
    }

    func testLoaderAcceptsVoiceWithAnyNonZeroKV() throws {
        let url = try writeFullStubSafetensors(tVoice: 4, allZero: false)
        let voice = try VoiceLoader.loadVoice(from: url)
        XCTAssertEqual(voice.tVoice, 4)
    }

    func testKVIsAllZeroDetector() {
        let zero: [String: [Float16]] = ["kv_k_0": [0, 0, 0], "kv_v_0": [0, 0, 0]]
        XCTAssertTrue(PocketTTSVoiceEncoder.kvIsAllZero(zero))
        var live = zero
        live["kv_v_0"] = [0, Float16(0.25), 0]
        XCTAssertFalse(PocketTTSVoiceEncoder.kvIsAllZero(live))
    }
}
