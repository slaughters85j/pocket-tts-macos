//
//  ChatInferenceSettingsTests.swift
//  mimika-ai-voice-studioTests
//

import SwiftData
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class ChatInferenceSettingsTests: XCTestCase {
    func test_inferenceSettingsPersistPerPromptAndCopyOnDuplicate() throws {
        let (_, context) = try makeContext()
        let first = AppDataStore.create(
            context,
            scope: .chat,
            name: "First",
            content: "first"
        )
        let second = AppDataStore.create(
            context,
            scope: .chat,
            name: "Second",
            content: "second"
        )
        let firstSettings = ChatInferenceSettings(
            temperature: 0.35,
            topP: 0.55,
            topK: 18,
            repeatPenalty: 1.25,
            maxTokens: 256
        )
        let secondSettings = ChatInferenceSettings(
            temperature: 1.2,
            topP: 0.9,
            topK: 72,
            repeatPenalty: 0.95,
            maxTokens: nil
        )

        AppDataStore.updateInferenceSettings(
            context,
            prompt: first,
            settings: firstSettings
        )
        AppDataStore.updateInferenceSettings(
            context,
            prompt: second,
            settings: secondSettings
        )

        XCTAssertEqual(first.inferenceSettings, firstSettings)
        XCTAssertEqual(second.inferenceSettings, secondSettings)

        let copy = AppDataStore.duplicate(context, prompt: first)
        XCTAssertNotEqual(copy.id, first.id)
        XCTAssertEqual(copy.inferenceSettings, firstSettings)
    }

    func test_sendCapturesActivePromptInferenceSettingsInPayload() async throws {
        SettingsStore.resetToDefaults()
        LLMStubURLProtocol.reset()
        defer {
            SettingsStore.resetToDefaults()
            LLMStubURLProtocol.reset()
        }
        let (_, context) = try makeContext()
        let settings = ChatInferenceSettings(
            temperature: 0.45,
            topP: 0.6,
            topK: 24,
            repeatPenalty: 1.3,
            maxTokens: 512
        )
        let inactivePrompt = SystemPrompt(
            name: "Inactive",
            scope: .chat,
            content: "Do not use this prompt.",
            isActive: false
        )
        let prompt = SystemPrompt(
            name: "Active",
            scope: .chat,
            content: "Use this prompt.",
            isActive: true,
            inferenceSettings: settings
        )
        context.insert(inactivePrompt)
        context.insert(prompt)
        try context.save()

        var chatSettings = ChatSettings.default
        chatSettings.baseURL = "http://localhost:1234"
        chatSettings.model = "m"

        let appState = AppState()
        appState.modelContext = context
        try appState.applyChatConfiguration(
            chatSettings,
            endpointBaseURL: chatSettings.baseURL
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMStubURLProtocol.self]
        let viewModel = ChatViewModel(
            engine: InferenceSettingsEmptyEngine(),
            player: InferenceSettingsPlayer(),
            settings: chatSettings,
            appState: appState,
            llmSession: URLSession(configuration: configuration)
        )
        viewModel.connectionState = .connected(model: "m")
        viewModel.draft = "Hello"
        LLMStubURLProtocol.setResponse(sse("Done"))

        viewModel.send()
        await assertEventually { LLMStubURLProtocol.capturedBody() != nil }

        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["temperature"] as? Double, settings.temperature)
        XCTAssertEqual(json["top_p"] as? Double, settings.topP)
        XCTAssertEqual(json["top_k"] as? Int, settings.topK)
        XCTAssertEqual(json["repeat_penalty"] as? Double, settings.repeatPenalty)
        XCTAssertEqual(json["max_tokens"] as? Int, settings.maxTokens)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, prompt.content)
        await assertEventually { viewModel.activeTurn == nil }

        var unlimitedSettings = settings
        unlimitedSettings.maxTokens = nil
        AppDataStore.updateInferenceSettings(
            context,
            prompt: prompt,
            settings: unlimitedSettings
        )
        LLMStubURLProtocol.setResponse(sse("Done again"))
        viewModel.draft = "Again"
        viewModel.send()
        await assertEventually { LLMStubURLProtocol.requestCount >= 2 }

        let unlimitedBody = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        let unlimitedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unlimitedBody) as? [String: Any]
        )
        XCTAssertNil(unlimitedJSON["max_tokens"])
        await assertEventually { viewModel.activeTurn == nil }
    }

    /// Fresh in-memory SwiftData context retained by the returned container.
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try HistoryStore.makeInMemoryContainer()
        return (container, ModelContext(container))
    }

    /// One SSE content chunk followed by the completion sentinel.
    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        return Data(
            (
                "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
                    + "data: [DONE]\n\n"
            ).utf8
        )
    }

    /// Wait for async URLSession and turn callbacks without fixed sleeps.
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

private struct InferenceSettingsEmptyEngine: TTSEngineProtocol {
    nonisolated func availableVoiceIDs() -> [String] {
        ["cosette"]
    }

    nonisolated func synthesize(
        text: String,
        voiceID: String,
        options: SynthesisOptions
    ) -> AsyncStream<PCMFrame> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class InferenceSettingsPlayer: ChatAudioPlaying, @unchecked Sendable {
    func play(stream: AsyncStream<PCMFrame>) async throws {}
    func stop() async {}
}
