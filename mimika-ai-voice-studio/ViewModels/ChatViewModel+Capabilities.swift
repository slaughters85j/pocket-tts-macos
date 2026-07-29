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
        let task = Task { try await client.modelCapabilities(for: selection.model) }
        capabilityProbeTask = task

        do {
            let capabilities = try await task.value
            guard
                !Task.isCancelled,
                requestID == capabilityRequestID,
                capabilitySelection == selection
            else { return }

            lastKnownCapabilities[selection.storageKey] = capabilities
            applyCapabilityResolution(
                ModelCapabilityState(
                    authoritative: capabilities,
                    forced: forced,
                    freshness: .current
                ),
                for: selection
            )
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
            capabilityProbeTask = nil
        }
    }
}
