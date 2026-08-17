//
//  EnsembleMultiTalkVoiceMapSheet.swift
//  mimika-ai-voice-studio
//
//  Pre-flight for Open in Multi-Talk: assign each human character name that
//  spoke in the episode to a stock or custom voice so Multi-Talk cards don't
//  collapse onto an unused-stock fallback (often Alba).
//

import SwiftUI

// MARK: - EnsembleMultiTalkVoiceMapSheet

/// Modal: map the user's Ensemble character aliases → Multi-Talk voices.
struct EnsembleMultiTalkVoiceMapSheet: View {
    @Bindable var viewModel: EnsembleViewModel
    let voices: [BundledVoice]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var characterNames: [String] {
        // Prefer draft keys (seeded by prepareMultiTalkVoiceMap) so order matches
        // the transcript; fall back to a live re-scan.
        let draftKeys = viewModel.multiTalkUserVoiceDraft.keys
        if !draftKeys.isEmpty {
            let order = viewModel.distinctUserSpeakerNamesInTranscript()
            return order.filter { name in
                draftKeys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            }
        }
        return viewModel.distinctUserSpeakerNamesInTranscript()
    }

    var body: some View {
        ModalContainer(title: "Map voices for Multi-Talk", onClose: onCancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                Text("Pick a voice for each character you spoke as. Cast members keep the voices from Cast & Settings.")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if characterNames.isEmpty {
                    Text("No human lines in this episode.")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        VStack(spacing: Theme.space3) {
                            ForEach(characterNames, id: \.self) { name in
                                characterRow(name)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space3)
                        .accessibilityIdentifier("ensemble.voiceMap.cancel")

                    Button(action: onConfirm) {
                        Text("Open in Multi-Talk")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4)
                            .padding(.vertical, Theme.space2)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .disabled(characterNames.isEmpty)
                    .accessibilityIdentifier("ensemble.voiceMap.confirm")
                }
            }
            .padding(Theme.space6)
        }
        // Wide enough that a full character name ("Lt. Commander Cock-gobbler")
        // sits beside a 220pt voice picker without truncating.
        .frame(minWidth: 560, minHeight: 280)
        .accessibilityIdentifier("ensemble.voiceMap.sheet")
    }

    // MARK: - Row

    private func characterRow(_ name: String) -> some View {
        HStack(spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                // Wrap rather than truncate — these are user-chosen character
                // names and can be arbitrarily long.
                Text(name)
                    .font(Theme.fontSM)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(name)
                Text("Your character")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            voicePicker(for: name)
                .frame(width: 220)
        }
        .padding(Theme.space3)
        .background(Theme.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityIdentifier("ensemble.voiceMap.row.\(name)")
    }

    @ViewBuilder
    private func voicePicker(for name: String) -> some View {
        let backend = viewModel.appState.chatSettings.activeBackend
        let selection = Binding<String>(
            get: {
                viewModel.multiTalkUserVoiceDraft[name]
                    ?? viewModel.multiTalkUserVoiceDraft.first(where: {
                        $0.key.caseInsensitiveCompare(name) == .orderedSame
                    })?.value
                    ?? CastPackageBuilder.defaultVoiceID
            },
            set: { newValue in
                // Keep the key stable to the display name from the transcript.
                viewModel.multiTalkUserVoiceDraft[name] = newValue
                // Drop any stale case-variant key.
                for key in viewModel.multiTalkUserVoiceDraft.keys
                where key != name && key.caseInsensitiveCompare(name) == .orderedSame {
                    viewModel.multiTalkUserVoiceDraft.removeValue(forKey: key)
                }
            }
        )

        if backend == .pocketTTS {
            let imported = VoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }
            let builtIn = voices
                .filter { $0.type == .predefined }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Picker("", selection: selection) {
                VoicePickerFallback.unavailableTag(
                    selection: selection.wrappedValue,
                    isKnown: builtIn.contains { $0.id == selection.wrappedValue }
                        || imported.contains { "imported:\($0.id)" == selection.wrappedValue }
                )
                Section("Built-in") {
                    ForEach(builtIn, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                if !imported.isEmpty {
                    Section("My Voices") {
                        ForEach(imported) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name)
                                .tag("imported:\(v.id)")
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .themeInputField()
            .accessibilityIdentifier("ensemble.voiceMap.picker.\(name)")
        } else {
            let fishVoices = VoiceManager.shared.voices
            Picker("", selection: selection) {
                VoicePickerFallback.unavailableTag(
                    selection: selection.wrappedValue,
                    isKnown: selection.wrappedValue == "fish-default"
                        || fishVoices.contains { $0.id == selection.wrappedValue }
                )
                Text("Default Voice").tag("fish-default")
                if !fishVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(fishVoices) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name).tag(v.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .themeInputField()
            .accessibilityIdentifier("ensemble.voiceMap.picker.\(name)")
        }
    }
}
