//
//  LocalLLMDTOs.swift
//  mimika-ai-voice-studio
//
//  OpenAI-compatible chat DTOs and LM Studio model metadata DTOs.

import Foundation

// MARK: - Chat request

/// Optional request properties encode only when present, preserving the existing text-only request shape for callers that do not use images.
nonisolated struct ChatRequest: Encodable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
    var temperature: Double? = nil
    var response_format: ResponseFormatDTO? = nil
    var stop: [String]? = nil
    var max_tokens: Int? = nil
    var top_p: Double? = nil
    var top_k: Int? = nil
    var repeat_penalty: Double? = nil
    var reasoning_effort: String? = nil
}

nonisolated struct ResponseFormatDTO: Encodable {
    let type: String
}

/// Validated lifecycle events emitted by Solo Chat streaming.
nonisolated enum ChatStreamEvent: Equatable, Sendable {
    case accepted(statusCode: Int)
    case delta(String)
}

nonisolated struct APIMessage: Encodable {
    let role: String
    let content: APIMessageContent

    init(role: String, content: APIMessageContent) {
        self.role = role
        self.content = content
    }

    init(message: ChatMessage) {
        role = message.role.rawValue
        guard message.role == .user, !message.attachments.isEmpty else {
            content = .text(message.content)
            return
        }
        var blocks: [APIContentBlock] = []
        if !message.content.isEmpty {
            blocks.append(.text(message.content))
        }
        blocks.append(contentsOf: message.attachments.map { .imageURL($0.dataURL) })
        content = .blocks(blocks)
    }
}

nonisolated enum APIMessageContent: Encodable {
    case text(String)
    case blocks([APIContentBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .blocks(value):
            try container.encode(value)
        }
    }
}

nonisolated struct APIContentBlock: Encodable {
    let type: String
    let text: String?
    let imageURL: ImageURL?

    struct ImageURL: Encodable {
        let url: String
    }

    static func text(_ value: String) -> APIContentBlock {
        APIContentBlock(type: "text", text: value, imageURL: nil)
    }

    static func imageURL(_ value: String) -> APIContentBlock {
        APIContentBlock(type: "image_url", text: nil, imageURL: ImageURL(url: value))
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

// MARK: - Chat responses

nonisolated struct ChatStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
        /// Why the server stopped. `"length"` means it hit `max_tokens` — for a reasoning model that usually means the thinking consumed the whole budget and no content was ever written. Without this the app cannot tell a deliberate short answer from a truncated one.
        let finish_reason: String?

        struct Delta: Decodable {
            let content: String?
            let reasoning: String?
            let reasoning_content: String?
        }
    }
}

nonisolated struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message

        struct Message: Decodable {
            let content: String?
        }
    }
}

// MARK: - Model responses

nonisolated struct ModelsResponse: Decodable {
    let data: [Entry]

    struct Entry: Decodable {
        let id: String
    }
}

