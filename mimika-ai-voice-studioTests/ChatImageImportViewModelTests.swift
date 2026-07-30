//
//  ChatImageImportViewModelTests.swift
//  mimika-ai-voice-studioTests
//

import AppKit
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class ChatImageImportViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsStore.resetToDefaults()
    }

    override func tearDown() {
        SettingsStore.resetToDefaults()
        super.tearDown()
    }

    func test_importAggregatesRejectionsAndRejectsPendingOrHistoricalDuplicates() async throws {
        let viewModel = try makeViewModel()
        let valid = try makePNG(red: 10)

        await viewModel.importImagePayloads([
            (filename: "valid.png", data: valid, error: nil),
            (filename: "bad.gif", data: Data("GIF89a".utf8), error: nil),
            (filename: "missing.png", data: nil, error: "missing.png could not be read.")
        ])
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("bad.gif") == true)
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("missing.png") == true)

        await viewModel.importImagePayloads([
            (filename: "pending-copy.png", data: valid, error: nil)
        ])
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("already in this chat") == true)

        viewModel.messages = [
            ChatMessage(
                role: .user,
                attachments: viewModel.pendingAttachments,
                deliveryState: .accepted
            )
        ]
        viewModel.pendingAttachments.removeAll()
        await viewModel.importImagePayloads([
            (filename: "history-copy.png", data: valid, error: nil)
        ])
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("already in this chat") == true)
    }

    func test_importCapsDeterministicValidBatchAtTen() async throws {
        let viewModel = try makeViewModel()
        let payloads = try (0..<11).map { index in
            (
                filename: "\(index).png",
                data: Optional(try makePNG(red: UInt8(index))),
                error: Optional<String>.none
            )
        }

        await viewModel.importImagePayloads(payloads)

        XCTAssertEqual(viewModel.pendingAttachments.count, 10)
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("at most 10") == true)
    }

    func test_dropPreflightRejectsUnavailableOrUnsupportedTransfers() throws {
        let viewModel = try makeViewModel()
        let pngURL = URL(fileURLWithPath: "/tmp/image.png")
        let gifURL = URL(fileURLWithPath: "/tmp/image.gif")

        viewModel.capabilityState = .unknown
        XCTAssertFalse(viewModel.shouldHandleImageDrop([pngURL]))
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("does not support Vision") == true)

        viewModel.capabilityState = ModelCapabilityState(
            authoritative: [.vision],
            forced: [],
            freshness: .current
        )
        XCTAssertFalse(viewModel.shouldHandleImageDrop([gifURL]))
        XCTAssertTrue(viewModel.appState.toastMessage?.contains("Only PNG") == true)
        XCTAssertTrue(viewModel.shouldHandleImageDrop([pngURL]))
    }

    // MARK: - Helpers

    private func makeViewModel() throws -> ChatViewModel {
        var settings = ChatSettings.default
        settings.model = "m"
        let appState = AppState()
        try appState.applyChatConfiguration(settings, endpointBaseURL: settings.baseURL)
        let viewModel = ChatViewModel(
            engine: ImportEmptyEngine(),
            player: ImportPlayer(),
            settings: settings,
            appState: appState
        )
        viewModel.capabilityState = ModelCapabilityState(
            authoritative: [.vision],
            forced: [],
            freshness: .current
        )
        return viewModel
    }

    private func makePNG(red: UInt8) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        bytes[0] = red
        bytes[1] = 20
        bytes[2] = 30
        bytes[3] = 255
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private struct ImportEmptyEngine: TTSEngineProtocol {
    nonisolated func availableVoiceIDs() -> [String] { ["cosette"] }

    nonisolated func synthesize(
        text: String,
        voiceID: String,
        options: SynthesisOptions
    ) -> AsyncStream<PCMFrame> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class ImportPlayer: ChatAudioPlaying, @unchecked Sendable {
    func play(stream: AsyncStream<PCMFrame>) async throws {}
    func stop() async {}
}
