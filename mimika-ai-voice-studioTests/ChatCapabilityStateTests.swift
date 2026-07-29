//
//  ChatCapabilityStateTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class ChatCapabilityStateTests: XCTestCase {

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

    func test_capabilitiesMoveCurrentToStaleAndBackToCurrent() async throws {
        let (viewModel, _) = try makeViewModel()
        enqueueModels(["m"])
        LLMStubURLProtocol.enqueue(metadata(vision: true, tools: false, reasoning: false))
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .current)
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.vision])

        enqueueModels(["m"])
        LLMStubURLProtocol.enqueue(Data("malformed".utf8))
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .stale)
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.vision])

        enqueueModels(["m"])
        LLMStubURLProtocol.enqueue(metadata(vision: false, tools: true, reasoning: true))
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .current)
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.tools, .reasoning])
    }

    func test_firstMetadataFailureIsUnknownAndDoesNotDisconnect() async throws {
        let (viewModel, _) = try makeViewModel()
        enqueueModels(["m"])
        LLMStubURLProtocol.enqueue(Data(#"{"models":[]}"#.utf8))

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.connectionState, .connected(model: "m"))
        XCTAssertEqual(viewModel.capabilityState.freshness, .unknown)
        XCTAssertTrue(viewModel.capabilityState.authoritative.isEmpty)
        XCTAssertFalse(viewModel.showsVisionRecovery)
    }

    func test_stopHealthChecksCancelsInFlightConnectionRequest() async throws {
        let (viewModel, _) = try makeViewModel()
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/models")

        viewModel.startHealthChecks()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        viewModel.stopHealthChecks()

        XCTAssertNil(viewModel.healthCheckTask)
        await assertEventually { LLMStubURLProtocol.cancellationObserved }
    }

    func test_delayedCapabilityProbeCannotOverwriteNewModelSelection() async throws {
        let (viewModel, appState) = try makeViewModel()
        enqueueModels(["m"])
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/api/v1/models")
        let oldCheck = Task { await viewModel.checkConnection() }
        await assertEventually { LLMStubURLProtocol.requestCount >= 2 }

        var newSettings = viewModel.settings
        newSettings.model = "new-model"
        try appState.applyChatConfiguration(
            newSettings,
            endpointBaseURL: "http://127.0.0.1:1234"
        )
        viewModel.settings = appState.chatSettings
        enqueueModels(["new-model"])
        LLMStubURLProtocol.enqueue(
            metadata(
                key: "new-model",
                vision: false,
                tools: true,
                reasoning: false
            )
        )

        await viewModel.checkConnection()
        await oldCheck.value

        XCTAssertEqual(viewModel.connectionState, .connected(model: "new-model"))
        XCTAssertEqual(viewModel.capabilitySelection?.model, "new-model")
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.tools])
        XCTAssertEqual(viewModel.capabilityState.freshness, .current)
    }

    func test_capabilityOverrideIsScopedAndPersists() {
        var settings = ChatSettings.default
        let selection = ChatModelSelection(endpoint: "HTTP://LOCALHOST:1234/", model: "m")
        let equivalent = ChatModelSelection(endpoint: "http://localhost:1234", model: "m")
        let otherModel = ChatModelSelection(endpoint: "http://localhost:1234", model: "other")

        settings.setCapability(.vision, forcedSupported: true, for: selection)
        SettingsStore.save(settings)
        let restored = SettingsStore.load()

        XCTAssertEqual(restored.forcedCapabilities(for: equivalent), [.vision])
        XCTAssertTrue(restored.forcedCapabilities(for: otherModel).isEmpty)
    }

    func test_authoritativeSupportDisplaysCurrentWithoutMutatingOverride() async throws {
        let (viewModel, appState) = try makeViewModel()
        let selection = ChatModelSelection(
            endpoint: viewModel.settings.baseURL,
            model: viewModel.settings.model
        )
        var settings = viewModel.settings
        settings.setCapability(.vision, forcedSupported: true, for: selection)
        try appState.applyChatConfiguration(
            settings,
            endpointBaseURL: settings.baseURL
        )
        viewModel.settings = appState.chatSettings
        enqueueModels(["m"])
        LLMStubURLProtocol.enqueue(
            metadata(vision: true, tools: false, reasoning: false)
        )

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.capabilityState.forced, [.vision])
        XCTAssertEqual(viewModel.capabilityState.displayState(for: .vision), .current)
        XCTAssertEqual(viewModel.settings.forcedCapabilities(for: selection), [.vision])
        XCTAssertEqual(
            SettingsStore.load().forcedCapabilities(for: selection),
            [.vision]
        )
    }

    private func makeViewModel() throws -> (ChatViewModel, AppState) {
        var settings = ChatSettings.default
        settings.model = "m"
        settings.baseURL = "http://localhost:1234"
        let appState = AppState()
        try appState.applyChatConfiguration(settings, endpointBaseURL: settings.baseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMStubURLProtocol.self]
        let viewModel = ChatViewModel(
            engine: CapabilityEmptyEngine(),
            player: CapabilityPlayer(),
            settings: settings,
            appState: appState,
            llmSession: URLSession(configuration: configuration)
        )
        return (viewModel, appState)
    }

    private func enqueueModels(_ models: [String]) {
        let entries = models.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        LLMStubURLProtocol.enqueue(Data(#"{"data":[\#(entries)]}"#.utf8))
    }

    private func metadata(
        key: String = "m",
        vision: Bool,
        tools: Bool,
        reasoning: Bool
    ) -> Data {
        let reasoningValue = reasoning
            ? #","reasoning":{"allowed_options":["on"],"default":"on"}"#
            : ""
        return Data(
            """
            {"models":[{"key":"\(key)","capabilities":{"vision":\(vision),
            "trained_for_tool_use":\(tools)\(reasoningValue)}}]}
            """.utf8
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

private struct CapabilityEmptyEngine: TTSEngineProtocol {
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
private final class CapabilityPlayer: ChatAudioPlaying, @unchecked Sendable {
    func play(stream: AsyncStream<PCMFrame>) async throws {}
    func stop() async {}
}
