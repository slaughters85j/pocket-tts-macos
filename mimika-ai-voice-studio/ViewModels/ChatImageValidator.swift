//
//  ChatImageValidator.swift
//  mimika-ai-voice-studio
//
//  Metadata-first validation and bounded display rendering for Solo Chat.

import AppKit
import CryptoKit
import Foundation
import ImageIO

// MARK: - Result

/// Result of validating one imported image.
nonisolated enum ChatImageValidationResult: Sendable {
    case accepted(ChatImageAttachment)
    case rejected(String)
}

// MARK: - Validator

/// Shared picker/drop validator that never modifies the original request bytes.
enum ChatImageValidator {
    /// Validate one supported image and derive bounded display-only PNGs.
    nonisolated static func validate(
        data: Data,
        filename: String,
        existingFingerprints: Set<String>
    ) -> ChatImageValidationResult {
        guard data.count <= ChatImageLimits.maxFileBytes else {
            return .rejected("\(filename) is larger than 20 MiB.")
        }
        guard let detected = detectedFormat(data: data) else {
            return .rejected("\(filename) is not a supported PNG, JPEG, or WebP image.")
        }

        let extensionName = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard detected.extensions.contains(extensionName) else {
            return .rejected("\(filename) has an extension that does not match its image data.")
        }

        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !existingFingerprints.contains(fingerprint) else {
            return .rejected("\(filename) is already in this chat.")
        }

        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
            let height = integerProperty(properties[kCGImagePropertyPixelHeight]),
            width > 0,
            height > 0
        else {
            return .rejected("\(filename) could not be decoded.")
        }

        guard width <= ChatImageLimits.maxDimension, height <= ChatImageLimits.maxDimension else {
            return .rejected("\(filename) exceeds 16,384 pixels on one side.")
        }
        guard Int64(width) * Int64(height) <= Int64(ChatImageLimits.maxPixels) else {
            return .rejected("\(filename) exceeds 40 megapixels.")
        }
        guard
            let thumbnailData = displayPNG(
                source: source,
                maxPixelSize: ChatImageLimits.thumbnailMaxPixels
            ),
            let previewData = displayPNG(
                source: source,
                maxPixelSize: ChatImageLimits.previewMaxPixels
            )
        else {
            return .rejected("\(filename) could not be prepared for display.")
        }

        return .accepted(
            ChatImageAttachment(
                id: UUID(),
                filename: filename,
                mimeType: detected.mimeType,
                data: data,
                pixelWidth: width,
                pixelHeight: height,
                fingerprint: fingerprint,
                thumbnailData: thumbnailData,
                previewData: previewData
            )
        )
    }

    /// Convert a metadata value from ImageIO to an integer.
    nonisolated private static func integerProperty(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    /// Produce a bounded display-only PNG while preserving the original bytes.
    nonisolated private static func displayPNG(
        source: CGImageSource,
        maxPixelSize: Int
    ) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Detect supported formats from magic bytes, never from filename alone.
    nonisolated private static func detectedFormat(
        data: Data
    ) -> (mimeType: String, extensions: Set<String>)? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ("image/png", ["png"])
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return ("image/jpeg", ["jpg", "jpeg"])
        }
        if bytes.count >= 12,
           String(bytes: bytes[0...3], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8...11], encoding: .ascii) == "WEBP" {
            return ("image/webp", ["webp"])
        }
        return nil
    }
}
