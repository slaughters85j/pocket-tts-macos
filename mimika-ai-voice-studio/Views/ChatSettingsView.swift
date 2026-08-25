//
//  ChatSettingsView.swift
//  mimika-ai-voice-studio
//
//  Chat-scoped settings: the TTS voice used for spoken chat replies, and the chat system prompt sent on every conversation. App-wide settings (LLM endpoint config, Pocket-TTS tuning) live in AppSettingsView and are reachable from a gear icon in the global header — not from this sheet, which is only triggered by the Chat tab's own gear button because these fields don't apply outside the Chat context.

import SwiftData
import SwiftUI

struct ChatSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Binding var isPresented: Bool
    @Binding var settings: ChatSettings
    let voices: [BundledVoice]
    let onSave: (ChatSettings) -> Void

    @State private var workingCopy: ChatSettings
    @State private var showsPromptManager = false
    @State private var inferencePrompt: SystemPrompt?

    init(
        isPresented: Binding<Bool>,
        settings: Binding<ChatSettings>,
        voices: [BundledVoice],
        onSave: @escaping (ChatSettings) -> Void
    ) {
        self._isPresented = isPresented
        self._settings = settings
        self.voices = voices
        self.onSave = onSave
        self._workingCopy = State(initialValue: settings.wrappedValue)
    }

    var body: some View {
        ModalContainer(title: "Chat Settings", onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                voiceSection
                Divider().background(Theme.borderColor)
                systemPromptSection
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
        .sheet(isPresented: $showsPromptManager) {
            PromptManagerSheet(isPresented: $showsPromptManager, scope: .chat)
        }
        .sheet(item: $inferencePrompt) { prompt in
            ChatInferenceSettingsSheet(prompt: prompt) { inferenceSettings in
                AppDataStore.updateInferenceSettings(
                    modelContext,
                    prompt: prompt,
                    settings: inferenceSettings
                )
            }
        }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        let importedVoices = VoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }
        let builtInVoices = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: Theme.space3) {
            Text("TTS Voice for chat replies")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            Picker("", selection: $workingCopy.ttsVoiceID) {
                VoicePickerFallback.unavailableTag(
                    selection: workingCopy.ttsVoiceID,
                    isKnown: builtInVoices.contains { $0.id == workingCopy.ttsVoiceID }
                        || importedVoices.contains { "imported:\($0.id)" == workingCopy.ttsVoiceID }
                )
                Section("Built-in") {
                    ForEach(builtInVoices, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                if !importedVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(importedVoices) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name).tag("imported:\(v.id)")
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeInputField()

            // Seed affordance for the chat voice. Self-hides for stock voices.
            if workingCopy.ttsVoiceID.hasPrefix("imported:") {
                HStack(spacing: Theme.space2) {
                    Text("Seed")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                    SeedControl(voiceID: workingCopy.ttsVoiceID, style: .card)
                    Spacer()
                }
            }
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("System Prompt")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Sent as the first system message in every conversation. Pick from saved prompts or open the editor to rename / add / duplicate.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ActivePromptPicker(
                scope: .chat,
                showsManager: $showsPromptManager,
                onEditInferenceSettings: { inferencePrompt = $0 }
            )
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(action: cancel) {
                Text("Cancel")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
            }
            .buttonStyle(.plain)

            Button(action: saveAndClose) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chatSettings.doneButton")
        }
    }

    // MARK: - Actions

    private func cancel() {
        isPresented = false
    }

    private func saveAndClose() {
        settings = workingCopy
        onSave(workingCopy)
        isPresented = false
    }
}

// MARK: - Inference settings sheet

/// Edits a working copy and persists it only when the user chooses Done.
private struct ChatInferenceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let prompt: SystemPrompt
    let onSave: (ChatInferenceSettings) -> Void

    @State private var workingCopy: ChatInferenceSettings

    init(
        prompt: SystemPrompt,
        onSave: @escaping (ChatInferenceSettings) -> Void
    ) {
        self.prompt = prompt
        self.onSave = onSave
        self._workingCopy = State(initialValue: prompt.inferenceSettings)
    }

    var body: some View {
        ModalContainer(title: "Inference Settings", onClose: dismiss.callAsFunction) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                parameterSlider(
                    label: "Temperature",
                    value: $workingCopy.temperature,
                    range: 0.1...1.5,
                    step: 0.05,
                    description: "Lower = consistent, predictable. Higher = expressive, varied. Default 0.7."
                )

                parameterSlider(
                    label: "Top P",
                    value: $workingCopy.topP,
                    range: 0.1...1.0,
                    step: 0.05,
                    description: "Nucleus sampling threshold. Lower = more focused. Higher = broader vocab. Default 0.7."
                )

                integerSlider(
                    label: "Top K",
                    value: $workingCopy.topK,
                    range: 1...100,
                    description: "Token candidates per step. Lower = deterministic. Higher = creative. Default 30."
                )

                parameterSlider(
                    label: "Repeat Penalty",
                    value: $workingCopy.repeatPenalty,
                    range: 0.0...2.0,
                    step: 0.05,
                    description: "Discourages repeated tokens. Higher = less repetition. Default 1.1."
                )

                HStack(alignment: .top, spacing: Theme.space4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max Tokens")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                        Text("Maximum reply length. Leave empty for no limit.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    TextField(
                        "No limit",
                        value: maxTokensBinding,
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .accessibilityIdentifier("chatInferenceSettings.maxTokens")
                }

                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
        .accessibilityIdentifier("chatInferenceSettings.sheet")
    }

    /// Empty means omit `max_tokens`; non-positive entries return to empty.
    private var maxTokensBinding: Binding<Int?> {
        Binding(
            get: { workingCopy.maxTokens },
            set: { value in
                workingCopy.maxTokens = value.flatMap { $0 > 0 ? $0 : nil }
            }
        )
    }

    /// Floating-point inference parameter with a live monospaced value.
    private func parameterSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.accent)
            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Integer inference parameter bridged to SwiftUI's floating slider.
    private func integerSlider(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        description: String
    ) -> some View {
        let sliderValue = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) }
        )

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(
                value: sliderValue,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(Theme.accent)
            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss.callAsFunction)
                .buttonStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)

            Button("Done") {
                onSave(workingCopy)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .accessibilityIdentifier("chatInferenceSettings.doneButton")
        }
    }
}
