//
//  EnsembleViewModel+Export.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — export + history. Render the finished episode as a {Name}-tagged Multi-Talk script, then either open it in the Multi-Talk tab (reuses that tab's render/export — no new audio code) or save it to History. Export tags are disambiguated per speaker so duplicate/blank names don't collapse into one voice, and an episode that's empty after stage-direction stripping can't be saved.
//
//  WP-CAST-1 also lives here: portable cast JSON export/import (NSSavePanel / NSOpenPanel), since the file-panel plumbing matches transcript save.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension EnsembleViewModel {

    /// True when at least one turn survives stage-direction stripping — i.e. the rendered Multi-Talk transcript won't be empty.
    var canExport: Bool {
        let strip = appState.chatSettings.activeBackend == .pocketTTS
        return turns.contains {
            !TextNormalizer.stripEmojis(
                TextNormalizer.stripStageDirections($0.content, stripBracketedTags: strip)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `{Tag} line` per turn, stage directions + emoji stripped per the active backend.
    func formatTranscriptMultiTalk(userVoiceMap: [String: String] = [:]) -> String {
        Self.formatMultiTalkScript(
            turns: turns,
            label: exportLabels(userVoiceMap: userVoiceMap).label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
    }

    /// Pure renderer (static for testing). `label` maps each turn to its unique Multi-Talk tag (cast by UUID, user by the name stored on the turn so multi-character aliases stay distinct). Emoji are stripped — Multi-Talk revoice uses the same TTS path that chokes on them.
    static func formatMultiTalkScript(
        turns: [EnsembleTurn],
        label: (EnsembleTurn) -> String,
        stripBrackets: Bool
    ) -> String {
        var lines: [String] = []
        for turn in turns {
            // Scene beats (boot deaths, etc.) stay in the Ensemble transcript for the models; Multi-Talk only wants spoken cast/user lines.
            if turn.isSceneBeat { continue }
            let cleaned = TextNormalizer.stripEmojis(
                TextNormalizer.stripStageDirections(turn.content, stripBracketedTags: stripBrackets)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            lines.append("{\(label(turn))} \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    /// Display names the human spoke as in this episode (order of first appearance). Drives the Multi-Talk voice-map sheet.
    func distinctUserSpeakerNamesInTranscript() -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for turn in turns {
            guard turn.speakerID == nil, !turn.isSceneBeat else { continue }
            let display = Self.normalizedUserSpeakerDisplay(turn.speakerName)
            let key = display.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(display)
        }
        return names
    }

    /// Seed `multiTalkUserVoiceDraft` for every user character in the transcript. Returns `true` when the map sheet should open (there is at least one human line to assign a voice to).
    @discardableResult
    func prepareMultiTalkVoiceMap() -> Bool {
        let names = distinctUserSpeakerNamesInTranscript()
        guard !names.isEmpty else { return false }
        var excluding = Set(cast.map(\.voiceID) + departedSpeakers.map(\.voiceID))
        var draft: [String: String] = [:]
        for name in names {
            if let kept = multiTalkUserVoiceDraft.first(where: {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            })?.value, !kept.isEmpty {
                draft[name] = kept
                excluding.insert(kept)
            } else {
                let voice = defaultUserExportVoiceID(for: name, excluding: excluding)
                draft[name] = voice
                excluding.insert(voice)
            }
        }
        multiTalkUserVoiceDraft = draft
        return true
    }

    /// Unique export tag per DISTINCT speaker (live cast + **booted** archive + each human character name that appears on a user turn), disambiguating duplicate/blank names so two "Alex"s — or a user sharing a cast name — each map to their own Multi-Talk voice.
    ///
    /// `userVoiceMap` is keyed by the human's display name on the turn (e.g. "John", "Data"); missing keys fall back to name-matched saved voices, then unused stock. Boot removes speakers from the live cast for the run loop, but their past turns still carry their UUID — without the archive those IDs fell through to the user label (or Multi-Talk's default stock).
    func exportLabels(userVoiceMap: [String: String] = [:]) -> (
        label: (EnsembleTurn) -> String,
        speakers: [SpeakerRef]
    ) {
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

        // Live cast first (stable order), then booted speakers in boot order.
        var roster: [Persona] = []
        var seen = Set<UUID>()
        for p in cast where seen.insert(p.id).inserted {
            roster.append(p)
        }
        for p in departedSpeakers where seen.insert(p.id).inserted {
            roster.append(p)
        }

        var idToLabel: [UUID: String] = [:]
        var refs: [SpeakerRef] = []
        for persona in roster {
            let tag = unique(persona.name)
            idToLabel[persona.id] = tag
            refs.append(SpeakerRef(name: tag, voiceID: persona.voiceID))
        }

        // Orphan turn speakers (shouldn't happen if boot archives correctly — recover by name from the turn so we still never collapse to "You"/alba).
        for turn in turns {
            guard let id = turn.speakerID, !turn.isSceneBeat, idToLabel[id] == nil else { continue }
            let tag = unique(turn.speakerName)
            idToLabel[id] = tag
            refs.append(SpeakerRef(name: tag, voiceID: CastPackageBuilder.defaultVoiceID))
        }

        // One Multi-Talk speaker per human alias that actually spoke (not just the current userPeer name — multi-character lines keep their tags).
        var userKeyToLabel: [String: String] = [:]
        var excludingVoices = Set(refs.map(\.voiceID))
        for display in distinctUserSpeakerNamesInTranscript() {
            let tag = unique(display)
            userKeyToLabel[display.lowercased()] = tag
            let mapped = userVoiceMap.first(where: {
                $0.key.caseInsensitiveCompare(display) == .orderedSame
            })?.value
            let voice: String
            if let mapped, !mapped.isEmpty {
                voice = mapped
            } else {
                voice = defaultUserExportVoiceID(for: display, excluding: excludingVoices)
            }
            excludingVoices.insert(voice)
            refs.append(SpeakerRef(name: tag, voiceID: voice))
        }

        let label: (EnsembleTurn) -> String = { turn in
            if let id = turn.speakerID {
                if let tag = idToLabel[id] { return tag }
                return "Speaker"
            }
            let display = Self.normalizedUserSpeakerDisplay(turn.speakerName)
            return userKeyToLabel[display.lowercased()] ?? display
        }
        return (label, refs)
    }

    /// Default voice for a human character: name-matched saved voice if free, else first unused stock, else package default. Never share a cast member's voiceID (shared IDs collapse Multi-Talk card identity).
    func defaultUserExportVoiceID(for displayName: String, excluding: Set<String>) -> String {
        let requirePocketKV = appState.chatSettings.activeBackend == .pocketTTS
        if let match = VoiceManager.shared.voices.first(where: {
            (!requirePocketKV || $0.pocketTTSKVPath != nil)
                && $0.name.caseInsensitiveCompare(displayName) == .orderedSame
                && !excluding.contains("imported:\($0.id)")
        }) {
            return "imported:\(match.id)"
        }
        if let stock = BundledVoice.stockIDs.sorted().first(where: { !excluding.contains($0) }) {
            return stock
        }
        return CastPackageBuilder.defaultVoiceID
    }

    private static func normalizedUserSpeakerDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }

    /// Open this episode in the Multi-Talk tab (reuses its render/export path). Pass `userVoiceMap` from the map sheet so each human character lands on a real stock/custom voice instead of an unused-stock fallback (often alba).
    func openInMultiTalk(userVoiceMap: [String: String] = [:]) {
        let map = userVoiceMap.isEmpty ? multiTalkUserVoiceDraft : userVoiceMap
        let labels = exportLabels(userVoiceMap: map)
        let script = Self.formatMultiTalkScript(
            turns: turns, label: labels.label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
        guard !script.isEmpty else { return }
        // Keep character names as Multi-Talk card labels (John / Data / …), not generic "Speaker N" — the map sheet is the user-authored roster.
        appState.queueReuse(.multi(script: script, speakers: labels.speakers, normalizeSpeakers: false))
    }

    /// Save the episode so it appears in History (+ the Ensemble session store). Uses the session voice draft when present so a prior Multi-Talk map is honored; otherwise auto-defaults per character name.
    func saveEpisodeToHistory() {
        guard let ctx = appState.modelContext else { return }
        let labels = exportLabels(userVoiceMap: multiTalkUserVoiceDraft)
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

    /// Save the transcript as a Markdown file — real speaker names, FULL content (stage directions preserved, for the user's records), matching Solo's `ChatViewModel.saveTranscript`.
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

    /// `**Name**:` blocks separated by `---`, with an optional scene/mood header. Stage directions are kept for the record; emoji are stripped (same as Multi-Talk — they only add noise in a saved transcript and blow up re-synthesis if the file is reused). Names come from exportLabels so duplicates stay distinct.
    func formatTranscriptMarkdown() -> String {
        let label = exportLabels(userVoiceMap: multiTalkUserVoiceDraft).label
        var out = ""
        let header = [scene, mood].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !header.isEmpty {
            out += "_" + header.joined(separator: " · ") + "_\n\n---\n\n"
        }
        var blocks: [String] = []
        for turn in turns {
            let content = TextNormalizer.stripEmojis(turn.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if turn.isSceneBeat {
                blocks.append("**Scene**:\n\(content)")
                continue
            }
            blocks.append("**\(label(turn))**:\n\(content)")
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

    /// Replace the live cast from a decoded package. Throws if personas empty or `formatVersion` is newer than this app understands.
    func applyImportedPackage(_ package: CastPackage) throws {
        guard package.formatVersion <= CastPackage.currentFormatVersion else {
            showNotice("Cast file is from a newer app version (format \(package.formatVersion))")
            throw CastImportError.unsupportedFormatVersion(package.formatVersion)
        }
        guard !package.personas.isEmpty else {
            showNotice("Cast file has no speakers")
            throw CastImportError.emptyPersonas
        }
        stop()
        detachAfterFlushingCurrentThread()
        let available = availableVoiceIDs()
        var remapped = 0
        let sorted = package.personas.sorted { $0.sortOrder < $1.sortOrder }
        // Cap at maxCastSize — UI and conductors assume ≤ 8.
        let capped = Array(sorted.prefix(CastPackageBuilder.maxCastSize))
        let truncated = sorted.count - capped.count
        let resolved: [(payload: PersonaPayload, voiceID: String)] = capped.map { p in
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
        seedUserCharacterRosterFromActivePeer()
        if let raw = package.cast.turnModeRaw, let mode = TurnMode(rawValue: raw) {
            turnOrder = mode
        }
        if let raw = package.cast.rngModeRaw, let mode = RNGMode(rawValue: raw) {
            rngMode = mode
        }
        if let pace = package.cast.paceSeconds {
            paceSeconds = CastPackageBuilder.clampPaceSeconds(pace)
        }
        if let max = package.cast.maxTurns {
            maxTurns = CastPackageBuilder.clampMaxTurns(max)
        }
        if let window = package.cast.contextWindowTurns {
            verbatimWindow = CastPackageBuilder.clampVerbatimWindow(window)
        }
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
        pendingBoot = nil
        pendingDirective = nil
        lastDepartureNote = nil
        departedSpeakers = []
        didWarnContextNearFull = false

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
        refreshContextFillEstimate()

        var noticeParts: [String] = []
        if remapped > 0 {
            noticeParts.append("\(remapped) voice(s) remapped to Cosette")
        }
        if truncated > 0 {
            noticeParts.append("kept first \(CastPackageBuilder.maxCastSize) of \(sorted.count) speakers")
        }
        if noticeParts.isEmpty {
            let names = cast.map(\.name).joined(separator: ", ")
            showNotice(names.isEmpty ? "Cast imported." : "Cast imported — \(names)")
        } else {
            showNotice("Cast imported; " + noticeParts.joined(separator: "; ") + ".")
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
    case unsupportedFormatVersion(Int)
}
