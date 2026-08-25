//
//  ChatViewModel+VisionRecovery.swift
//  mimika-ai-voice-studio
//
//  Deferred recovery actions after authoritative Vision capability loss.

import Foundation

extension ChatViewModel {

    // MARK: - Vision invariant

    /// Apply one same-selection capability result and enforce image-history safety.
    func applyCapabilityResolution(
        _ state: ModelCapabilityState,
        for selection: ChatModelSelection
    ) {
        capabilityState = state
        if state.effective.contains(.vision) {
            previousVisionSelection = selection
            showsVisionRecovery = false
            deferredVisionRecovery = false
        } else if state.freshness == .current {
            offerAutomaticVisionRecoveryIfNeeded()
        }
    }

    /// Automatically offer recovery once for one selection/history combination.
    func offerAutomaticVisionRecoveryIfNeeded() {
        guard let key = visionRecoveryOfferKey else { return }
        guard lastAutomaticVisionRecoveryKey != key else { return }
        lastAutomaticVisionRecoveryKey = key
        requestVisionRecoveryWhenSafe()
    }

    /// Defer recovery UI until no active request can mutate image history.
    func requestVisionRecoveryWhenSafe() {
        guard hasImageHistory else { return }
        if activeTurn != nil {
            deferredVisionRecovery = true
        } else {
            showsVisionRecovery = true
        }
    }

    /// Open recovery after an explicit user action, including unknown/stale states.
    func presentImageHistoryResolution() {
        requestVisionRecoveryWhenSafe()
    }

    /// Sent messages currently retain at least one image.
    var hasImageHistory: Bool {
        messages.contains { !$0.attachments.isEmpty }
    }

    /// Recovery controls are useful whenever retained images currently block sending.
    var canResolveImageHistory: Bool {
        imageHistorySendBlockMessage != nil
    }

    /// Context-sensitive title for authoritative loss versus unresolved metadata.
    var visionRecoveryDialogTitle: String {
        capabilityState.freshness == .current
            ? "Current model does not support Vision"
            : "Resolve image history"
    }

    /// Explain why image-bearing request history cannot be sent safely.
    var imageHistorySendBlockMessage: String? {
        guard hasImageHistory, !supportsVision else { return nil }
        switch capabilityState.freshness {
        case .current:
            return "The current model does not support Vision. Start a new chat, strip image history, revert the model, or enable an override."
        case .stale, .unknown:
            return "Vision support is not confirmed for the current model. Use Resolve Image History, choose a Vision model, or enable an override."
        }
    }

    /// Stable key that changes with either the active selection or retained images.
    private var visionRecoveryOfferKey: String? {
        guard hasImageHistory, let capabilitySelection else { return nil }
        let attachmentIDs = messages
            .flatMap(\.attachments)
            .map { $0.id.uuidString }
            .joined(separator: ",")
        return "\(capabilitySelection.storageKey)\u{1F}\(attachmentIDs)"
    }

    // MARK: - Recovery actions

    /// Clear conversation and attachment state while preserving typed text.
    func startNewChatForVisionRecovery() {
        guard activeTurn == nil else {
            deferredVisionRecovery = true
            return
        }
        messages.removeAll()
        pendingAttachments.removeAll()
        previewAttachment = nil
        showsVisionRecovery = false
        beginFreshSoloThread()
    }

    /// Remove sent images while preserving all transcript text.
    func stripImageHistory() {
        guard activeTurn == nil else {
            deferredVisionRecovery = true
            return
        }
        for index in messages.indices {
            messages[index].attachments = []
            messages[index].deliveryState = nil
        }
        showsVisionRecovery = false
    }

    /// Atomically restore the last Vision-capable endpoint/model pair.
    func revertToPreviousVisionModel() {
        guard activeTurn == nil else {
            deferredVisionRecovery = true
            return
        }
        guard let previousVisionSelection else {
            showToast("The previous Vision model is no longer available.")
            return
        }
        guard previousVisionSelection != appState.currentChatModelSelection else {
            showToast("The previous Vision model is no longer available.")
            return
        }

        Task {
            do {
                guard let endpoint = URL(string: previousVisionSelection.endpoint) else {
                    throw LocalLLMClient.ClientError.invalidURL(previousVisionSelection.endpoint)
                }
                let client = LocalLLMClient(baseURL: endpoint, session: llmSession)
                let models = try await client.listModels()
                guard models.contains(previousVisionSelection.model) else {
                    throw LocalLLMClient.ClientError.modelMetadataUnavailable(
                        previousVisionSelection.model
                    )
                }

                var restoredSettings = settings
                restoredSettings.model = previousVisionSelection.model
                let forced = restoredSettings.forcedCapabilities(
                    for: previousVisionSelection
                )
                if !forced.contains(.vision) {
                    let capabilities: ModelCapabilities
                    do {
                        capabilities = try await client.modelCapabilities(
                            for: previousVisionSelection.model
                        )
                    } catch {
                        guard let cached = lastKnownCapabilities[
                            previousVisionSelection.storageKey
                        ] else { throw error }
                        capabilities = cached
                    }
                    guard capabilities.contains(.vision) else {
                        throw LocalLLMClient.ClientError.visionUnavailable(
                            previousVisionSelection.model
                        )
                    }
                }
                try appState.applyChatConfiguration(
                    restoredSettings,
                    endpointBaseURL: previousVisionSelection.endpoint
                )
                settings = appState.chatSettings
                showsVisionRecovery = false
                await checkConnection()
            } catch {
                showToast("Could not restore the previous Vision model: \(shortError(error))")
            }
        }
    }
}
