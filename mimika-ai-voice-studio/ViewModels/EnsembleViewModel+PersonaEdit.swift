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

    // MARK: - User peer name (Cast & Settings)

    /// Cap on quick-pick character aliases kept in the composer roster.
    static let maxUserCharacterRoster = 16

    /// Set how the cast addresses the human. Empty → display "You" / model
    /// "Guest" (same convention as the New Cast wizard). Mirrors display into
    /// `modelName` when the user picks a real proper noun so the LLM never
    /// sees the pronoun "You" as a speaker label. Also keeps the composer
    /// character picker in sync.
    func updateUserPeerName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userPeer.name = "You"
            userPeer.modelName = "Guest"
            // Include-me requires a real character name.
            includeUserInTurnOrder = false
        } else {
            userPeer.name = trimmed
            userPeer.modelName = trimmed
            rememberUserCharacter(trimmed)
        }
        guard let ctx = appState.modelContext, let saved = currentSavedCast(ctx) else { return }
        saved.userPeerName = userPeer.name
        EnsembleStore.update(ctx, cast: saved)
    }

    // MARK: - Multi-character quick pick (composer)

    /// Switch the active human identity to a name already on the roster
    /// (or any string). Overrides Cast & Settings and persists to the cast.
    func selectUserCharacter(_ name: String) {
        updateUserPeerName(name)
    }

    /// Add a new character name, make it active, and remember it on the
    /// picker. Empty / whitespace-only fails. Case-insensitive duplicates
    /// just select the existing entry.
    @discardableResult
    func addUserCharacter(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let existing = userCharacterRoster.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            selectUserCharacter(existing)
            return true
        }
        rememberUserCharacter(trimmed)
        selectUserCharacter(trimmed)
        return true
    }

    /// Seed the picker from the active peer (cast load / new cast). Real
    /// proper nouns only — skips the default "You" pronoun.
    func seedUserCharacterRosterFromActivePeer() {
        let n = userPeer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != "You" else { return }
        rememberUserCharacter(n)
    }

    /// Insert `name` at the front of the roster if missing; drop oldest when
    /// over the cap. Does not change the active peer.
    private func rememberUserCharacter(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "You" else { return }
        if let idx = userCharacterRoster.firstIndex(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            // Promote to front so recent picks stay visible first.
            let kept = userCharacterRoster.remove(at: idx)
            userCharacterRoster.insert(kept, at: 0)
            return
        }
        userCharacterRoster.insert(trimmed, at: 0)
        if userCharacterRoster.count > Self.maxUserCharacterRoster {
            userCharacterRoster = Array(userCharacterRoster.prefix(Self.maxUserCharacterRoster))
        }
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
        let removed = cast[index]
        let removedID = removed.id
        cast.remove(at: index)
        // Drop a removed speaker from the RR shuffle so cursor stays valid.
        shuffledOrder = []
        orderCursor = 0
        if pendingBoot?.speakerID == removedID { pendingBoot = nil }
        if pendingDirective?.speakerID == removedID { pendingDirective = nil }
        guard let ctx = appState.modelContext, let saved = currentSavedCast(ctx) else { return true }
        let personas = saved.sortedPersonas
        // Prefer identity-ish match (name + voice) so a reordered store row
        // can't delete the wrong persona; fall back to full resync.
        if let storePersona = personas.first(where: {
            $0.name == removed.name && $0.voiceID == removed.voiceID
        }) {
            EnsembleStore.removePersona(ctx, storePersona, from: saved)
        } else {
            resyncSavedPersonas(ctx, saved: saved)
        }
        return true
    }

    /// Remove by persona id (Boot + roster).
    @discardableResult
    func removeCastMember(id: UUID) -> Bool {
        guard let index = cast.firstIndex(where: { $0.id == id }) else { return false }
        return removeCastMember(at: index)
    }

    // MARK: - Boot (Director's Chair)

    /// Arm a one-shot exit for `speakerID`: they speak next with the reason,
    /// then leave the cast. Remaining speakers get a public departure note.
    /// Cuts any in-flight line immediately so the exit does not wait.
    @discardableResult
    func bootCastMember(id: UUID, reason: String) -> Bool {
        guard cast.count > CastPackageBuilder.minCastSize else {
            showNotice("Keep at least one speaker in the cast")
            return false
        }
        guard cast.contains(where: { $0.id == id }) else { return false }
        let name = cast.first(where: { $0.id == id })?.name ?? "Speaker"
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBoot = PendingBoot(speakerID: id, reason: trimmed)
        showNotice(trimmed.isEmpty
                   ? "Boot armed — \(name) exits now"
                   : "Boot armed — \(name): \(trimmed)")
        forceImmediateDirectorAction()
        return true
    }

    // MARK: - Direct (Director's Chair)

    /// Arm a one-shot cast-specific direction: that speaker is forced next with
    /// the instruction injected and Strict sampling so compliance is likelier.
    /// Unlike Boot they stay in the cast. Instruction must be non-empty.
    /// Cuts any in-flight line immediately so the note lands on the next pick.
    @discardableResult
    func issueDirective(id: UUID, instruction: String) -> Bool {
        guard cast.contains(where: { $0.id == id }) else { return false }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showNotice("Write a direction first")
            return false
        }
        let name = cast.first(where: { $0.id == id })?.name ?? "Speaker"
        pendingDirective = PendingDirective(speakerID: id, instruction: trimmed)
        showNotice("Direction armed — \(name)")
        forceImmediateDirectorAction()
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
