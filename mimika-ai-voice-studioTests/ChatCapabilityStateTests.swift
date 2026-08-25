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
        // serving + probe
        LLMStubURLProtocol.enqueue(metadata(vision: true, tools: false, reasoning: false))
        LLMStubURLProtocol.enqueue(metadata(vision: true, tools: false, reasoning: false))
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .current)
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.vision])

        // Polls skip re-probe while freshness is .current. Force a refresh so a failed metadata read can move current → stale.
        viewModel.capabilityState.freshness = .unknown
        LLMStubURLProtocol.enqueue(metadata(vision: true, tools: false, reasoning: false))
        LLMStubURLProtocol.enqueue(Data("malformed".utf8))
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .stale)
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.vision])

        viewModel.capabilityState.freshness = .unknown
        LLMStubURLProtocol.enqueue(metadata(vision: false, tools: true, reasoning: true))
        LLMStubURLProtocol.enqueue(metadata(vision: false, tools: true, reasoning: true))
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.capabilityState.freshness, .current)
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.tools, .reasoning])
    }

    func test_firstMetadataFailureIsUnknownAndDoesNotDisconnect() async throws {
        let (viewModel, _) = try makeViewModel()
        // Serving succeeds; capability probe returns empty catalog for that model.
        LLMStubURLProtocol.enqueue(metadata(vision: true, tools: false, reasoning: false))
        LLMStubURLProtocol.enqueue(Data(#"{"models":[]}"#.utf8))

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.connectionState, .connected(model: "m"))
        XCTAssertEqual(viewModel.capabilityState.freshness, .unknown)
        XCTAssertTrue(viewModel.capabilityState.authoritative.isEmpty)
        XCTAssertFalse(viewModel.showsVisionRecovery)
    }

    func test_stopHealthChecksCancelsInFlightConnectionRequest() async throws {
        let (viewModel, _) = try makeViewModel()
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/api/v1/models")

        viewModel.startHealthChecks()
        await assertEventually { LLMStubURLProtocol.requestCount >= 1 }
        viewModel.stopHealthChecks()

        XCTAssertNil(viewModel.healthCheckTask)
        await assertEventually { LLMStubURLProtocol.cancellationObserved }
    }

    func test_catalogOnlyModelsDoNotCountAsConnected() async throws {
        let (viewModel, _) = try makeViewModel()
        // LM Studio catalog entry with no loaded instance — server up, nothing serving.
        LLMStubURLProtocol.enqueue(Data(
            #"{"models":[{"key":"stale/model","loaded_instances":[],"capabilities":{"vision":false,"trained_for_tool_use":false}}]}"#.utf8
        ))

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.connectionState, .disconnected(reason: "no model loaded"))
    }

    func test_modelSwitchReplacesConnectionAndCapabilities() async throws {
        let (viewModel, appState) = try makeViewModel()
        let metaM = metadata(vision: true, tools: false, reasoning: false)
        LLMStubURLProtocol.enqueue(metaM)
        LLMStubURLProtocol.enqueue(metaM)
        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.connectionState, .connected(model: "m"))
        XCTAssertEqual(viewModel.capabilityState.authoritative, [.vision])

        var newSettings = viewModel.settings
        newSettings.model = "new-model"
        try appState.applyChatConfiguration(
            newSettings,
            endpointBaseURL: "http://127.0.0.1:1234"
        )
        viewModel.settings = appState.chatSettings
        let newMeta = metadata(
            key: "new-model",
            vision: false,
            tools: true,
            reasoning: false
        )
        LLMStubURLProtocol.enqueue(newMeta)
        LLMStubURLProtocol.enqueue(newMeta)
        await viewModel.checkConnection()

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

    func test_forceReasoningOverrideAppearsWithoutReprobe() async throws {
        let (viewModel, appState) = try makeViewModel()
        let meta = metadata(vision: false, tools: false, reasoning: false)
        LLMStubURLProtocol.enqueue(meta)
        LLMStubURLProtocol.enqueue(meta)
        await viewModel.checkConnection()
        XCTAssertFalse(viewModel.supportsReasoning)
        XCTAssertNil(viewModel.reasoningConfiguration)

        let selection = ChatModelSelection(
            endpoint: viewModel.settings.baseURL,
            model: viewModel.settings.model
        )
        var newSettings = viewModel.settings
        newSettings.setCapability(.reasoning, forcedSupported: true, for: selection)
        try appState.applyChatConfiguration(
            newSettings,
            endpointBaseURL: newSettings.baseURL
        )
        viewModel.settings = appState.chatSettings

        // Same serving set — must pick up forced bits without a new probe.
        await viewModel.checkConnection()

        XCTAssertTrue(viewModel.capabilityState.forced.contains(.reasoning))
        XCTAssertTrue(viewModel.supportsReasoning)
        XCTAssertNotNil(viewModel.reasoningConfiguration)
        XCTAssertNotNil(viewModel.reasoningSelection)
    }

    func test_forceReasoningSurvivesSwitchWhilePreviousModelStillServing() async throws {
        let (viewModel, appState) = try makeViewModel()
        let oldMeta = metadata(key: "m", vision: false, tools: false, reasoning: false)
        LLMStubURLProtocol.enqueue(oldMeta)
        LLMStubURLProtocol.enqueue(oldMeta)
        await viewModel.checkConnection()
        XCTAssertFalse(viewModel.supportsReasoning)

        let newSelection = ChatModelSelection(
            endpoint: viewModel.settings.baseURL,
            model: "new-model"
        )
        var newSettings = viewModel.settings
        newSettings.model = "new-model"
        newSettings.setCapability(.reasoning, forcedSupported: true, for: newSelection)
        try appState.applyChatConfiguration(
            newSettings,
            endpointBaseURL: newSettings.baseURL
        )
        viewModel.settings = appState.chatSettings

        // Auto-load not finished: serving list is still the old model.
        LLMStubURLProtocol.enqueue(oldMeta)
        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.capabilitySelection?.model, "new-model")
        XCTAssertTrue(viewModel.capabilityState.forced.contains(.reasoning))
        XCTAssertTrue(viewModel.supportsReasoning)
        XCTAssertNotNil(
            viewModel.reasoningConfiguration,
            "must not adopt the still-serving old model's empty reasoning"
        )

        // New model is now loaded and reports no native reasoning.
        let newMeta = metadata(key: "new-model", vision: false, tools: false, reasoning: false)
        LLMStubURLProtocol.enqueue(newMeta)
        LLMStubURLProtocol.enqueue(newMeta)
        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.capabilitySelection?.model, "new-model")
        XCTAssertTrue(viewModel.capabilityState.forced.contains(.reasoning))
        XCTAssertTrue(viewModel.supportsReasoning)
        XCTAssertNotNil(viewModel.reasoningConfiguration)
        XCTAssertEqual(
            viewModel.capabilityState.displayState(for: .reasoning),
            .overridden
        )
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
        let meta = metadata(vision: true, tools: false, reasoning: false)
        LLMStubURLProtocol.enqueue(meta)
        LLMStubURLProtocol.enqueue(meta)

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.capabilityState.forced, [.vision])
        XCTAssertEqual(viewModel.capabilityState.displayState(for: .vision), .current)
        XCTAssertEqual(viewModel.settings.forcedCapabilities(for: selection), [.vision])
        XCTAssertEqual(
            SettingsStore.load().forcedCapabilities(for: selection),
            [.vision]
        )
    }

    func test_reasoningSelectionUsesMetadataAndLocksDuringActiveTurn() async throws {
        let (viewModel, appState) = try makeViewModel()
        let meta = servingPayload(models: ["m"], vision: false, tools: false, reasoning: true)
        LLMStubURLProtocol.enqueue(meta)
        LLMStubURLProtocol.enqueue(meta)

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.reasoningSelection, .medium)
        viewModel.setReasoningSelection(.high)
        XCTAssertEqual(viewModel.reasoningSelection, .high)
        XCTAssertEqual(viewModel.reasoningEffortForRequest, "high")

        viewModel.activeTurn = ActiveChatTurn(
            userMessageID: UUID(),
            assistantMessageID: UUID(),
            originalDraft: "",
            originalAttachments: []
        )
        viewModel.setReasoningSelection(.low)

        XCTAssertEqual(viewModel.reasoningSelection, .high)
        XCTAssertEqual(
            appState.toastMessage,
            "Please wait until the model finishes responding."
        )
    }

    func test_ensembleReasoningDefaultsOffAndWarnsWhenEnabled() async throws {
        let (viewModel, appState) = try makeViewModel()
        appState.chatSubMode = .ensemble
        let meta = servingPayload(models: ["m"], vision: false, tools: false, reasoning: true)
        LLMStubURLProtocol.enqueue(meta)
        LLMStubURLProtocol.enqueue(meta)

        await viewModel.checkConnection()

        // Ensemble injects Off and defaults to it even when LM Studio's graded list omits it.
        XCTAssertEqual(viewModel.reasoningSelection, .off)
        XCTAssertTrue(viewModel.reasoningConfiguration?.allowedOptions.contains(.off) == true)

        viewModel.setReasoningSelection(.high)
        XCTAssertEqual(viewModel.reasoningSelection, .high)
        XCTAssertEqual(
            appState.toastMessage,
            "Larger thinking models tend to cause non-responsive turns in Ensemble."
        )

        // Solo keeps its own store — switching back restores medium default (no prior solo selection for this model).
        appState.chatSubMode = .solo
        viewModel.refreshReasoningForChatSubMode()
        XCTAssertEqual(viewModel.reasoningSelection, .medium)
    }

    private func makeViewModel() throws -> (ChatViewModel, AppState) {
        var settings = ChatSettings.default
        settings.model = "m"
        settings.baseURL = "http://localhost:1234"
        let appState = AppState()
        // Tests must not inherit the user's last Solo/Ensemble pick from UserDefaults.
        appState.chatSubMode = .solo
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

    /// Connection health uses `/api/v1/models` twice (serving list + capability probe). Enqueue the same loaded-model payload for both legs.
    private func enqueueModels(_ models: [String]) {
        let payload = servingPayload(models: models, vision: false, tools: false, reasoning: false)
        LLMStubURLProtocol.enqueue(payload)
        LLMStubURLProtocol.enqueue(payload)
    }

    private func metadata(
        key: String = "m",
        vision: Bool,
        tools: Bool,
        reasoning: Bool
    ) -> Data {
        servingPayload(models: [key], vision: vision, tools: tools, reasoning: reasoning)
    }

    private func servingPayload(
        models: [String],
        vision: Bool,
        tools: Bool,
        reasoning: Bool
    ) -> Data {
        let entries: [[String: Any]] = models.map { id in
            var capabilities: [String: Any] = [
                "vision": vision,
                "trained_for_tool_use": tools,
            ]
            if reasoning {
                capabilities["reasoning"] = [
                    "allowed_options": ["low", "medium", "high", "off"],
                    "default": "medium",
                ]
            }
            return [
                "key": id,
                "loaded_instances": [["id": id]],
                "capabilities": capabilities,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: ["models": entries])
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

// MARK: - Assistant Markdown

final class ChatMarkdownParserTests: XCTestCase {
    func test_parserSeparatesProseAndFencedCodeWithoutFenceMarkers() {
        let source = """
        Intro with **bold** text.

        ```markdown
        # Generated prompt
        Keep this literal.
        ```

        Closing paragraph.
        """

        XCTAssertEqual(
            ChatMarkdownParser.parse(source),
            [
                .prose("Intro with **bold** text."),
                .code(
                    language: "markdown",
                    content: "# Generated prompt\nKeep this literal."
                ),
                .prose("Closing paragraph.")
            ]
        )
    }

    func test_parserTreatsUnclosedStreamingFenceAsCode() {
        XCTAssertEqual(
            ChatMarkdownParser.parse("Before\n\n```text\npartial response"),
            [
                .prose("Before"),
                .code(language: "text", content: "partial response")
            ]
        )
    }

    func test_parserLeavesOrdinaryMarkdownAsProse() {
        XCTAssertEqual(
            ChatMarkdownParser.parse("- One\n- Two\n\n`inline`"),
            [.prose("- One\n- Two\n\n`inline`")]
        )
    }

    func test_multiTalkSanitizerRemovesFencesEmojiAndMarkdownMarkers() {
        let source = """
        Hello 👋 **John**.

        ```markdown
        *Prompt* with `inline code`.
        Second line ❤️
        ```
        """

        XCTAssertEqual(
            ChatTranscriptSanitizer.multiTalkText(from: source),
            "Hello John.\n\nPrompt with inline code.\nSecond line"
        )
    }

    func test_multiTalkSanitizerKeepsProsodyPunctuationAndGroupedNumbers() {
        // `,` `?` `!` used to be replaced with spaces, which flattened questions into statements and turned "45,607" into two separate numbers.
        XCTAssertEqual(
            ChatTranscriptSanitizer.multiTalkText(
                from: "The total was 45,607 units. Who are you? Stop!"
            ),
            "The total was 45,607 units. Who are you? Stop!"
        )
    }

    func test_multiTalkSanitizerKeepsOnlySpeechSafePunctuation() {
        let source = #"Path /root\folder; #topic: "Sam's ready." — “It’s done.” [yes] {no} @home + 50%"#

        XCTAssertEqual(
            ChatTranscriptSanitizer.multiTalkText(from: source),
            #"Path root folder topic "Sam's ready." “It’s done.” yes no home 50"#
        )
    }
}
