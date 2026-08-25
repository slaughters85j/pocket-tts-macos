//
//  EnsembleViewModel+Attachments.swift
//  mimika-ai-voice-studio
//
//  Solo-parity image attach for Ensemble: picker/drop import via ChatImageValidator, pending tray, and session-only turn storage.
//

import Foundation

extension EnsembleViewModel {

    // MARK: - Import

    /// Import file URLs from NSOpenPanel or SwiftUI drop handling.
    func importImageURLs(_ urls: [URL]) async {
        guard supportsVision else {
            showNotice("The current model does not support Vision.")
            return
        }

        let payloads = await Task.detached(priority: .userInitiated) {
            urls.map { url -> (filename: String, data: Data?, error: String?) in
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    return (
                        url.lastPathComponent,
                        try Data(contentsOf: url, options: .mappedIfSafe),
                        nil
                    )
                } catch {
                    return (url.lastPathComponent, nil, "\(url.lastPathComponent) could not be read.")
                }
            }
        }.value

        await importImagePayloads(payloads)
    }

    /// Validate raw picker/drop payloads and append every valid batch member.
    func importImagePayloads(_ payloads: [(filename: String, data: Data?, error: String?)]) async {
        var fingerprints = Set(
            turns.flatMap(\.attachments).map(\.fingerprint)
                + pendingAttachments.map(\.fingerprint)
        )
        var encodedBytes = totalEncodedImageBytes
        var rejectionMessages: [String] = []

        for payload in payloads {
            if let error = payload.error {
                rejectionMessages.append(error)
                continue
            }
            guard let data = payload.data else {
                rejectionMessages.append("\(payload.filename) could not be read.")
                continue
            }
            guard pendingAttachments.count < ChatImageLimits.maxImagesPerTurn else {
                rejectionMessages.append("A turn can include at most 10 images.")
                break
            }

            let existingFingerprints = fingerprints
            let result = await Task.detached(priority: .userInitiated) {
                ChatImageValidator.validate(
                    data: data,
                    filename: payload.filename,
                    existingFingerprints: existingFingerprints
                )
            }.value

            switch result {
            case let .rejected(message):
                rejectionMessages.append(message)
            case let .accepted(attachment):
                guard encodedBytes + attachment.encodedURLByteCount
                        <= ChatImageLimits.maxEncodedRequestBytes
                else {
                    rejectionMessages.append(
                        "\(attachment.filename) would exceed the 64 MiB encoded request limit."
                    )
                    continue
                }
                pendingAttachments.append(attachment)
                fingerprints.insert(attachment.fingerprint)
                encodedBytes += attachment.encodedURLByteCount
            }
        }

        if !rejectionMessages.isEmpty {
            showNotice(rejectionMessages.joined(separator: " "))
        }
    }

    /// Accept a drop only when its transfer can enter the shared import pipeline.
    func shouldHandleImageDrop(_ urls: [URL]) -> Bool {
        guard supportsVision else {
            showNotice("The current model does not support Vision.")
            return false
        }
        guard !urls.isEmpty else { return false }

        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        guard urls.contains(where: {
            supportedExtensions.contains($0.pathExtension.lowercased())
        }) else {
            showNotice("Only PNG, JPEG/JPG, and WebP images can be added.")
            return false
        }
        return true
    }

    /// Remove one unsent composer attachment.
    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        if previewAttachment?.id == id { previewAttachment = nil }
    }

    /// Image data already retained by transcript history and the composer.
    var totalEncodedImageBytes: Int {
        turns
            .flatMap(\.attachments)
            .reduce(0) { $0 + $1.encodedURLByteCount }
            + pendingAttachments.reduce(0) { $0 + $1.encodedURLByteCount }
    }

    /// True when the human can send (text and/or images) while connected.
    var canSubmitUserTurn: Bool {
        guard case .connected = connectionState else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingAttachments.isEmpty
    }
}
