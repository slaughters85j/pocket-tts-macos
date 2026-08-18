//
//  ChatVisionRecoveryTransitionTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class ChatVisionRecoveryTransitionTests: XCTestCase {

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

    func test_realModelSwitchToNonVisionWithImageHistoryShowsRecovery() async throws {
        let (viewModel, appState) = try makeViewModelWithAcceptedImageHistory()
        try applySelection(model: "text-model", appState: appState, viewModel: viewModel)
        enqueueModels(["text-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "text-model", vision: false))

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.capabilityState.freshness, .current)
        XCTAssertFalse(viewModel.supportsVision)
        XCTAssertTrue(viewModel.showsVisionRecovery)
        XCTAssertEqual(viewModel.previousVisionSelection?.model, "vision-model")
    }

    func test_unknownMetadataDoesNotOpenRecoveryButBlocksHistoricalImages() async throws {
        let (viewModel, appState) = try makeViewModelWithAcceptedImageHistory()
        try applySelection(model: "unknown-model", appState: appState, viewModel: viewModel)
        enqueueModels(["unknown-model"])
        LLMStubURLProtocol.enqueue(Data("malformed".utf8))

        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .unknown)
        XCTAssertFalse(viewModel.showsVisionRecovery)
        XCTAssertTrue(viewModel.canResolveImageHistory)
        viewModel.presentImageHistoryResolution()
        XCTAssertTrue(viewModel.showsVisionRecovery)
        viewModel.showsVisionRecovery = false

        let requestCount = LLMStubURLProtocol.requestCount
        viewModel.draft = "do not send image history"
        viewModel.send()

        XCTAssertEqual(LLMStubURLProtocol.requestCount, requestCount)
        XCTAssertTrue(viewModel.messages.contains { !$0.attachments.isEmpty })
        XCTAssertTrue(
            viewModel.appState.toastMessage?.contains("Vision support is not confirmed") == true
        )
    }

    func test_cancelledRecoveryCannotSendImageHistoryToNonVisionModel() async throws {
        let (viewModel, appState) = try makeViewModelWithAcceptedImageHistory()
        try applySelection(model: "text-model", appState: appState, viewModel: viewModel)
        enqueueModels(["text-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "text-model", vision: false))
        await viewModel.checkConnection()
        XCTAssertTrue(viewModel.showsVisionRecovery)

        viewModel.showsVisionRecovery = false
        enqueueModels(["text-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "text-model", vision: false))
        await viewModel.checkConnection()
        XCTAssertFalse(viewModel.showsVisionRecovery)

        let requestCount = LLMStubURLProtocol.requestCount
        viewModel.draft = "still blocked"
        viewModel.send()

        XCTAssertEqual(LLMStubURLProtocol.requestCount, requestCount)
        XCTAssertTrue(viewModel.showsVisionRecovery)
        XCTAssertTrue(viewModel.messages.contains { !$0.attachments.isEmpty })
    }

    func test_forceVisionOverrideSuppressesRecoveryAndAllowsHistorySend() async throws {
        let (viewModel, appState) = try makeViewModelWithAcceptedImageHistory()
        var newSettings = viewModel.settings
        newSettings.model = "forced-model"
        let forcedSelection = ChatModelSelection(
            endpoint: newSettings.baseURL,
            model: newSettings.model
        )
        newSettings.setCapability(.vision, forcedSupported: true, for: forcedSelection)
        try appState.applyChatConfiguration(
            newSettings,
            endpointBaseURL: newSettings.baseURL
        )
        viewModel.settings = appState.chatSettings
        enqueueModels(["forced-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "forced-model", vision: false))

        await viewModel.checkConnection()

        XCTAssertTrue(viewModel.supportsVision)
        XCTAssertFalse(viewModel.showsVisionRecovery)
        // Via `completeSend`, which picks the STREAMED request. Reading the last captured body races the thread auto-title call that fires the moment `activeTurn` clears — see that helper.
        viewModel.draft = "allowed"
        let sentBody = try await completeSend(viewModel)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sentBody.utf8)) as? [String: Any]
        )
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let imageURL = try XCTUnwrap(blocks.last?["image_url"] as? [String: Any])
        XCTAssertTrue((imageURL["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    func test_stoppingSoloChatSessionCancelsActiveTransport() async throws {
        let (viewModel, _) = try makeViewModelWithAcceptedImageHistory()
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")
        viewModel.draft = "cancel with the view"
        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }

        viewModel.stopSoloChatSession()

        await assertEventually { LLMStubURLProtocol.cancellationObserved }
        await assertEventually { viewModel.activeTurn == nil }
        XCTAssertNil(viewModel.healthCheckTask)
    }

    func test_realSwitchThenStartNewChatRegainsTextSendState() async throws {
        let (viewModel, appState) = try await switchToNonVision()
        viewModel.draft = "preserve this draft"

        viewModel.startNewChatForVisionRecovery()

        XCTAssertFalse(viewModel.hasImageHistory)
        XCTAssertEqual(viewModel.draft, "preserve this draft")
        let body = try await completeSend(viewModel)
        XCTAssertFalse(body.contains("\"image_url\""))
    }

    func test_realSwitchThenStripHistorySendsTextWithoutImageBlocks() async throws {
        let (viewModel, _) = try await switchToNonVision()

        viewModel.stripImageHistory()

        XCTAssertFalse(viewModel.hasImageHistory)
        XCTAssertEqual(viewModel.messages.map(\.content), ["look", "seen"])
        viewModel.draft = "continue"
        let body = try await completeSend(viewModel)
        XCTAssertFalse(body.contains("\"image_url\""))
    }

    func test_realSwitchThenRevertRestoresVisionSelectionAndAllowsSend() async throws {
        let (viewModel, appState) = try await switchToNonVision()
        // Revert issues four requests in order: catalog list, capability probe,
        // then checkConnection's serving list and its own probe.
        enqueueCatalogModels(["vision-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "vision-model", vision: true))
        enqueueModels(["vision-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "vision-model", vision: true))

        viewModel.revertToPreviousVisionModel()
        await assertEventually {
            appState.currentChatModelSelection.model == "vision-model"
                && viewModel.capabilityState.freshness == .current
                && viewModel.supportsVision
        }

        viewModel.draft = "continue with vision"
        let body = try await completeSend(viewModel)
        XCTAssertTrue(body.contains("\"image_url\""))
    }

    // MARK: - Helpers

    private func switchToNonVision() async throws -> (ChatViewModel, AppState) {
        let (viewModel, appState) = try makeViewModelWithAcceptedImageHistory()
        try applySelection(model: "text-model", appState: appState, viewModel: viewModel)
        enqueueModels(["text-model"])
        LLMStubURLProtocol.enqueue(metadata(model: "text-model", vision: false))
        await viewModel.checkConnection()
        XCTAssertTrue(viewModel.showsVisionRecovery)
        return (viewModel, appState)
    }

    private func completeSend(_ viewModel: ChatViewModel) async throws -> String {
        LLMStubURLProtocol.setResponse(Data("data: [DONE]\n\n".utf8))
        viewModel.send()
        await assertEventually { viewModel.activeTurn == nil }

        // `capturedBody()` (the LAST request) is a race here: `finishTurnIfSettled`
        // clears `activeTurn` and then immediately fires the thread auto-title
        // call, so whichever lands last depends on I/O timing. Both go to
        // /v1/chat/completions, but only the chat send is streamed — pick that.
        let sent = LLMStubURLProtocol.capturedBodies()
            .compactMap { String(data: $0, encoding: .utf8) }
            .last { $0.contains("\"stream\":true") }
        return try XCTUnwrap(sent, "no streamed chat request was captured")
    }

    private func makeViewModelWithAcceptedImageHistory() throws -> (ChatViewModel, AppState) {
        var settings = ChatSettings.default
        settings.model = "vision-model"
        settings.baseURL = "http://localhost:1234"
        let appState = AppState()
        try appState.applyChatConfiguration(settings, endpointBaseURL: settings.baseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMStubURLProtocol.self]
        let viewModel = ChatViewModel(
            engine: RecoveryEmptyEngine(),
            player: RecoveryPlayer(),
            settings: settings,
            appState: appState,
            llmSession: URLSession(configuration: configuration)
        )
        let selection = ChatModelSelection(endpoint: settings.baseURL, model: settings.model)
        viewModel.connectionState = .connected(model: settings.model)
        viewModel.capabilitySelection = selection
        viewModel.capabilityState = ModelCapabilityState(
            authoritative: [.vision],
            forced: [],
            freshness: .current
        )
        viewModel.previousVisionSelection = selection
        viewModel.messages = [
            ChatMessage(
                role: .user,
                content: "look",
                attachments: [makeAttachment()],
                deliveryState: .accepted
            ),
            ChatMessage(role: .assistant, content: "seen")
        ]
        return (viewModel, appState)
    }

    private func applySelection(
        model: String,
        appState: AppState,
        viewModel: ChatViewModel
    ) throws {
        var settings = viewModel.settings
        settings.model = model
        try appState.applyChatConfiguration(
            settings,
            endpointBaseURL: settings.baseURL
        )
        viewModel.settings = appState.chatSettings
    }

    /// LM Studio `/api/v1/models` shape — NOT the OpenAI `{"data":[…]}` one.
    /// `listServingModels()` probes the native endpoint first and only falls
    /// back to `/v1/models` when that body fails to decode. An OpenAI-shaped
    /// fixture here therefore burned TWO queued responses (the fallback ate the
    /// metadata reply), so every later capability expectation read the wrong
    /// slot. `loaded_instances` must be non-empty or `servingModelIDs()`
    /// reports nothing as serving.
    private func enqueueModels(_ models: [String]) {
        let entries = models.map {
            #"{"key":"\#($0)","loaded_instances":[{"id":"\#($0)"}]}"#
        }.joined(separator: ",")
        LLMStubURLProtocol.enqueue(Data(#"{"models":[\#(entries)]}"#.utf8))
    }

    /// OpenAI `/v1/models` shape. `revertToPreviousVisionModel()` asks for the
    /// catalog via `listModels()` directly — not serving state — and that call
    /// decodes only this shape, so it needs its own fixture.
    private func enqueueCatalogModels(_ models: [String]) {
        let entries = models.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        LLMStubURLProtocol.enqueue(Data(#"{"data":[\#(entries)]}"#.utf8))
    }

    private func metadata(model: String, vision: Bool) -> Data {
        Data(
            """
            {"models":[{"key":"\(model)","capabilities":{
            "vision":\(vision),"trained_for_tool_use":false}}]}
            """.utf8
        )
    }

    private func makeAttachment() -> ChatImageAttachment {
        ChatImageAttachment(
            id: UUID(),
            filename: "history.png",
            mimeType: "image/png",
            data: Data([0x01, 0x02, 0x03]),
            pixelWidth: 1,
            pixelHeight: 1,
            fingerprint: "history",
            thumbnailData: Data(),
            previewData: Data()
        )
    }

    private func assertEventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private struct RecoveryEmptyEngine: TTSEngineProtocol {
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
private final class RecoveryPlayer: ChatAudioPlaying, @unchecked Sendable {
    func play(stream: AsyncStream<PCMFrame>) async throws {}
    func stop() async {}
}
