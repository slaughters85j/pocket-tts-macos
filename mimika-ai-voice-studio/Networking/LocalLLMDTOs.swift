//
//  LocalLLMDTOs.swift
//  mimika-ai-voice-studio
//
//  OpenAI-compatible chat DTOs and LM Studio model metadata DTOs.

import Foundation

// MARK: - Chat request

/// Optional request properties encode only when present, preserving the
/// existing text-only request shape for callers that do not use images.
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

    struct Entry: Decodable {
        let key: String
        let capabilities: Capabilities?
        let loadedInstances: [LoadedInstance]

        private enum CodingKeys: String, CodingKey {
            case key
            case capabilities
            case loadedInstances = "loaded_instances"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            loadedInstances = try container.decodeIfPresent(
                [LoadedInstance].self,
                forKey: .loadedInstances
            ) ?? []
        }
    }

    struct LoadedInstance: Decodable {
        let id: String
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
            let unsupported = Set(["", "off", "none", "disabled", "false"])
            if allowedOptions?.contains(where: {
                !unsupported.contains($0.lowercased())
            }) == true {
                return true
            }
            guard let defaultValue else { return false }
            return !unsupported.contains(defaultValue.lowercased())
        }
    }
}
