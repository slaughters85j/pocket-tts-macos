//
//  SoloChatNetworkingTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class SoloChatNetworkingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    // MARK: - Capabilities

    func test_modelCapabilities_mapsAuthoritativeLMStudioMetadata() async throws {
        LLMStubURLProtocol.setResponse(metadataResponse(
            key: "catalog/model",
            loadedID: "active-model",
            vision: true,
            tools: true,
            reasoning: true
        ))

        let capabilities = try await makeClient().modelCapabilities(for: "active-model")

        XCTAssertEqual(capabilities, .all)
        XCTAssertEqual(LLMStubURLProtocol.capturedURL()?.path, "/api/v1/models")
    }

    func test_modelCapabilities_omittedCapabilitiesFails() async {
        LLMStubURLProtocol.setResponse(Data(#"{"models":[{"key":"m"}]}"#.utf8))

        do {
            _ = try await makeClient().modelCapabilities(for: "m")
            XCTFail("Expected omitted metadata to fail")
        } catch let LocalLLMClient.ClientError.modelMetadataUnavailable(model) {
            XCTAssertEqual(model, "m")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_modelCapabilities_reasoningObjectWithoutUsableOptionIsUnsupported() async throws {
        LLMStubURLProtocol.setResponse(
            Data(
                """
                {"models":[{"key":"m","capabilities":{"vision":false,
                "trained_for_tool_use":false,
                "reasoning":{"allowed_options":["off"],"default":"off"}}}]}
                """.utf8
            )
        )

        let capabilities = try await makeClient().modelCapabilities(for: "m")

        XCTAssertFalse(capabilities.contains(.reasoning))
    }

    // MARK: - Multimodal encoding

    func test_streamChat_encodesMixedContentAndPreservesTextOnlyShape() async throws {
        LLMStubURLProtocol.setResponse(sse("ok"))
        let attachment = makeAttachment(data: Data([0x01, 0x02]), mimeType: "image/png")

        for try await _ in makeClient().streamChat(
            messages: [
                ChatMessage(role: .user, content: "look", attachments: [attachment]),
                ChatMessage(role: .assistant, content: "seen"),
                ChatMessage(role: .user, content: "plain")
            ],
            model: "m"
        ) {}

        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let mixed = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(mixed[0]["type"] as? String, "text")
        XCTAssertEqual(mixed[0]["text"] as? String, "look")
        XCTAssertEqual(mixed[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(mixed[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, attachment.dataURL)
        XCTAssertEqual(messages[1]["content"] as? String, "seen")
        XCTAssertEqual(messages[2]["content"] as? String, "plain")
    }

    func test_streamChatEvents_emitsAcceptanceBeforeDeltas() async throws {
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")
        let recorder = EventRecorder()
        let task = Task {
            for try await event in makeClient().streamChatEvents(
                messages: [ChatMessage(role: .user, content: "go")],
                model: "m"
            ) {
                await recorder.append(event)
            }
        }

        let requestArrived = await waitForRequestCount(1)
        XCTAssertTrue(requestArrived)
        var events = await recorder.values
        XCTAssertTrue(events.isEmpty)

        LLMStubURLProtocol.releaseHeaders()
        let acceptanceArrived = await waitForEventCount(1, recorder: recorder)
        XCTAssertTrue(acceptanceArrived)
        events = await recorder.values
        XCTAssertEqual(events, [.accepted(statusCode: 200)])

        LLMStubURLProtocol.emit(sse("hello"))
        LLMStubURLProtocol.finish()
        try await task.value
        events = await recorder.values
        XCTAssertEqual(events, [.accepted(statusCode: 200), .delta("hello")])
    }

    func test_streamChatEvents_cancellationCancelsTransport() async {
        LLMStubURLProtocol.beginStagedResponse(pathContains: "/v1/chat/completions")
        let task = Task {
            do {
                for try await _ in makeClient().streamChatEvents(
                    messages: [ChatMessage(role: .user, content: "go")],
                    model: "m"
                ) {}
            } catch {}
        }

        let requestArrived = await waitForRequestCount(1)
        XCTAssertTrue(requestArrived)
        task.cancel()
        _ = await task.result
        let cancellationArrived = await waitForCancellation()
        XCTAssertTrue(cancellationArrived)
    }

    func test_streamChat_rejectsOverBudgetHistoryBeforeStartingTransport() async {
        let attachments = [12_582_897, 12_582_897, 12_582_897, 12_582_892]
            .enumerated()
            .map { index, size in
                makeAttachment(
                    data: Data(repeating: UInt8(index), count: size),
                    mimeType: "image/png"
                )
            }
        do {
            for try await _ in makeClient().streamChatEvents(
                messages: [ChatMessage(role: .user, attachments: attachments)],
                model: "m"
            ) {}
            XCTFail("Expected the encoded history guard to reject the request")
        } catch LocalLLMClient.ClientError.imagePayloadTooLarge {
            XCTAssertEqual(LLMStubURLProtocol.requestCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeClient() -> LocalLLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMStubURLProtocol.self]
        return LocalLLMClient(
            baseURL: URL(string: "http://localhost:1234")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeAttachment(data: Data, mimeType: String) -> ChatImageAttachment {
        ChatImageAttachment(
            id: UUID(),
            filename: "image.png",
            mimeType: mimeType,
            data: data,
            pixelWidth: 1,
            pixelHeight: 1,
            fingerprint: UUID().uuidString,
            thumbnailData: Data(),
            previewData: Data()
        )
    }

    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        return Data(
            ("data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
                + "data: [DONE]\n\n").utf8
        )
    }

    private func metadataResponse(
        key: String,
        loadedID: String,
        vision: Bool,
        tools: Bool,
        reasoning: Bool
    ) -> Data {
        let reasoningJSON = reasoning
            ? #","reasoning":{"allowed_options":["on"],"default":"on"}"#
            : ""
        return Data(
            """
            {"models":[{"key":"\(key)","loaded_instances":[{"id":"\(loadedID)"}],
            "capabilities":{"vision":\(vision),"trained_for_tool_use":\(tools)\(reasoningJSON)}}]}
            """.utf8
        )
    }

    private func waitForRequestCount(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if LLMStubURLProtocol.requestCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForEventCount(_ count: Int, recorder: EventRecorder) async -> Bool {
        for _ in 0..<100 {
            if await recorder.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForCancellation() async -> Bool {
        for _ in 0..<100 {
            if LLMStubURLProtocol.cancellationObserved { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor EventRecorder {
    private(set) var values: [ChatStreamEvent] = []
    var count: Int { values.count }

    func append(_ event: ChatStreamEvent) {
        values.append(event)
    }
}
