//
//  ChatViewModel+Capabilities.swift
//  mimika-ai-voice-studio
//
//  Connection-first, fail-soft LM Studio capability probing.

import Foundation

extension ChatViewModel {

    // MARK: Polling lifecycle

    /// Start one idempotent 30-second health/capability loop.
    func startHealthChecks() {
        guard healthCheckTask == nil else { return }
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkConnection()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break
                }
            }
        }
    }

    /// Stop future checks and cancel a request currently in progress.
    func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        capabilityProbeTask?.cancel()
        capabilityProbeTask = nil
        connectionRequestID = UUID()
        capabilityRequestID = UUID()
    }

    /// Publish connectivity first, then probe richer capability metadata.
    func checkConnection() async {
        let requestID = UUID()
        connectionRequestID = requestID
        let requestedEndpoint = appState.currentEndpointBaseURL
        let requestedModel = settings.model
        let configuredSelection = ChatModelSelection(
            endpoint: requestedEndpoint,
            model: requestedModel
        )
        if capabilitySelection != configuredSelection {
            if capabilityState.effective.contains(.vision),
               let capabilitySelection {
                previousVisionSelection = capabilitySelection
            }
            capabilityProbeTask?.cancel()
            capabilitySelection = configuredSelection
            capabilityState = ModelCapabilityState(
                authoritative: [],
                forced: settings.forcedCapabilities(for: configuredSelection),
                freshness: .unknown
            )
            applyReasoningConfiguration(nil, for: configuredSelection)
            lastAutomaticVisionRecoveryKey = nil
            showsVisionRecovery = false
            deferredVisionRecovery = false
        }
        let client = LocalLLMClient(
            baseURL: URL(string: requestedEndpoint) ?? Self.fallbackURL,
            session: llmSession
        )

        do {
            let models = try await client.listModels()
            guard
                !Task.isCancelled,
                requestID == connectionRequestID,
                ChatModelSelection.normalizeEndpoint(appState.currentEndpointBaseURL)
                    == ChatModelSelection.normalizeEndpoint(requestedEndpoint),
                settings.model == requestedModel
            else { return }
            guard let loaded = models.first else {
                connectionState = .disconnected(reason: "no models loaded")
                return
            }

            let effectiveModel = models.contains(settings.model) ? settings.model : loaded
            connectionState = .connected(model: effectiveModel)

            let selection = ChatModelSelection(
                endpoint: appState.currentEndpointBaseURL,
                model: effectiveModel
            )
            let forced = settings.forcedCapabilities(for: selection)
            capabilitySelection = selection
            await probeCapabilities(for: selection, forced: forced)
        } catch {
            guard !Task.isCancelled, requestID == connectionRequestID else { return }
            connectionState = .disconnected(reason: shortError(error))
        }
    }

    /// Probe authoritative LM Studio metadata with stale-result protection.
    private func probeCapabilities(
        for selection: ChatModelSelection,
        forced: ModelCapabilities
    ) async {
        capabilityProbeTask?.cancel()
        let requestID = UUID()
        capabilityRequestID = requestID
        let client = makeClient()
        let task = Task { try await client.modelMetadata(for: selection.model) }
        capabilityProbeTask = task

        do {
            let metadata = try await task.value
            guard
                !Task.isCancelled,
                requestID == capabilityRequestID,
                capabilitySelection == selection
            else { return }

            lastKnownCapabilities[selection.storageKey] = metadata.capabilities
            if let reasoning = metadata.reasoning {
                lastKnownReasoningConfigurations[selection.storageKey] = reasoning
            } else {
                lastKnownReasoningConfigurations.removeValue(
                    forKey: selection.storageKey
                )
            }
            applyCapabilityResolution(
                ModelCapabilityState(
                    authoritative: metadata.capabilities,
                    forced: forced,
                    freshness: .current
                ),
                for: selection
            )
            applyReasoningConfiguration(metadata.reasoning, for: selection)
            capabilityProbeTask = nil
        } catch {
            guard
                !Task.isCancelled,
                requestID == capabilityRequestID,
                capabilitySelection == selection
            else { return }
            let cached = lastKnownCapabilities[selection.storageKey]
            applyCapabilityResolution(
                ModelCapabilityState(
                    authoritative: cached ?? [],
                    forced: forced,
                    freshness: cached == nil ? .unknown : .stale
                ),
                for: selection
            )
            applyReasoningConfiguration(
                lastKnownReasoningConfigurations[selection.storageKey],
                for: selection
            )
            capabilityProbeTask = nil
        }
    }

    // MARK: Reasoning selection

    /// Resolve one model's reasoning control without guessing from its name.
    func applyReasoningConfiguration(
        _ configuration: ModelReasoningConfiguration?,
        for selection: ChatModelSelection
    ) {
        guard capabilitySelection == selection else { return }

        let resolved = configuration
            ?? (supportsReasoning ? .binaryFallback : nil)
        reasoningConfiguration = resolved

        guard let resolved else {
            reasoningSelection = nil
            return
        }

        let stored = reasoningSelections[selection.storageKey]
        let selected = stored.flatMap {
            resolved.allowedOptions.contains($0) ? $0 : nil
        } ?? resolved.defaultOption
        reasoningSelection = selected
        reasoningSelections[selection.storageKey] = selected
    }

    /// Change reasoning only while no request owns a captured payload.
    func setReasoningSelection(_ option: ModelReasoningOption) {
        guard activeTurn == nil else {
            showToast("Please wait until the model finishes responding.")
            return
        }
        guard
            let selection = capabilitySelection,
            let reasoningConfiguration,
            reasoningConfiguration.allowedOptions.contains(option)
        else { return }

        reasoningSelection = option
        reasoningSelections[selection.storageKey] = option
    }
}
