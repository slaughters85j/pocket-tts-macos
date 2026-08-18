//
//  ModelCapabilityBadges.swift
//  mimika-ai-voice-studio
//
//  Compact capability badges beside Solo Chat's active model.

import SwiftUI

// MARK: - Badge group

/// Supported capability badges in stable Vision, Tools, Reasoning order.
struct ModelCapabilityBadges: View {
    let state: ModelCapabilityState

    var body: some View {
        HStack(spacing: Theme.space2) {
            ForEach(ModelCapabilities.displayOrder, id: \.rawValue) { capability in
                if let displayState = state.displayState(for: capability) {
                    ModelCapabilityBadge(
                        capability: capability,
                        displayState: displayState
                    )
                }
            }
        }
    }
}

// MARK: - Badge

/// One clickable capability badge with source-aware explanatory popover.
private struct ModelCapabilityBadge: View {
    let capability: ModelCapabilities
    let displayState: CapabilityDisplayState
    @State private var showsPopover = false

    var body: some View {
        Button(action: { showsPopover.toggle() }) {
            capabilityGlyph
                .frame(width: 13, height: 13)
                .frame(width: 26, height: 20)
                .foregroundStyle(capabilityColor)
                .background(capabilityColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(capabilityColor.opacity(0.9), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if displayState == .stale {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(capabilityColor)
                            .background(Theme.bgPrimary, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .opacity(displayState == .stale ? 0.65 : 1)
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.capability.\(capability.displayName.lowercased())")
        .accessibilityLabel("\(capability.displayName) capability")
        .help(capability.displayName)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.space2) {
                Text("Model supports \(capability.displayName)")
                    .font(Theme.fontSMBold)
                switch displayState {
                case .current:
                    EmptyView()
                case .stale:
                    Text("Last confirmed by LM Studio. The latest capability check failed.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                case .overridden:
                    Text("Force supported in App Settings")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Theme.space4)
            .frame(maxWidth: 300, alignment: .leading)
        }
    }

    // MARK: Appearance

    /// LM Studio-inspired capability color.
    private var capabilityColor: Color {
        switch capability {
        case .vision:
            return Color(red: 1.00, green: 0.78, blue: 0.00)
        case .tools:
            return Color(red: 0.16, green: 0.52, blue: 1.00)
        case .reasoning:
            return Color(red: 0.00, green: 0.82, blue: 0.48)
        default:
            return Theme.textSecondary
        }
    }

    /// Native vector glyph matching the capability represented by the badge.
    @ViewBuilder
    private var capabilityGlyph: some View {
        switch capability {
        case .vision:
            Image(systemName: "eye")
                .font(.system(size: 10, weight: .medium))
        case .tools:
            Image(systemName: "hammer")
                .font(.system(size: 10, weight: .medium))
        case .reasoning:
            ReasoningCapabilityGlyph()
        default:
            Image(systemName: "questionmark")
                .font(.system(size: 10, weight: .medium))
        }
    }
}

// MARK: - Reasoning glyph

/// Compact split-circle mark matching the reasoning badge in the mock-up.
private struct ReasoningCapabilityGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 1.15)
            Capsule()
                .frame(width: 1.15, height: 8)
        }
        .padding(1)
        .accessibilityHidden(true)
    }
}

// MARK: - Reasoning control

/// Reasoning toggle or effort picker derived from LM Studio metadata.
struct ModelReasoningControl: View {
    @Bindable var viewModel: ChatViewModel

    @State private var showsInfo = false

    var body: some View {
        if viewModel.supportsReasoning,
           let configuration = viewModel.reasoningConfiguration,
           viewModel.reasoningSelection != nil {
            HStack(spacing: Theme.space2) {
                if configuration.usesEffortLevels {
                    Text("Thinking")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)

                    Picker("", selection: selectionBinding) {
                        ForEach(
                            configuration.allowedOptions,
                            id: \.rawValue
                        ) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // Locked only while a Solo turn is in flight, because that request was already built and cannot take the new value. An Ensemble RUN is deliberately not a lock: the loop reads the effort fresh for each speaker, so a change lands on the next turn — and being unable to fix a thinking setting without stopping the whole episode is worse than the change arriving one turn late.
                    .disabled(
                        viewModel.hasActiveTurn
                            || configuration.allowedOptions.count < 2
                    )
                    .accessibilityLabel("Thinking level")
                    .accessibilityIdentifier("chat.reasoningLevel")
                } else {
                    Toggle("Enable Thinking", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .disabled(
                            viewModel.hasActiveTurn
                                || !canToggle
                        )
                        .accessibilityIdentifier("chat.reasoningEnabled")
                }

                Button {
                    showsInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("About thinking")
                .accessibilityLabel("About thinking")
                .accessibilityIdentifier("chat.reasoningInfo")
                .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
                    Text(
                        configuration.usesEffortLevels
                            ? "Controls how much the model will think when replying"
                            : "Controls whether the model will think before replying"
                    )
                        .font(Theme.fontSM)
                        .padding(Theme.space4)
                }
            }
        }
    }

    /// Binding for models exposing Low/Medium/High effort levels.
    private var selectionBinding: Binding<ModelReasoningOption> {
        Binding(
            get: {
                viewModel.reasoningSelection
                    ?? viewModel.reasoningConfiguration?.defaultOption
                    ?? .medium
            },
            set: { viewModel.setReasoningSelection($0) }
        )
    }

    /// Binding for models exposing only on/off reasoning.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.reasoningSelection != .off },
            set: { enabled in
                viewModel.setReasoningSelection(enabled ? enabledOption : .off)
            }
        )
    }

    /// LM Studio's explicit enabled option or its reported default.
    private var enabledOption: ModelReasoningOption {
        let configuration = viewModel.reasoningConfiguration
        if configuration?.allowedOptions.contains(.on) == true {
            return .on
        }
        return configuration?.defaultOption ?? .on
    }

    /// On-only models remain visible but cannot send an unsupported off value.
    private var canToggle: Bool {
        guard let options = viewModel.reasoningConfiguration?.allowedOptions else {
            return false
        }
        return options.contains(.off) && options.contains(enabledOption)
    }
}
