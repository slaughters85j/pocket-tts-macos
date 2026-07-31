//
//  EnsembleViewModel+Export.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — export + history. Render the finished episode as a {Name}-tagged
//  Multi-Talk script, then either open it in the Multi-Talk tab (reuses that
//  tab's render/export — no new audio code) or save it to History. Export tags
//  are disambiguated per speaker so duplicate/blank names don't collapse into
//  one voice, and an episode that's empty after stage-direction stripping can't
//  be saved.
//
//  WP-CAST-1 also lives here: portable cast JSON export/import (NSSavePanel /
//  NSOpenPanel), since the file-panel plumbing matches transcript save.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension EnsembleViewModel {

    /// True when at least one turn survives stage-direction stripping — i.e. the
    /// rendered Multi-Talk transcript won't be empty.
    var canExport: Bool {
        let strip = appState.chatSettings.activeBackend == .pocketTTS
        return turns.contains {
            !TextNormalizer.stripStageDirections($0.content, stripBracketedTags: strip)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `{Tag} line` per turn, stage directions stripped per the active backend.
    func formatTranscriptMultiTalk() -> String {
        Self.formatMultiTalkScript(
            turns: turns,
            label: exportLabels().label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
    }

    /// Pure renderer (static for testing). `label` maps each turn's speakerID to
    /// its unique tag.
    static func formatMultiTalkScript(turns: [EnsembleTurn], label: (UUID?) -> String, stripBrackets: Bool) -> String {
        var lines: [String] = []
        for turn in turns {
            let cleaned = TextNormalizer.stripStageDirections(turn.content, stripBracketedTags: stripBrackets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            lines.append("{\(label(turn.speakerID))} \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    /// Unique export tag per DISTINCT speaker (each cast member + the user),
    /// disambiguating duplicate/blank names so two "Alex"s — or a user sharing a
    /// cast name — each map to their own Multi-Talk voice. Returns the
    /// speakerID→tag mapper plus the matching speaker list (same order/tags).
    func exportLabels() -> (label: (UUID?) -> String, speakers: [SpeakerRef]) {
        var used = Set<String>()
        func unique(_ base: String) -> String {
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            let root = trimmed.isEmpty ? "Speaker" : trimmed
            var name = root
            var n = 1
            while used.contains(name) { n += 1; name = "\(root) \(n)" }
            used.insert(name)
            return name
        }
        var idToLabel: [UUID: String] = [:]
        var refs: [SpeakerRef] = []
        for persona in cast {
            let tag = unique(persona.name)
            idToLabel[persona.id] = tag
            refs.append(SpeakerRef(name: tag, voiceID: persona.voiceID))
        }
        var userLabel = "You"
        if turns.contains(where: { $0.speakerID == nil }) {
            userLabel = unique(userPeer.name)
            // The user needs their OWN voice in the re-voiced export, not a cast
            // member's. Sharing a voiceID makes the user's voice NAME equal that
            // cast member's speaker label, which corrupts Multi-Talk's tag rewrite
            // (changing one relabels the other).
            //
            // Prefer a saved voice named after the user's peer (a "Fox
            // Mulder" voice for the Fox Mulder peer) — an arbitrary stock
            // fallback makes the user's lines sound like a stranger.
            // Pocket capability is only required when Pocket is the active
            // backend: Multi-Talk's applyReuse remap degrades cross-backend
            // IDs safely, so a Fish-only clone is a valid match under Fish.
            // Fall back to the first stock voice the cast isn't using.
            let castVoiceIDs = Set(cast.map(\.voiceID))
            let requirePocketKV = appState.chatSettings.activeBackend == .pocketTTS
            let userVoice = VoiceManager.shared.voices
                .first {
                    (!requirePocketKV || $0.pocketTTSKVPath != nil)
                        && $0.name.caseInsensitiveCompare(userPeer.name) == .orderedSame
                        && !castVoiceIDs.contains("imported:\($0.id)")
                }
                .map { "imported:\($0.id)" }
                ?? BundledVoice.stockIDs.sorted().first { !castVoiceIDs.contains($0) }
                ?? cast.first?.voiceID ?? "cosette"
            refs.append(SpeakerRef(name: userLabel, voiceID: userVoice))
        }
        let label: (UUID?) -> String = { id in
            if let id, let tag = idToLabel[id] { return tag }
            return userLabel
        }
        return (label, refs)
    }

    /// Open this episode in the Multi-Talk tab (reuses its render/export path).
    func openInMultiTalk() {
        let labels = exportLabels()
        let script = Self.formatMultiTalkScript(
            turns: turns, label: labels.label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
        guard !script.isEmpty else { return }
        appState.queueReuse(.multi(script: script, speakers: labels.speakers, normalizeSpeakers: true))
    }

    /// Save the episode so it appears in History (+ the Ensemble session store).
    func saveEpisodeToHistory() {
        guard let ctx = appState.modelContext else { return }
        let labels = exportLabels()
        let script = Self.formatMultiTalkScript(
            turns: turns, label: labels.label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
        guard !script.isEmpty else { return }
        HistoryStore.appendMulti(script: script, speakers: labels.speakers, context: ctx)
        EnsembleStore.appendSession(ctx, scene: scene, mood: mood,
                                    transcriptMultiTalk: script, speakers: labels.speakers)
        showNotice("Saved to History")
    }

    // MARK: - Markdown transcript (parity with Solo's "Save transcript")

    /// Save the transcript as a Markdown file — real speaker names, FULL content
    /// (stage directions preserved, for the user's records), matching Solo's
    /// `ChatViewModel.saveTranscript`.
    func saveTranscript() {
        let panel = NSSavePanel()
        panel.title = "Save Ensemble Transcript"
        panel.nameFieldStringValue = "ensemble-transcript.md"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try formatTranscriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showNotice("Couldn't save transcript")
        }
    }

    /// `**Name**:` blocks separated by `---`, with an optional scene/mood header.
    /// Unlike the Multi-Talk export this does NOT strip stage directions — a
    /// saved transcript preserves the full output. Names come from exportLabels
    /// so duplicates stay distinct.
    func formatTranscriptMarkdown() -> String {
        let label = exportLabels().label
        var out = ""
        let header = [scene, mood].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !header.isEmpty {
            out += "_" + header.joined(separator: " · ") + "_\n\n---\n\n"
        }
        var blocks: [String] = []
        for turn in turns {
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            blocks.append("**\(label(turn.speakerID))**:\n\(content)")
        }
        return out + blocks.joined(separator: "\n\n---\n\n") + "\n"
    }

    // MARK: - Cast package export / import (WP-CAST-1)

    /// Snapshot the live cast + run knobs to a portable JSON file.
    func exportCastToFile() {
        guard !cast.isEmpty else {
            showNotice("Nothing to export — load or generate a cast first.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Cast"
        panel.nameFieldStringValue = suggestedCastFilename()
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let package = buildCastPackage()
            let data = try CastPackageBuilder.jsonEncoder().encode(package)
            try data.write(to: url, options: .atomic)
            showNotice("Cast exported")
        } catch {
            showNotice("Couldn't export cast")
        }
    }

    /// Open a cast JSON file and replace the live cast (new SwiftData row).
    func importCastFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Cast"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let package = try CastPackageBuilder.jsonDecoder().decode(CastPackage.self, from: data)
            try applyImportedPackage(package)
        } catch {
            showNotice("Couldn't read cast file")
        }
    }

    /// Build a `CastPackage` from the live VM (+ optional SwiftData role/reads).
    func buildCastPackage() -> CastPackage {
        var rolesAndReads: [(role: String, suggestedVoice: String, reads: [String: String])] = []
        if let ctx = appState.modelContext, let saved = currentSavedCast(ctx) {
            rolesAndReads = saved.sortedPersonas.map {
                (role: $0.role, suggestedVoice: $0.suggestedVoice, reads: $0.readsOnOthers)
            }
        }
        return CastPackageBuilder.make(
            castID: currentCastID,
            castName: scene.isEmpty ? "Ensemble" : scene,
            scene: scene,
            mood: mood,
            userPeerName: userPeer.name,
            personas: cast,
            rolesAndReads: rolesAndReads,
            turnMode: turnOrder,
            rngMode: rngMode,
            paceSeconds: paceSeconds,
            maxTurns: maxTurns,
            contextWindowTurns: verbatimWindow,
            rollingSummaryEnabled: rollingSummaryEnabled,
            voicedPlayback: voicedPlayback,
            scenePlayMode: scenePlayMode
        )
    }

    /// Replace the live cast from a decoded package. Throws if personas empty.
    func applyImportedPackage(_ package: CastPackage) throws {
        guard !package.personas.isEmpty else {
            showNotice("Cast file has no speakers")
            throw CastImportError.emptyPersonas
        }
        stop()
        let available = availableVoiceIDs()
        var remapped = 0
        let sorted = package.personas.sorted { $0.sortOrder < $1.sortOrder }
        let resolved: [(payload: PersonaPayload, voiceID: String)] = sorted.map { p in
            let v = CastPackageBuilder.resolveVoiceID(p.voiceID, available: available)
            if v != p.voiceID { remapped += 1 }
            return (p, v)
        }

        scene = package.cast.scene
        mood = package.cast.mood
        let peer = package.cast.userPeerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !peer.isEmpty, peer != "You" {
            userPeer.name = peer
            userPeer.modelName = peer
        }
        if let raw = package.cast.turnModeRaw, let mode = TurnMode(rawValue: raw) {
            turnOrder = mode
        }
        if let raw = package.cast.rngModeRaw {
            rngMode = (raw == "rerollPerTurn") ? .rerollPerTurn : .shuffleOnce
        }
        if let pace = package.cast.paceSeconds { paceSeconds = pace }
        if let max = package.cast.maxTurns { maxTurns = max }
        if let window = package.cast.contextWindowTurns { verbatimWindow = window }
        if let rolling = package.cast.rollingSummaryEnabled { rollingSummaryEnabled = rolling }
        if let voiced = package.cast.voicedPlayback { voicedPlayback = voiced }
        if let raw = package.cast.scenePlayModeRaw,
           let mode = ScenePlayMode(rawValue: raw) {
            scenePlayMode = mode
        }

        turns = []
        rollingSummary = ""
        summarizedUpTo = 0
        summaryTask?.cancel(); summaryTask = nil
        shuffledOrder = []
        orderCursor = 0
        producedThisRun = 0

        cast = resolved.map { entry in
            let preset = SamplingPreset(rawValue: entry.payload.samplingPresetRaw) ?? .relaxed
            return Persona(
                name: entry.payload.name,
                voiceID: entry.voiceID,
                systemPrompt: entry.payload.personaPrompt,
                temperature: entry.payload.temperature,
                samplingPreset: preset
            )
        }

        persistImportedCast(package: package, resolved: resolved)

        if remapped > 0 {
            showNotice("Imported cast; \(remapped) voice(s) remapped to Cosette (missing custom voices).")
        } else {
            let names = cast.map(\.name).joined(separator: ", ")
            showNotice(names.isEmpty ? "Cast imported." : "Cast imported — \(names)")
        }
    }

    private func persistImportedCast(
        package: CastPackage,
        resolved: [(payload: PersonaPayload, voiceID: String)]
    ) {
        guard let ctx = appState.modelContext else { return }
        let name = package.cast.name.isEmpty
            ? (package.cast.scene.isEmpty ? "Ensemble" : package.cast.scene)
            : package.cast.name
        let castModel = EnsembleStore.create(ctx, name: name, scene: package.cast.scene, mood: package.cast.mood)
        castModel.userPeerName = userPeer.name
        if let raw = package.cast.turnModeRaw { castModel.turnModeRaw = raw }
        if let pace = package.cast.paceSeconds { castModel.paceSeconds = pace }
        if let window = package.cast.contextWindowTurns { castModel.contextWindowTurns = window }
        if let rolling = package.cast.rollingSummaryEnabled { castModel.rollingSummaryEnabled = rolling }
        currentCastID = castModel.id
        for (i, entry) in resolved.enumerated() {
            let p = entry.payload
            let preset = SamplingPreset(rawValue: p.samplingPresetRaw) ?? .relaxed
            EnsembleStore.addPersona(
                ctx, to: castModel,
                name: p.name,
                role: p.role,
                voiceID: entry.voiceID,
                suggestedVoice: p.suggestedVoice,
                personaPrompt: p.personaPrompt,
                temperature: p.temperature,
                samplingPreset: preset,
                readsOnOthers: p.readsOnOthers,
                sortOrder: i
            )
        }
    }

    private func availableVoiceIDs() -> Set<String> {
        var ids = BundledVoice.stockIDs
        for v in VoiceManager.shared.voices where v.pocketTTSKVPath != nil {
            ids.insert("imported:\(v.id)")
        }
        // Always allow the fallback stock id even if stock assets aren't loaded yet.
        ids.insert(CastPackageBuilder.defaultVoiceID)
        return ids
    }

    private func suggestedCastFilename() -> String {
        let base = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = base.isEmpty ? "ensemble-cast" : base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(slug).json"
    }
}

/// Errors from cast JSON import (surfaced as notices; type is for tests).
enum CastImportError: Error {
    case emptyPersonas
}
