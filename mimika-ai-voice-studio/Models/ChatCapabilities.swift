//
//  ChatCapabilities.swift
//  mimika-ai-voice-studio
//
//  Authoritative LM Studio capability state and persistent force-supported
//  overrides. Server observations are session-only; only explicit user
//  overrides are encoded in ChatSettings.

import Foundation

// MARK: - Capabilities

/// Capabilities LM Studio reports for a local language model.
nonisolated struct ModelCapabilities: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: Int

    static let vision = ModelCapabilities(rawValue: 1 << 0)
    static let tools = ModelCapabilities(rawValue: 1 << 1)
    static let reasoning = ModelCapabilities(rawValue: 1 << 2)
    static let all: ModelCapabilities = [.vision, .tools, .reasoning]

    /// Stable display order used by the Solo Chat header and App Settings.
    static let displayOrder: [ModelCapabilities] = [.vision, .tools, .reasoning]

    /// User-facing badge label.
    var displayName: String {
        switch self {
        case .vision: return "Vision"
        case .tools: return "Tools"
        case .reasoning: return "Reasoning"
        default: return "Capabilities"
        }
    }
}

/// Freshness of the last authoritative metadata response.
nonisolated enum CapabilityFreshness: Equatable, Sendable {
    case current
    case stale
    case unknown
}

/// Presentation source for one effective capability badge.
nonisolated enum CapabilityDisplayState: Equatable, Sendable {
    case current
    case stale
    case overridden
}

/// Resolved capability state for the active endpoint/model pair.
nonisolated struct ModelCapabilityState: Equatable, Sendable {
    var authoritative: ModelCapabilities
    var forced: ModelCapabilities
    var freshness: CapabilityFreshness

    static let unknown = ModelCapabilityState(
        authoritative: [],
        forced: [],
        freshness: .unknown
    )

    /// Capabilities the UI and composer may actually use.
    var effective: ModelCapabilities {
        authoritative.union(forced)
    }

    /// Resolve how one visible badge should explain its source.
    func displayState(for capability: ModelCapabilities) -> CapabilityDisplayState? {
        guard effective.contains(capability) else { return nil }
        if forced.contains(capability), !authoritative.contains(capability) {
            return .overridden
        }
        return freshness == .stale ? .stale : .current
    }
}

// MARK: - Endpoint/model identity

/// Stable identity used for capability observations, overrides, and reversion.
nonisolated struct ChatModelSelection: Equatable, Hashable, Sendable {
    var endpoint: String
    var model: String

    /// Canonical endpoint/model storage key.
    var storageKey: String {
        "\(Self.normalizeEndpoint(endpoint))\u{1F}\(model)"
    }

    /// Normalize insignificant endpoint formatting without changing its route.
    static func normalizeEndpoint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" { components.path = "" }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? trimmed
    }
}

// MARK: - Override persistence

extension ChatSettings {
    /// Force-supported capabilities for one endpoint/model pair.
    func forcedCapabilities(for selection: ChatModelSelection) -> ModelCapabilities {
        ModelCapabilities(rawValue: capabilityOverrides[selection.storageKey] ?? 0)
    }

    /// Persist or remove one force-supported capability.
    mutating func setCapability(
        _ capability: ModelCapabilities,
        forcedSupported: Bool,
        for selection: ChatModelSelection
    ) {
        var value = forcedCapabilities(for: selection)
        if forcedSupported {
            value.insert(capability)
        } else {
            value.remove(capability)
        }
        if value.isEmpty {
            capabilityOverrides.removeValue(forKey: selection.storageKey)
        } else {
            capabilityOverrides[selection.storageKey] = value.rawValue
        }
    }
}
