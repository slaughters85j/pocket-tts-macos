//
//  PersonaProviderTests.swift
//  mimika-ai-voice-studioTests
//
//  The pluggable persona-writer backends: the Anthropic structured-output path (request → response → tolerant decode) and the reads_on_others map/array tolerance that lets one DTO decode both the local (map) and Claude (array) shapes. The LLM transport is stubbed via LLMStubURLProtocol.
//

import XCTest
@testable import mimika_ai_voice_studio

final class PersonaProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Wrap a JSON string as an Anthropic Messages response (`content[0].text`).
    private func anthropicResponse(_ jsonText: String) -> Data {
        let escaped = jsonText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data("{\"content\":[{\"type\":\"text\",\"text\":\"\(escaped)\"}]}".utf8)
    }

    // MARK: - reads_on_others tolerance

    func test_personaStub_decodesArrayReads() throws {
        let json = #"{"name":"A","voice":"v","reads_on_others":[{"name":"B","read":"trusts B"}]}"#
        let stub = try JSONDecoder().decode(PersonaStub.self, from: Data(json.utf8))
        XCTAssertEqual(stub.readsOnOthers["B"], "trusts B")
    }

    func test_personaStub_stillDecodesMapReads() throws {
        let json = #"{"name":"A","voice":"v","reads_on_others":{"B":"trusts B"}}"#
        let stub = try JSONDecoder().decode(PersonaStub.self, from: Data(json.utf8))
        XCTAssertEqual(stub.readsOnOthers["B"], "trusts B")
    }

    func test_personaFull_decodesArrayReads() throws {
        let json = #"{"name":"A","voice":"v","persona_prompt":"hi","reads_on_others":[{"name":"B","read":"rival"}]}"#
        let full = try JSONDecoder().decode(PersonaFull.self, from: Data(json.utf8))
        XCTAssertEqual(full.readsOnOthers["B"], "rival")
        XCTAssertEqual(full.personaPrompt, "hi")
    }

    // MARK: - Anthropic client + provider

    func test_anthropicProvider_decodesStructuredSkeleton() async throws {
        let skeletonJSON = #"{"scene":"s","mood":"m","cast":[{"name":"Ada","voice":"dry","reads_on_others":[]}]}"#
        LLMStubURLProtocol.setResponse(anthropicResponse(skeletonJSON))

        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "test-key", session: stubSession()),
            model: "claude-haiku-4-5"
        )
        let skel = try await provider.requestJSON(
            CastSkeleton.self, system: "sys", user: "usr",
            schema: PersonaWriterSchemas.skeleton, temperature: 0.5, attempts: 1
        )
        XCTAssertEqual(skel.scene, "s")
        XCTAssertEqual(skel.cast.map(\.name), ["Ada"])
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1)
    }

    func test_anthropicProvider_retriesThenSucceeds() async throws {
        // First attempt: a server error; second: a valid persona.
        LLMStubURLProtocol.enqueue(Data(#"{"error":{"message":"overloaded"}}"#.utf8), statusCode: 529)
        LLMStubURLProtocol.enqueue(anthropicResponse(#"{"name":"Q","voice":"smug","persona_prompt":"hi","reads_on_others":[]}"#))

        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "k", session: stubSession()),
            model: "claude-sonnet-4-6"
        )
        let full = try await provider.requestJSON(
            PersonaFull.self, system: "s", user: "u",
            schema: PersonaWriterSchemas.persona, temperature: 0.4, attempts: 3
        )
        XCTAssertEqual(full.name, "Q")
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 2)
    }

    func test_anthropicClient_extractsErrorMessage() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad schema"}}"#.utf8)
        XCTAssertEqual(AnthropicMessagesClient.errorMessage(from: body), "bad schema")
    }

    // MARK: - Provider config

    func test_providerStore_roundTripsKindAndModel() {
        let defaults = UserDefaults(suiteName: "persona.provider.test")!
        defaults.removePersistentDomain(forName: "persona.provider.test")

        XCTAssertEqual(PersonaProviderStore.load(defaults).kind, .local, "local is the default")

        PersonaProviderStore.save(PersonaProviderConfig(kind: .anthropic, anthropicModel: "claude-sonnet-4-6"), defaults)
        let loaded = PersonaProviderStore.load(defaults)
        XCTAssertEqual(loaded.kind, .anthropic)
        XCTAssertEqual(loaded.anthropicModel, "claude-sonnet-4-6")
    }

    // MARK: - Request shape + retry policy

    private func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func test_anthropicClient_sendsStructuredRequestWithoutTemperature() async throws {
        LLMStubURLProtocol.setResponse(anthropicResponse(#"{"scene":"s","mood":"m","cast":[]}"#))
        let client = AnthropicMessagesClient(apiKey: "secret-key", session: stubSession())
        _ = try await client.complete(model: "claude-haiku-4-5", system: "sys", user: "usr", schemaJSON: PersonaWriterSchemas.skeleton)

        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "claude-haiku-4-5")
        XCTAssertNil(obj["temperature"], "temperature must be omitted (Opus 4.8/4.7 reject it)")
        let format = try XCTUnwrap((obj["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"])

        let headers = try XCTUnwrap(LLMStubURLProtocol.capturedHeaders())
        XCTAssertEqual(header(headers, "x-api-key"), "secret-key")
        XCTAssertEqual(header(headers, "anthropic-version"), "2023-06-01")
    }

    func test_anthropicProvider_doesNotRetryRefusal() async {
        LLMStubURLProtocol.setResponse(Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8))
        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "k", session: stubSession()), model: "claude-haiku-4-5"
        )
        do {
            _ = try await provider.requestJSON(CastSkeleton.self, system: "s", user: "u",
                                               schema: PersonaWriterSchemas.skeleton, temperature: 0.5, attempts: 3)
            XCTFail("a refusal should surface, not retry")
        } catch {}
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1, "refusal is non-retryable")
    }

    func test_anthropicProvider_doesNotRetry4xx() async {
        LLMStubURLProtocol.setResponse(Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8), statusCode: 401)
        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "bad", session: stubSession()), model: "claude-haiku-4-5"
        )
        do {
            _ = try await provider.requestJSON(PersonaFull.self, system: "s", user: "u",
                                               schema: PersonaWriterSchemas.persona, temperature: 0.4, attempts: 3)
            XCTFail("a 401 should surface, not retry")
        } catch {
            XCTAssertTrue("\(error)".contains("401") || "\(error)".lowercased().contains("invalid"),
                          "surfaces the real API error, not 'incomplete JSON'")
        }
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1, "4xx is non-retryable")
    }

    func test_decodeReads_emptyNullAbsentAllYieldEmpty() throws {
        func reads(_ json: String) throws -> [String: String] {
            try JSONDecoder().decode(PersonaStub.self, from: Data(json.utf8)).readsOnOthers
        }
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v","reads_on_others":[]}"#), [:])
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v","reads_on_others":{}}"#), [:])
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v","reads_on_others":null}"#), [:])
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v"}"#), [:])
    }
}
