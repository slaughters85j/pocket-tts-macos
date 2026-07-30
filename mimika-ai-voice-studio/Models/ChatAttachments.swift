//
//  ChatAttachments.swift
//  mimika-ai-voice-studio
//
//  Pure in-memory value types for Solo Chat image attachments.

import Foundation

// MARK: - Attachment limits

/// Hard limits for one multimodal chat request.
nonisolated enum ChatImageLimits {
    /// Maximum attachments in one composer turn.
    static let maxImagesPerTurn = 10
    /// Maximum bytes in one original image.
    static let maxFileBytes = 20 * 1_024 * 1_024
    /// Maximum decoded width or height.
    static let maxDimension = 16_384
    /// Maximum decoded pixel count.
    static let maxPixels = 40_000_000
    /// Maximum encoded image bytes across the complete outgoing history.
    static let maxEncodedRequestBytes = 64 * 1_024 * 1_024
    /// Longest thumbnail edge.
    static let thumbnailMaxPixels = 160
    /// Longest preview edge.
    static let previewMaxPixels = 1_600
}

// MARK: - Attachment model

/// A validated image retained only for the lifetime of the current chat.
nonisolated struct ChatImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let fingerprint: String
    let thumbnailData: Data
    let previewData: Data

    /// Exact bytes contributed by the OpenAI data-URL string.
    var encodedURLByteCount: Int {
        let prefixBytes = "data:\(mimeType);base64,".utf8.count
        return prefixBytes + 4 * ((data.count + 2) / 3)
    }

    /// OpenAI-compatible inline image URL.
    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

/// Delivery validation for a user turn containing attachments.
nonisolated enum ChatDeliveryState: Equatable, Sendable {
    case pending
    case accepted
}
