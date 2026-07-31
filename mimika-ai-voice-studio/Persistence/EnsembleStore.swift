//
//  EnsembleStore.swift
//  mimika-ai-voice-studio
//
//  Thin CRUD layer for Ensemble Mode's SwiftData models, mirroring
//  AppDataStore / HistoryStore: all static + @MainActor (ModelContext isn't
//  Sendable, callers are on the main actor). Casts + personas are the saved
//  configuration; sessions are finished episodes (the appendSession path is a
//  near-clone of HistoryStore.appendMulti, including a cap on unpinned rows).

import Foundation
import SwiftData

@MainActor
enum EnsembleStore {

    static let maxUnpinnedSessions = 30

    // MARK: - Casts

    /// All saved casts, most-recently-updated first.
    static func casts(_ ctx: ModelContext) -> [EnsembleCast] {
        let descriptor = FetchDescriptor<EnsembleCast>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? ctx.fetch(descriptor)) ?? []
    }

    @discardableResult
    static func create(_ ctx: ModelContext, name: String, scene: String = "", mood: String = "") -> EnsembleCast {
        let cast = EnsembleCast(name: name, scene: scene, mood: mood)
        ctx.insert(cast)
        try? ctx.save()
        return cast
    }

    /// Attach a persona to `cast`. `sortOrder` fixes display + iteration order.
    @discardableResult
    static func addPersona(
        _ ctx: ModelContext,
        to cast: EnsembleCast,
        name: String,
        role: String = "",
        voiceID: String,
        suggestedVoice: String = "",
        personaPrompt: String = "",
        temperature: Double = 0.7,
        samplingPreset: SamplingPreset = .relaxed,
        readsOnOthers: [String: String] = [:],
        sortOrder: Int
    ) -> EnsemblePersona {
        let persona = EnsemblePersona(
            name: name,
            role: role,
            voiceID: voiceID,
            suggestedVoice: suggestedVoice,
            personaPrompt: personaPrompt,
            temperature: temperature,
            samplingPreset: samplingPreset,
            readsOnOthers: readsOnOthers,
            sortOrder: sortOrder
        )
        persona.cast = cast
        cast.personas.append(persona)
        ctx.insert(persona)
        cast.updatedAt = .now
        try? ctx.save()
        return persona
    }

    /// Bump `updatedAt` and persist after the caller mutated `cast` directly.
    static func update(_ ctx: ModelContext, cast: EnsembleCast) {
        cast.updatedAt = .now
        try? ctx.save()
    }

    /// Remove one persona from a cast and reindex remaining `sortOrder` values
    /// to `0..<n`. Used by Cast & Settings roster editing.
    static func removePersona(_ ctx: ModelContext, _ persona: EnsemblePersona, from cast: EnsembleCast) {
        cast.personas.removeAll { $0.id == persona.id }
        ctx.delete(persona)
        let remaining = cast.sortedPersonas
        for (i, p) in remaining.enumerated() {
            p.sortOrder = i
        }
        cast.updatedAt = .now
        try? ctx.save()
    }

    static func delete(_ ctx: ModelContext, cast: EnsembleCast) {
        ctx.delete(cast)   // .cascade deletes its personas
        try? ctx.save()
    }

    // MARK: - Sessions (finished episodes)

    /// Persist a finished episode (the {Name}-tagged transcript + speaker
    /// roster). Mirrors HistoryStore.appendMulti, then enforces the cap.
    static func appendSession(
        _ ctx: ModelContext,
        scene: String,
        mood: String,
        transcriptMultiTalk: String,
        speakers: [SpeakerRef]
    ) {
        let session = EnsembleSession(scene: scene, mood: mood, transcriptMultiTalk: transcriptMultiTalk)
        for (i, ref) in speakers.enumerated() {
            let speaker = EnsembleSessionSpeaker(name: ref.name, voiceID: ref.voiceID, sortOrder: i)
            speaker.session = session
            session.speakers.append(speaker)
            ctx.insert(speaker)
        }
        ctx.insert(session)
        enforceSessionCap(ctx)
        try? ctx.save()
    }

    static func sessions(_ ctx: ModelContext) -> [EnsembleSession] {
        let descriptor = FetchDescriptor<EnsembleSession>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// Keep all pinned + the most-recent `maxUnpinnedSessions` unpinned rows.
    static func enforceSessionCap(_ ctx: ModelContext) {
        let predicate = #Predicate<EnsembleSession> { $0.pinned == false }
        let descriptor = FetchDescriptor<EnsembleSession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let unpinned = try? ctx.fetch(descriptor),
              unpinned.count > maxUnpinnedSessions else { return }
        for stale in unpinned.dropFirst(maxUnpinnedSessions) {
            ctx.delete(stale)
        }
    }
}
