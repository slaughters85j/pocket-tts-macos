//
//  CapabilityOverrideSettingsSection.swift
//  mimika-ai-voice-studio
//
//  Endpoint/model-scoped force-supported toggles for providers that do not publish LM Studio capability metadata.

import SwiftUI

// MARK: - Capability overrides

/// App Settings section for persistent force-supported capability overrides.
struct CapabilityOverrideSettingsSection: View {
    @Binding var settings: ChatSettings
    let endpoint: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Model Capability Overrides")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Force support only when this endpoint does not publish LM Studio capability metadata. Overrides apply to the selected endpoint and model.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ModelCapabilities.displayOrder, id: \.rawValue) { capability in
                Toggle(
                    "Force \(capability.displayName) supported",
                    isOn: binding(for: capability)
                )
                .font(Theme.fontSM)
                .disabled(settings.model.isEmpty)
                .accessibilityIdentifier(
                    "appSettings.capabilityOverride.\(capability.displayName.lowercased())"
                )
            }
        }
    }

    /// Binding for one endpoint/model-specific force-supported toggle.
    private func binding(for capability: ModelCapabilities) -> Binding<Bool> {
        Binding(
            get: { settings.forcedCapabilities(for: selection).contains(capability) },
            set: { enabled in
                settings.setCapability(
                    capability,
                    forcedSupported: enabled,
                    for: selection
                )
            }
        )
    }

    /// Endpoint/model identity currently shown in the settings form.
    private var selection: ChatModelSelection {
        ChatModelSelection(endpoint: endpoint, model: settings.model)
    }
}
