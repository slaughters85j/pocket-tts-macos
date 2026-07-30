//
//  ChatImageAttachmentTests.swift
//  mimika-ai-voice-studioTests
//

import AppKit
import Compression
import XCTest
@testable import mimika_ai_voice_studio

final class ChatImageAttachmentTests: XCTestCase {

    // MARK: - Supported formats

    func test_validator_acceptsPNGAndJPEG() throws {
        let png = try makeRasterData(type: .png, width: 4, height: 3)
        let jpeg = try makeRasterData(type: .jpeg, width: 4, height: 3)

        assertAccepted(data: png, filename: "photo.png", mimeType: "image/png")
        assertAccepted(data: jpeg, filename: "photo.JPG", mimeType: "image/jpeg")
    }

    func test_validator_acceptsWebPWhenImageIOSupportsIt() throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"
        ))
        switch ChatImageValidator.validate(
            data: data,
            filename: "photo.webp",
            existingFingerprints: []
        ) {
        case let .accepted(attachment):
            XCTAssertEqual(attachment.mimeType, "image/webp")
            XCTAssertEqual(attachment.data, data)
        case let .rejected(message):
            XCTFail("Expected WebP support from ImageIO: \(message)")
        }
    }

    // MARK: - Rejections

    func test_validator_rejectsCorruptUnsupportedSpoofedAndDuplicateData() throws {
        assertRejected(data: Data([0x89, 0x50, 0x4E, 0x47]), filename: "bad.png")
        assertRejected(data: Data("GIF89a".utf8), filename: "bad.gif")

        let png = try makeRasterData(type: .png, width: 2, height: 2)
        assertRejected(data: png, filename: "spoof.jpg")

        let accepted = try acceptedAttachment(data: png, filename: "first.png")
        switch ChatImageValidator.validate(
            data: png,
            filename: "second.png",
            existingFingerprints: [accepted.fingerprint]
        ) {
        case .accepted:
            XCTFail("Expected exact duplicate rejection")
        case let .rejected(message):
            XCTAssertTrue(message.contains("already in this chat"))
        }
    }

    func test_validator_rejectsMetadataDimensionsBeforeDisplayDecode() throws {
        let tooWide = try makeGrayscalePNG(
            width: ChatImageLimits.maxDimension + 1,
            height: 1
        )
        let tooManyPixels = try makeGrayscalePNG(width: 10_000, height: 4_001)

        assertRejected(data: tooWide, filename: "wide.png", containing: "16,384")
        assertRejected(data: tooManyPixels, filename: "large.png", containing: "40 megapixels")
    }

    func test_validator_enforcesFileLimitAndPreservesRawBytes() throws {
        let original = try makeRasterData(type: .png, width: 2, height: 2)
        let accepted = try acceptedAttachment(data: original, filename: "small.png")
        XCTAssertEqual(accepted.data, original)

        var oversized = original
        oversized.append(Data(repeating: 0, count: ChatImageLimits.maxFileBytes - original.count + 1))
        assertRejected(data: oversized, filename: "large.png", containing: "20 MiB")
    }

    func test_displayImagesAreBoundedWithoutChangingAspectRatio() throws {
        let original = try makeRasterData(type: .png, width: 2_000, height: 1_000)
        let attachment = try acceptedAttachment(data: original, filename: "wide.png")
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(data: attachment.thumbnailData))
        let preview = try XCTUnwrap(NSBitmapImageRep(data: attachment.previewData))

        XCTAssertLessThanOrEqual(max(thumbnail.pixelsWide, thumbnail.pixelsHigh), 160)
        XCTAssertLessThanOrEqual(max(preview.pixelsWide, preview.pixelsHigh), 1_600)
        XCTAssertEqual(
            Double(thumbnail.pixelsWide) / Double(thumbnail.pixelsHigh),
            2,
            accuracy: 0.02
        )
    }

    func test_chatMessageCodableNeverPersistsAttachmentsOrDeliveryMarkers() throws {
        let image = try acceptedAttachment(
            data: makeRasterData(type: .png, width: 1, height: 1),
            filename: "private.png"
        )
        let message = ChatMessage(
            role: .user,
            content: "hello",
            attachments: [image],
            deliveryState: .accepted
        )

        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("private.png"))
        XCTAssertFalse(json.contains("attachments"))
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertTrue(decoded.attachments.isEmpty)
        XCTAssertNil(decoded.deliveryState)
        XCTAssertEqual(decoded.content, "hello")
    }

    func test_encodedHistoryBoundaryIncludesEveryDataURLPrefix() {
        let sizes = [12_582_897, 12_582_897, 12_582_897, 12_582_891]
        let attachments = sizes.enumerated().map { index, size in
            ChatImageAttachment(
                id: UUID(),
                filename: "\(index).png",
                mimeType: "image/png",
                data: Data(repeating: UInt8(index), count: size),
                pixelWidth: 1,
                pixelHeight: 1,
                fingerprint: "\(index)",
                thumbnailData: Data(),
                previewData: Data()
            )
        }

        XCTAssertEqual(
            attachments.reduce(0) { $0 + $1.encodedURLByteCount },
            ChatImageLimits.maxEncodedRequestBytes
        )
        var oneByteOver = attachments
        let last = oneByteOver.removeLast()
        oneByteOver.append(ChatImageAttachment(
            id: last.id,
            filename: last.filename,
            mimeType: last.mimeType,
            data: last.data + Data([0]),
            pixelWidth: last.pixelWidth,
            pixelHeight: last.pixelHeight,
            fingerprint: last.fingerprint,
            thumbnailData: last.thumbnailData,
            previewData: last.previewData
        ))
        XCTAssertGreaterThan(
            oneByteOver.reduce(0) { $0 + $1.encodedURLByteCount },
            ChatImageLimits.maxEncodedRequestBytes
        )
    }

    // MARK: - Helpers

    private enum RasterType {
        case png
        case jpeg
    }

    private func makeRasterData(type: RasterType, width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let fileType: NSBitmapImageRep.FileType = type == .png ? .png : .jpeg
        return try XCTUnwrap(bitmap.representation(using: fileType, properties: [:]))
    }

    private func acceptedAttachment(data: Data, filename: String) throws -> ChatImageAttachment {
        switch ChatImageValidator.validate(
            data: data,
            filename: filename,
            existingFingerprints: []
        ) {
        case let .accepted(attachment):
            return attachment
        case let .rejected(message):
            XCTFail("Expected acceptance: \(message)")
            throw ValidationFailure.rejected
        }
    }

    private func assertAccepted(data: Data, filename: String, mimeType: String) {
        switch ChatImageValidator.validate(
            data: data,
            filename: filename,
            existingFingerprints: []
        ) {
        case let .accepted(attachment):
            XCTAssertEqual(attachment.mimeType, mimeType)
            XCTAssertEqual(attachment.data, data)
        case let .rejected(message):
            XCTFail("Expected acceptance: \(message)")
        }
    }

    private func assertRejected(
        data: Data,
        filename: String,
        containing expected: String? = nil
    ) {
        switch ChatImageValidator.validate(
            data: data,
            filename: filename,
            existingFingerprints: []
        ) {
        case .accepted:
            XCTFail("Expected rejection for \(filename)")
        case let .rejected(message):
            if let expected { XCTAssertTrue(message.contains(expected), message) }
        }
    }

    private func makeGrayscalePNG(width: Int, height: Int) throws -> Data {
        let rowBytes = width + 1
        let raw = Data(repeating: 0, count: rowBytes * height)
        var compressed = Data(count: raw.count)
        let encodedCount = compressed.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedCount > 0 else { throw ValidationFailure.compressionFailed }
        compressed.removeSubrange(encodedCount..<compressed.count)

        var header = Data()
        header.append(contentsOf: bigEndianBytes(width))
        header.append(contentsOf: bigEndianBytes(height))
        header.append(contentsOf: [8, 0, 0, 0, 0])

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        appendPNGChunk(type: "IHDR", payload: header, to: &png)
        appendPNGChunk(type: "IDAT", payload: compressed, to: &png)
        appendPNGChunk(type: "IEND", payload: Data(), to: &png)
        return png
    }

    private func appendPNGChunk(type: String, payload: Data, to data: inout Data) {
        data.append(contentsOf: bigEndianBytes(payload.count))
        let typeData = Data(type.utf8)
        data.append(typeData)
        data.append(payload)
        var checksumInput = typeData
        checksumInput.append(payload)
        data.append(contentsOf: bigEndianBytes(Int(crc32(checksumInput))))
    }

    private func bigEndianBytes(_ value: Int) -> [UInt8] {
        let value = UInt32(value)
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1
                    ? (crc >> 1) ^ 0xEDB8_8320
                    : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private enum ValidationFailure: Error {
        case rejected
        case compressionFailed
    }
}
