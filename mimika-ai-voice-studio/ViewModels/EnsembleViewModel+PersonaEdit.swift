//
//  EnsembleViewModel+PersonaEdit.swift
//  mimika-ai-voice-studio
//
//  Post-acceptance persona editing (Cast & Settings' pencil): the persona
//  editor works on local copies and lands them here on close — name and
//  script mutate the LIVE cast, then one commit persists to the saved
//  cast. Sibling file to EnsembleViewModel.swift per the file-size
//  guideline, matching the existing +Context/+Director/+Export pattern.
//
//  WP-CAST-1 also lives here: manual add/remove of cast members after the
//  persona writer finishes (roster was previously fixed at accept time).
//

import Foundation
import SwiftData

extension EnsembleViewModel {

    // MARK: - Persona identity edits (pre-conversation)

    /// Set a persona's display name on the LIVE cast without persisting —
    /// the save is deferred to `commitPersonaEdit` on editor close. Only
    /// sensible before the conversation starts (the UI gates it): past
    /// turns keep whatever name they were spoken under.
    func setPersonaName(at index: Int, name: String) {
        guard cast.indices.contains(index) else { return }
        cast[index].name = name
    }

    /// Set a persona's system-prompt script on the LIVE cast without
    /// persisting — same deferred-save contract as `setPersonaName`.
    /// (Runtime `Persona` names the field `systemPrompt`; the persisted
    /// `EnsemblePersona` calls it `personaPrompt`.)
    func setPersonaPrompt(at index: Int, prompt: String) {
        guard cast.indices.contains(index) else { return }
        cast[index].systemPrompt = prompt
    }

    /// Persist any pending `setPersonaName` / `setPersonaPrompt` edits to
    /// the saved cast. Called once, when the persona editor closes.
    func commitPersonaEdit(at index: Int) {
        guard cast.indices.contains(index) else { return }
        persistPersonaEdit(at: index)
    }

    // MARK: - Scene & mood (Cast & Settings)

    /// Update the live scene string and persist to the saved cast (export uses
    /// the same fields; next turns pick them up via `framedSystemPrompt`).
    func updateScene(_ scene: String) {
        self.scene = scene
        persistSceneAndMood()
    }

    /// Update the live mood string and persist to the saved cast.
    func updateMood(_ mood: String) {
        self.mood = mood
        persistSceneAndMood()
    }

    private func persistSceneAndMood() {
        guard let ctx = appState.modelContext, let saved = currentSavedCast(ctx) else { return }
        saved.scene = scene
        saved.mood = mood
        // Cast display name tracks scene when we have one (same convention as
        // `persistCast` / import).
        let trimmed = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.name = trimmed.isEmpty ? "Ensemble" : trimmed
        EnsembleStore.update(ctx, cast: saved)
    }

    // MARK: - Roster add / remove (WP-CAST-1)

    /// Append a blank Cosette / Strict speaker and persist to the saved cast.
    @discardableResult
    func addCastMember() -> Bool {
        guard cast.count < CastPackageBuilder.maxCastSize else { return false }
        let persona = Persona(
            name: CastPackageBuilder.defaultNewMemberName,
            voiceID: CastPackageBuilder.defaultVoiceID,
            systemPrompt: "",
            temperature: SamplingPreset.strict.temperature,
            samplingPreset: .strict
        )
        cast.append(persona)
        // If nothing is saved yet, create a shell cast so the new member sticks.
        guard let ctx = appState.modelContext else { return true }
        if let saved = currentSavedCast(ctx) {
            EnsembleStore.addPersona(
                ctx, to: saved,
                name: persona.name,
                voiceID: persona.voiceID,
                personaPrompt: persona.systemPrompt,
                temperature: persona.temperature,
                samplingPreset: persona.samplingPreset,
                sortOrder: cast.count - 1
            )
        } else {
            let name = scene.isEmpty ? "Ensemble" : scene
            let castModel = EnsembleStore.create(ctx, name: name, scene: scene, mood: mood)
            castModel.userPeerName = userPeer.name
            currentCastID = castModel.id
            for (i, p) in cast.enumerated() {
                EnsembleStore.addPersona(
                    ctx, to: castModel,
                    name: p.name,
                    voiceID: p.voiceID,
                    personaPrompt: p.systemPrompt,
                    temperature: p.temperature,
                    samplingPreset: p.samplingPreset,
                    sortOrder: i
                )
            }
        }
        return true
    }

    /// Remove a speaker by index from the live cast + saved cast. Refuses
    /// when it would leave fewer than `minCastSize` members.
    @discardableResult
    func removeCastMember(at index: Int) -> Bool {
        guard cast.indices.contains(index) else { return false }
        guard cast.count > CastPackageBuilder.minCastSize else { return false }
        cast.remove(at: index)
        // Drop a removed speaker from the RR shuffle so cursor stays valid.
        shuffledOrder = []
        orderCursor = 0
        guard let ctx = appState.modelContext, let saved = currentSavedCast(ctx) else { return true }
        let personas = saved.sortedPersonas
        guard personas.indices.contains(index) else {
            // Length mismatch — re-sync store from runtime.
            resyncSavedPersonas(ctx, saved: saved)
            return true
        }
        EnsembleStore.removePersona(ctx, personas[index], from: saved)
        return true
    }

    /// Whether the cast can grow (under max size).
    var canAddCastMember: Bool {
        cast.count < CastPackageBuilder.maxCastSize
    }

    /// Whether a given row can be removed (above min size).
    var canRemoveCastMember: Bool {
        cast.count > CastPackageBuilder.minCastSize
    }

    /// Rewrite saved personas from the live cast when index matching broke.
    private func resyncSavedPersonas(_ ctx: ModelContext, saved: EnsembleCast) {
        for p in saved.sortedPersonas {
            EnsembleStore.removePersona(ctx, p, from: saved)
        }
        for (i, p) in cast.enumerated() {
            EnsembleStore.addPersona(
                ctx, to: saved,
                name: p.name,
                voiceID: p.voiceID,
                personaPrompt: p.systemPrompt,
                temperature: p.temperature,
                samplingPreset: p.samplingPreset,
                sortOrder: i
            )
        }
    }
}