nonisolated struct LMStudioModelsResponse: Decodable {
    let models: [Entry]

    /// IDs for models that currently have at least one loaded instance. Includes both instance ids and catalog keys so saved preferences match.
    func servingModelIDs() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for entry in models where !entry.loadedInstances.isEmpty {
            for inst in entry.loadedInstances {
                if seen.insert(inst.id).inserted { out.append(inst.id) }
            }
            if seen.insert(entry.key).inserted { out.append(entry.key) }
        }
        return out
    }

    /// Downloaded/catalog model keys (picker source) — not necessarily loaded.
    func catalogModelIDs() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for entry in models {
            if seen.insert(entry.key).inserted { out.append(entry.key) }
        }
        return out
    }

    /// Loaded instance ids only (for unload).
    func loadedInstanceIDs() -> [String] {
        models.flatMap { $0.loadedInstances.map(\.id) }
    }

    /// Loaded instance ids belonging to one model, so a caller holding only a model id can eject it. Matches on the catalog key or on any instance id, because a saved preference may hold either.
    func loadedInstanceIDs(for model: String) -> [String] {
        models
            .filter { entry in
                idsMatch(entry.key, model) || entry.loadedInstances.contains { idsMatch($0.id, model) }
            }
            .flatMap { $0.loadedInstances.map(\.id) }
    }

    /// True if `model` is already loaded (matches key or instance id).
    func isServing(_ model: String) -> Bool {
        servingModelIDs().contains { idsMatch($0, model) }
    }

    private func idsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.hasSuffix(b) || b.hasSuffix(a) { return true }
        let ta = a.split(separator: "/").last.map(String.init) ?? a
        let tb = b.split(separator: "/").last.map(String.init) ?? b
        return ta == tb
    }

    struct Entry: Decodable {
        let key: String
        let capabilities: Capabilities?
        let loadedInstances: [LoadedInstance]
        /// Architecture / publisher max (tokens), when LM Studio reports it.
        let maxContextLength: Int?
        let config: Config?

        private enum CodingKeys: String, CodingKey {
            case key
            case capabilities
            case loadedInstances = "loaded_instances"
            case maxContextLength = "max_context_length"
            case config
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            loadedInstances = try container.decodeIfPresent(
                [LoadedInstance].self,
                forKey: .loadedInstances
            ) ?? []
            maxContextLength = Self.decodeFlexibleInt(container, key: .maxContextLength)
            config = try container.decodeIfPresent(Config.self, forKey: .config)
        }

        /// Fallback when no loaded instance is matched. Prefer architecture `max_context_length` over bare `config.context_length`:
        /// the latter is often a catalog default (e.g. 8192) that understates the model’s real ceiling when the instance isn’t matched by id.
        var resolvedContextLength: Int? {
            if let n = maxContextLength, n > 0 { return n }
            if let n = config?.contextLength, n > 0 { return n }
            return nil
        }

        /// Loaded instance n_ctx for `model` if present (actual server capacity).
        func loadedContextLength(for model: String) -> Int? {
            let match = loadedInstances.first(where: { Self.idsMatch($0.id, model) })
                ?? loadedInstances.first
            if let n = match?.config?.contextLength, n > 0 { return n }
            return nil
        }

        private static func idsMatch(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            // LM Studio sometimes keys as publisher/name and serves as a longer path.
            if a.hasSuffix(b) || b.hasSuffix(a) { return true }
            let ta = a.split(separator: "/").last.map(String.init) ?? a
            let tb = b.split(separator: "/").last.map(String.init) ?? b
            return ta == tb
        }

        private static func decodeFlexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Int? {
            if let i = try? container.decodeIfPresent(Int.self, forKey: key) { return i }
            if let d = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
            if let s = try? container.decodeIfPresent(String.self, forKey: key),
               let i = Int(s) { return i }
            return nil
        }
    }

    struct Config: Decodable {
        /// Context length of the *loaded* instance (user-configured in LM Studio).
        let contextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let i = try? container.decodeIfPresent(Int.self, forKey: .contextLength) {
                contextLength = i
            } else if let d = try? container.decodeIfPresent(Double.self, forKey: .contextLength) {
                contextLength = Int(d)
            } else if let s = try? container.decodeIfPresent(String.self, forKey: .contextLength),
                      let i = Int(s) {
                contextLength = i
            } else {
                contextLength = nil
            }
        }
    }

    struct LoadedInstance: Decodable {
        let id: String
        let config: Config?

        private enum CodingKeys: String, CodingKey {
            case id
            case config
        }
    }

    struct Capabilities: Decodable {
        let vision: Bool
        let trainedForToolUse: Bool
        let reasoning: Reasoning?

        private enum CodingKeys: String, CodingKey {
            case vision
            case trainedForToolUse = "trained_for_tool_use"
            case reasoning
        }
    }

    struct Reasoning: Decodable {
        let allowedOptions: [String]?
        let defaultValue: String?

        private enum CodingKeys: String, CodingKey {
            case allowedOptions = "allowed_options"
            case defaultValue = "default"
        }

        /// LM Studio reports support through at least one usable option.
        var indicatesSupport: Bool {
            configuration != nil
        }

        /// Typed control surface preserving LM Studio's option order.
        var configuration: ModelReasoningConfiguration? {
            var options = (allowedOptions ?? []).compactMap {
                ModelReasoningOption(rawValue: $0.lowercased())
            }
            let defaultOption = defaultValue.flatMap {
                ModelReasoningOption(rawValue: $0.lowercased())
            }

            if options.isEmpty, let defaultOption {
                options = [defaultOption]
            }
            guard options.contains(where: { $0 != .off }) else {
                return nil
            }

            let uniqueOptions = options.reduce(into: [ModelReasoningOption]()) {
                if !$0.contains($1) {
                    $0.append($1)
                }
            }
            return ModelReasoningConfiguration(
                allowedOptions: uniqueOptions,
                defaultOption: defaultOption.flatMap {
                    uniqueOptions.contains($0) ? $0 : nil
                } ?? uniqueOptions[0]
            )
        }
    }
}
