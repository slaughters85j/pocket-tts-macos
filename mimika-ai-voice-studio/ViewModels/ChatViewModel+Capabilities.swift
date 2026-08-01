//
//  ChatViewModel+Capabilities.swift
//  mimika-ai-voice-studio
//
//  Connection-first, fail-soft LM Studio capability probing.

import Foundation

extension ChatViewModel {

    // MARK: Polling lifecycle

    /// Start one idempotent 1-second health/capability loop.
    /// UI state is only written when connectivity or model actually changes.
    func startHealthChecks() {
        guard healthCheckTask == nil else { return }
        // Ensemble Compact may open later in the same process; pre-warm once.
        QwenTokenEstimator.prewarm()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkConnection()
                do {
                    try await Task.sleep(for: .seconds(1))
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
    /// Polls every second; skips Observation writes and capability probes when
    /// the serving model set is unchanged.
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
            let models = try await client.listServingModels()
            guard
                !Task.isCancelled,
                requestID == connectionRequestID,
                ChatModelSelection.normalizeEndpoint(appState.currentEndpointBaseURL)
                    == ChatModelSelection.normalizeEndpoint(requestedEndpoint),
                settings.model == requestedModel
            else { return }
            guard let loaded = models.first else {
                setConnectionStateIfChanged(.disconnected(reason: "no model loaded"))
                return
            }

            let effectiveModel = models.contains(settings.model) ? settings.model : loaded
            let next = ConnectionState.connected(model: effectiveModel)
            let connectionChanged = connectionState != next
            setConnectionStateIfChanged(next)

            let selection = ChatModelSelection(
                endpoint: appState.currentEndpointBaseURL,
                model: effectiveModel
            )
            let forced = settings.forcedCapabilities(for: selection)
            // Re-probe only when the serving model/endpoint changed, or we
            // never got a successful capability read for this selection.
            let needsProbe = connectionChanged
                || capabilitySelection != selection
                || capabilityState.freshness == .unknown
            if capabilitySelection != selection {
                capabilitySelection = selection
            }
            if needsProbe {
                await probeCapabilities(for: selection, forced: forced)
            }
        } catch {
            guard !Task.isCancelled, requestID == connectionRequestID else { return }
            setConnectionStateIfChanged(
                .disconnected(reason: LocalLLMClient.friendlyConnectionError(error))
            )
        }
    }

    /// Avoid redundant `@Observable` publishes on a 1s poll.
    /// Sanitize disconnect reasons at write time (toolbar + composer share this state).
    private func setConnectionStateIfChanged(_ next: ConnectionState) {
        let cleaned: ConnectionState
        if case let .disconnected(reason) = next {
            cleaned = .disconnected(reason: LocalLLMClient.sanitizedConnectionReason(reason))
        } else {
            cleaned = next
        }
        guard connectionState != cleaned else { return }
        connectionState = cleaned
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
    /// Ensemble keeps its own stored selection (defaults to Off) so Solo
    /// effort levels are not inherited into multi-agent turns.
    func applyReasoningConfiguration(
        _ configuration: ModelReasoningConfiguration?,
        for selection: ChatModelSelection
    ) {
        guard capabilitySelection == selection else { return }

        let base = configuration
            ?? (supportsReasoning ? .binaryFallback : nil)
        let resolved = Self.reasoningConfiguration(
            base: base,
            forEnsemble: appState.chatSubMode == .ensemble
        )
        reasoningConfiguration = resolved

        guard let resolved else {
            reasoningSelection = nil
            return
        }

        let key = reasoningStorageKey(for: selection)
        let stored = reasoningSelections[key]
        let selected = stored.flatMap {
            resolved.allowedOptions.contains($0) ? $0 : nil
        } ?? Self.defaultReasoningOption(
            for: resolved,
            ensemble: appState.chatSubMode == .ensemble
        )
        reasoningSelection = selected
        reasoningSelections[key] = selected
    }

    /// Re-resolve the active model's thinking control after Solo ↔ Ensemble
    /// switch so the shared badge uses the mode-scoped default/store.
    func refreshReasoningForChatSubMode() {
        guard let selection = capabilitySelection else { return }
        let config = lastKnownReasoningConfigurations[selection.storageKey]
            ?? reasoningConfiguration
        applyReasoningConfiguration(config, for: selection)
    }

    /// Change reasoning only while no request owns a captured payload.
    /// Ensemble shows a one-shot toast when thinking is turned on (not when
    /// only changing effort level among already-on values).
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

        let previous = reasoningSelection
        reasoningSelection = option
        reasoningSelections[reasoningStorageKey(for: selection)] = option

        if appState.chatSubMode == .ensemble,
           option != .off,
           previous == .off || previous == nil {
            showToast(
                "Larger thinking models tend to cause non-responsive turns in Ensemble."
            )
        }
    }

    /// Solo keys by model; Ensemble uses a distinct key so defaults stay Off.
    private func reasoningStorageKey(for selection: ChatModelSelection) -> String {
        if appState.chatSubMode == .ensemble {
            return selection.storageKey + "|ensemble"
        }
        return selection.storageKey
    }

    /// Ensemble always offers Off (injecting it when LM Studio only lists
    /// low/medium/high) so multi-agent runs can disable thinking by default.
    private static func reasoningConfiguration(
        base: ModelReasoningConfiguration?,
        forEnsemble: Bool
    ) -> ModelReasoningConfiguration? {
        guard let base else { return nil }
        guard forEnsemble else { return base }
        var options = base.allowedOptions
        if !options.contains(.off) {
            options.insert(.off, at: 0)
        }
        return ModelReasoningConfiguration(
            allowedOptions: options,
            defaultOption: options.contains(.off) ? .off : base.defaultOption
        )
    }

    private static func defaultReasoningOption(
        for configuration: ModelReasoningConfiguration,
        ensemble: Bool
    ) -> ModelReasoningOption {
        if ensemble, configuration.allowedOptions.contains(.off) {
            return .off
        }
        return configuration.defaultOption
    }
}
