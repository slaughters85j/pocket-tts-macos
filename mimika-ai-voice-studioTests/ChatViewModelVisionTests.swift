//
//  ChatViewModelVisionTests.swift
//  mimika-ai-voice-studioTests
//

import Observation
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class ChatViewModelVisionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsStore.resetToDefaults()
        LLMStubURLProtocol.reset()
    }

    override func tearDown() {
        SettingsStore.resetToDefaults()
        LLMStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Delivery lifecycle

    func test_preAcceptanceHTTPFailureRestoresExactComposer() async throws {
        let (viewModel, _, _) = try makeViewModel()
        let attachment = makeAttachment(filename: "one.png")
        viewModel.draft = "  original text  "
        viewModel.pendingAttachments = [attachment]
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")

        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        XCTAssertTrue(viewModel.isComposerLocked)
        XCTAssertEqual(viewModel.messages.first?.deliveryState, .pending)

        LLMStubURLProtocol.releaseHeaders(statusCode: 500)
        LLMStubURLProtocol.emit(Data("rejected".utf8))
        LLMStubURLProtocol.finish()
        await assertEventually { viewModel.activeTurn == nil }

        XCTAssertEqual(viewModel.draft, "  original text  ")
        XCTAssertEqual(viewModel.pendingAttachments, [attachment])
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func test_cancelBeforeAcceptanceIgnoresLateAcceptanceAndRestoresComposer() async throws {
        let (viewModel, _, _) = try makeViewModel()
        let attachment = makeAttachment(filename: "cancelled.png")
        viewModel.draft = "restore me"
        viewModel.pendingAttachments = [attachment]
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")

        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        viewModel.cancel()
        LLMStubURLProtocol.releaseHeaders()
        LLMStubURLProtocol.emit(sseChunk("must be ignored"))
        LLMStubURLProtocol.finish()
        await assertEventually { viewModel.activeTurn == nil }

        XCTAssertEqual(viewModel.draft, "restore me")
        XCTAssertEqual(viewModel.pendingAttachments, [attachment])
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(LLMStubURLProtocol.cancellationObserved)
    }

    func test_postAcceptanceFailureRetainsImagesAndPartialTextWithoutTouchingNextDraft() async throws {
        let (viewModel, _, _) = try makeViewModel()
        viewModel.pendingAttachments = [makeAttachment(filename: "sent.png")]
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")

        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        let composerUnlocked = expectation(
            description: "Accepted turn invalidates the composer lock"
        )
        withObservationTracking {
            _ = viewModel.isComposerLocked
        } onChange: {
            composerUnlocked.fulfill()
        }
        LLMStubURLProtocol.releaseHeaders()
        await fulfillment(of: [composerUnlocked], timeout: 1)
        await assertEventually {
            viewModel.messages.first?.deliveryState == .accepted
        }
        XCTAssertFalse(viewModel.isComposerLocked)

        viewModel.draft = "next draft"
        let messageCount = viewModel.messages.count
        viewModel.send()
        XCTAssertEqual(viewModel.appState.toastMessage,
                       "Please wait until the model finishes responding.")
        XCTAssertEqual(viewModel.messages.count, messageCount)
        XCTAssertEqual(viewModel.draft, "next draft")

        LLMStubURLProtocol.emit(sseChunk("partial"))
        await assertEventually {
            viewModel.messages.last?.content == "partial"
        }
        LLMStubURLProtocol.finish(error: URLError(.networkConnectionLost))
        await assertEventually { viewModel.activeTurn == nil }

        XCTAssertEqual(viewModel.messages.first?.deliveryState, .accepted)
        XCTAssertEqual(viewModel.messages.first?.attachments.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "partial")
        XCTAssertEqual(viewModel.draft, "next draft")
    }

    func test_sendRemainsSingleFlightUntilTTSFinishes() async throws {
        let player = HoldingPlayer()
        player.holdsPlayback = true
        let (viewModel, _, _) = try makeViewModel(player: player)
        viewModel.draft = "first"
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")

        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        LLMStubURLProtocol.releaseHeaders()
        LLMStubURLProtocol.emit(sseChunk("Hello."))
        LLMStubURLProtocol.emit(Data("data: [DONE]\n\n".utf8))
        LLMStubURLProtocol.finish()
        await assertEventually { player.playStarted }
        XCTAssertNotNil(viewModel.activeTurn)

        viewModel.draft = "second"
        viewModel.send()
        XCTAssertEqual(viewModel.appState.toastMessage,
                       "Please wait until the model finishes responding.")
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1)

        player.releasePlayback()
        await assertEventually { viewModel.activeTurn == nil }
    }

    func test_visionLossDuringActiveTurnDefersRecoveryUntilTerminal() async throws {
        let (viewModel, _, _) = try makeViewModel()
        viewModel.messages = [
            ChatMessage(
                role: .user,
                attachments: [makeAttachment(filename: "history.png")],
                deliveryState: .accepted
            )
        ]
        viewModel.draft = "go"
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")
        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        LLMStubURLProtocol.releaseHeaders()
        await assertEventually { viewModel.activeTurn?.phase == .accepted }

        viewModel.capabilityState = ModelCapabilityState(
            authoritative: [],
            forced: [],
            freshness: .current
        )
        viewModel.requestVisionRecoveryWhenSafe()
        XCTAssertFalse(viewModel.showsVisionRecovery)
        XCTAssertTrue(viewModel.deferredVisionRecovery)

        LLMStubURLProtocol.emit(Data("data: [DONE]\n\n".utf8))
        LLMStubURLProtocol.finish()
        await assertEventually { viewModel.activeTurn == nil }
        XCTAssertTrue(viewModel.showsVisionRecovery)
    }

    // MARK: - Recovery and reuse

    func test_newChatAndStripHistoryPreserveRequiredTextState() async throws {
        let (viewModel, _, _) = try makeViewModel()
        let image = makeAttachment(filename: "history.png")
        viewModel.messages = [
            ChatMessage(role: .user, content: "question", attachments: [image],
                        deliveryState: .accepted),
            ChatMessage(role: .assistant, content: "answer")
        ]
        viewModel.pendingAttachments = [makeAttachment(filename: "draft.png")]
        viewModel.draft = "unsent text"

        viewModel.stripImageHistory()
        XCTAssertEqual(viewModel.messages.map(\.content), ["question", "answer"])
        XCTAssertTrue(viewModel.messages.allSatisfy(\.attachments.isEmpty))
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)

        viewModel.startNewChatForVisionRecovery()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
        XCTAssertEqual(viewModel.draft, "unsent text")
    }

    func test_failedRevertLeavesCurrentEndpointModelAndHistoryIntact() async throws {
        let (viewModel, appState, _) = try makeViewModel()
        let originalMessages = [
            ChatMessage(
                role: .user,
                content: "keep me",
                attachments: [makeAttachment(filename: "keep.png")],
                deliveryState: .accepted
            )
        ]
        viewModel.messages = originalMessages
        viewModel.showsVisionRecovery = true
        viewModel.previousVisionSelection = ChatModelSelection(
            endpoint: "http://unavailable.invalid:9999",
            model: "old-model"
        )

        viewModel.revertToPreviousVisionModel()
        await assertEventually {
            appState.toastMessage?.contains("Could not restore") == true
        }

        XCTAssertEqual(appState.currentChatModelSelection.model, "m")
        XCTAssertEqual(appState.currentEndpointBaseURL, "http://localhost:1234")
        XCTAssertEqual(viewModel.messages, originalMessages)
        XCTAssertTrue(viewModel.showsVisionRecovery)
    }

    func test_revertRejectsAuthoritativelyNonVisionModelWithoutChangingState() async throws {
        let (viewModel, appState, _) = try makeViewModel()
        let originalMessages = [
            ChatMessage(
                role: .user,
                content: "keep me",
                attachments: [makeAttachment(filename: "keep.png")],
                deliveryState: .accepted
            )
        ]
        viewModel.messages = originalMessages
        viewModel.showsVisionRecovery = true
        viewModel.previousVisionSelection = ChatModelSelection(
            endpoint: "http://localhost:9876",
            model: "old-model"
        )
        LLMStubURLProtocol.enqueue(
            Data(#"{"data":[{"id":"old-model"}]}"#.utf8)
        )
        LLMStubURLProtocol.enqueue(
            Data(
                """
                {"models":[{"key":"old-model","capabilities":{
                "vision":false,"trained_for_tool_use":false}}]}
                """.utf8
            )
        )

        viewModel.revertToPreviousVisionModel()
        await assertEventually {
            appState.toastMessage?.contains("Could not restore") == true
        }

        XCTAssertEqual(appState.currentChatModelSelection.model, "m")
        XCTAssertEqual(appState.currentEndpointBaseURL, "http://localhost:1234")
        XCTAssertEqual(viewModel.messages, originalMessages)
        XCTAssertTrue(viewModel.showsVisionRecovery)
    }

    func test_exportAndMultiTalkFilterAllAttachmentArtifacts() async throws {
        let (viewModel, _, _) = try makeViewModel()
        let image = makeAttachment(filename: "secret-name.png")
        viewModel.messages = [
            ChatMessage(role: .user, attachments: [image], deliveryState: .accepted),
            ChatMessage(role: .user, content: "visible", attachments: [image],
                        deliveryState: .accepted),
            ChatMessage(role: .assistant, content: "(stage direction)")
        ]

        let markdown = viewModel.formatTranscriptMarkdown()
        let multiTalk = viewModel.formatTranscriptMultiTalk()
        XCTAssertFalse(markdown.contains("secret-name"))
        XCTAssertFalse(multiTalk.contains("secret-name"))
        XCTAssertFalse(multiTalk.contains("stage direction"))
        XCTAssertTrue(markdown.contains("visible"))
        XCTAssertTrue(multiTalk.contains("visible"))

        viewModel.messages = [
            ChatMessage(role: .user, attachments: [image], deliveryState: .accepted)
        ]
        XCTAssertFalse(viewModel.canSaveTranscript)
        XCTAssertFalse(viewModel.canOpenInMultiTalk)
    }

    // MARK: - Helpers

    private func makeViewModel(
        player: HoldingPlayer = HoldingPlayer()
    ) throws -> (ChatViewModel, AppState, HoldingPlayer) {
        var settings = ChatSettings.default
        settings.model = "m"
        settings.baseURL = "http://localhost:1234"
        let appState = AppState()
        try appState.applyChatConfiguration(settings, endpointBaseURL: settings.baseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMStubURLProtocol.self]
        let viewModel = ChatViewModel(
            engine: EmptyEngine(),
            player: player,
            settings: settings,
            appState: appState,
            llmSession: URLSession(configuration: configuration)
        )
        viewModel.connectionState = .connected(model: "m")
        viewModel.capabilityState = ModelCapabilityState(
            authoritative: [.vision],
            forced: [],
            freshness: .current
        )
        return (viewModel, appState, player)
    }

    private func makeAttachment(filename: String) -> ChatImageAttachment {
        ChatImageAttachment(
            id: UUID(),
            filename: filename,
            mimeType: "image/png",
            data: Data([0x01, 0x02, 0x03]),
            pixelWidth: 1,
            pixelHeight: 1,
            fingerprint: UUID().uuidString,
            thumbnailData: Data(),
            previewData: Data()
        )
    }

    private func sseChunk(_ content: String) -> Data {
        Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n".utf8
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func assertEventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let succeeded = await waitUntil(condition)
        XCTAssertTrue(succeeded, "Condition did not become true", file: file, line: line)
    }
}

private struct EmptyEngine: TTSEngineProtocol {
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
private final class HoldingPlayer: ChatAudioPlaying, @unchecked Sendable {
    var holdsPlayback = false
    private(set) var playStarted = false
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    func play(stream: AsyncStream<PCMFrame>) async throws {
        playStarted = true
        guard holdsPlayback else { return }
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
        }
    }

    func stop() async {
        releasePlayback()
    }

    func releasePlayback() {
        holdsPlayback = false
        playbackContinuation?.resume()
        playbackContinuation = nil
    }
}
