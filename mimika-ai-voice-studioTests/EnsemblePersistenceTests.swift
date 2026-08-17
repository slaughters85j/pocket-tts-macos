//
//  EnsemblePersistenceTests.swift
//  mimika-ai-voice-studioTests
//
//  Phase 0 persistence coverage for Ensemble Mode:
//    * EnsemblePersona.readsOnOthers JSON round-trip
//    * EnsembleStore cast/persona CRUD + cascade delete
//    * EnsembleStore.appendSession speaker ordering
//    * .ensemble prompt scope seeds idempotently
//    * Migration safety: an on-disk store written with the new schema (which
//      includes the additive Ensemble models) preserves legacy rows across a
//      reopen and keeps seeding idempotent.
//

import SwiftData
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class EnsemblePersistenceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try HistoryStore.makeInMemoryContainer()
        return ModelContext(container)
    }

    // MARK: - readsOnOthers round-trip

    func test_readsOnOthers_roundTrip() throws {
        let persona = EnsemblePersona(
            name: "Picard",
            voiceID: "javert",
            readsOnOthers: ["Riker": "good officer, worse adult", "Data": "infuriating, indispensable"],
            sortOrder: 0
        )
        XCTAssertEqual(persona.readsOnOthers["Riker"], "good officer, worse adult")
        XCTAssertEqual(persona.readsOnOthers["Data"], "infuriating, indispensable")

        persona.readsOnOthers = ["Q": "exhausting"]
        XCTAssertEqual(persona.readsOnOthers, ["Q": "exhausting"])
        XCTAssertTrue(persona.readsOnOthersJSON.contains("exhausting"))
    }

    func test_readsOnOthers_toleratesMalformedJSON() throws {
        let persona = EnsemblePersona(name: "X", voiceID: "alba", sortOrder: 0)
        persona.readsOnOthersJSON = "not json"
        XCTAssertEqual(persona.readsOnOthers, [:])
    }

    // MARK: - Cast / persona CRUD

    func test_addPersona_persistsSortedAndCascades() throws {
        let ctx = try makeContext()
        let cast = EnsembleStore.create(ctx, name: "Ten Forward", scene: "after Data's recital", mood: "unimpressed")
        EnsembleStore.addPersona(ctx, to: cast, name: "Picard", voiceID: "javert", temperature: 0.6, sortOrder: 0)
        EnsembleStore.addPersona(ctx, to: cast, name: "Riker", voiceID: "jean", temperature: 0.8, sortOrder: 1)

        let casts = EnsembleStore.casts(ctx)
        XCTAssertEqual(casts.count, 1)
        XCTAssertEqual(casts[0].sortedPersonas.map(\.name), ["Picard", "Riker"])

        EnsembleStore.delete(ctx, cast: cast)
        XCTAssertEqual(EnsembleStore.casts(ctx).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EnsemblePersona>()).count, 0,
                       "cascade delete should remove personas")
    }

    func test_turnMode_roundTripsThroughRawValue() throws {
        let ctx = try makeContext()
        let cast = EnsembleStore.create(ctx, name: "C")
        cast.turnModeRaw = TurnMode.director.rawValue
        EnsembleStore.update(ctx, cast: cast)
        XCTAssertEqual(EnsembleStore.casts(ctx).first?.turnMode, .director)
    }

    // MARK: - WP-CAST-1 removePersona + CastPackage

    func test_removePersona_reindexesSortOrder() throws {
        let ctx = try makeContext()
        let cast = EnsembleStore.create(ctx, name: "Bridge")
        EnsembleStore.addPersona(ctx, to: cast, name: "Picard", voiceID: "javert", sortOrder: 0)
        EnsembleStore.addPersona(ctx, to: cast, name: "Riker", voiceID: "jean", sortOrder: 1)
        EnsembleStore.addPersona(ctx, to: cast, name: "Data", voiceID: "marius", sortOrder: 2)

        let mid = cast.sortedPersonas[1]
        EnsembleStore.removePersona(ctx, mid, from: cast)

        XCTAssertEqual(cast.sortedPersonas.map(\.name), ["Picard", "Data"])
        XCTAssertEqual(cast.sortedPersonas.map(\.sortOrder), [0, 1])
    }

    func test_castPackage_roundTripEncodeDecode() throws {
        let personas = [
            Persona(name: "Picard", voiceID: "javert", systemPrompt: "Captain.", samplingPreset: .strict),
            Persona(name: "Q", voiceID: "marius", systemPrompt: "Chaos.", samplingPreset: .butterflyChaser),
        ]
        let package = CastPackageBuilder.make(
            castID: UUID(),
            castName: "Q Continuum",
            scene: "Ten Forward",
            mood: "unimpressed",
            userPeerName: "Guest",
            personas: personas,
            rolesAndReads: [
                (role: "captain", suggestedVoice: "gravelly", reads: ["Q": "exhausting"]),
                (role: "entity", suggestedVoice: "", reads: [:]),
            ],
            turnMode: .director,
            rngMode: .shuffleOnce,
            paceSeconds: 0.6,
            maxTurns: 60,
            contextWindowTurns: 16,
            rollingSummaryEnabled: true,
            voicedPlayback: true,
            scenePlayMode: .sceneFirst
        )
        let data = try CastPackageBuilder.jsonEncoder().encode(package)
        let decoded = try CastPackageBuilder.jsonDecoder().decode(CastPackage.self, from: data)

        XCTAssertEqual(decoded.formatVersion, CastPackage.currentFormatVersion)
        XCTAssertEqual(decoded.cast.scene, "Ten Forward")
        XCTAssertEqual(decoded.cast.turnModeRaw, TurnMode.director.rawValue)
        XCTAssertEqual(decoded.cast.scenePlayModeRaw, ScenePlayMode.sceneFirst.rawValue)
        XCTAssertEqual(decoded.personas.count, 2)
        XCTAssertEqual(decoded.personas[0].name, "Picard")
        XCTAssertEqual(decoded.personas[0].readsOnOthers["Q"], "exhausting")
        XCTAssertEqual(decoded.personas[1].samplingPresetRaw, SamplingPreset.butterflyChaser.rawValue)
    }

    func test_castPackage_toleratesMissingOptionalRunKnobs() throws {
        // Minimal JSON an older/hand-written exporter might produce.
        let json = """
        {
          "formatVersion": 1,
          "exportedAt": "2026-01-15T12:00:00Z",
          "cast": {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "name": "Minimal",
            "scene": "bridge",
            "mood": "tense",
            "userPeerName": "You"
          },
          "personas": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Data",
              "role": "",
              "voiceID": "marius",
              "suggestedVoice": "",
              "personaPrompt": "Android.",
              "temperature": 0.7,
              "samplingPresetRaw": "relaxed",
              "readsOnOthers": {},
              "sortOrder": 0
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let decoded = try CastPackageBuilder.jsonDecoder().decode(CastPackage.self, from: data)
        XCTAssertEqual(decoded.personas.count, 1)
        XCTAssertNil(decoded.cast.turnModeRaw)
        XCTAssertNil(decoded.cast.maxTurns)
        XCTAssertEqual(decoded.personas[0].voiceID, "marius")
    }

    func test_resolveVoiceID_fallsBackToCosette() {
        let available: Set<String> = ["javert", "cosette"]
        XCTAssertEqual(CastPackageBuilder.resolveVoiceID("javert", available: available), "javert")
        XCTAssertEqual(
            CastPackageBuilder.resolveVoiceID("imported:deadbeef", available: available),
            CastPackageBuilder.defaultVoiceID
        )
    }

    func test_importClampsRunKnobsAndCapsCastSize() throws {
        XCTAssertEqual(CastPackageBuilder.clampMaxTurns(999), 300)
        XCTAssertEqual(CastPackageBuilder.clampMaxTurns(1), 4)
        XCTAssertEqual(CastPackageBuilder.clampVerbatimWindow(100), 40)
        XCTAssertEqual(CastPackageBuilder.clampPaceSeconds(9), 2.5)
        XCTAssertEqual(RNGMode(rawValue: "shuffleOnce"), .shuffleOnce)
        XCTAssertEqual(RNGMode(rawValue: "rerollPerTurn"), .rerollPerTurn)
    }

    func test_qwenPretokens_attachLeadingSpaceToFollowingWord() {
        let parts = QwenTokenEstimator.shared.pretokensForTesting("Hello world")
        XCTAssertEqual(parts, ["Hello", " world"], parts.joined(separator: "|"))
        XCTAssertFalse(parts.contains { $0.allSatisfy(\.isWhitespace) })
    }

    /// `prewarm()` must actually settle the load. It previously dispatched
    /// `countTokens(" ")`, which took the not-ready branch and called `prewarm()`
    /// again — an immortal spin loop on the global queue, one per Ensemble turn,
    /// that starved the main thread and left the estimator permanently unloaded.
    /// Passes whether or not the tokenizer resource is bundled: what regressed
    /// was that the load never *settled*, not which branch it settled on.
    func test_qwenPrewarm_settlesTheLoadAndDoesNotReenter() async throws {
        QwenTokenEstimator.prewarm()
        // Repeat calls must be claimed-and-dropped, never seed a second parse.
        QwenTokenEstimator.prewarm()
        QwenTokenEstimator.prewarm()

        let deadline = Date().addingTimeInterval(20)
        while !QwenTokenEstimator.shared.didFinishLoadingForTesting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            QwenTokenEstimator.shared.didFinishLoadingForTesting,
            "prewarm() never settled — the estimator is spinning instead of loading"
        )

        // Counting after the load must not re-arm a background parse either.
        _ = QwenTokenEstimator.shared.countTokens("the quick brown fox")
        XCTAssertTrue(QwenTokenEstimator.shared.didFinishLoadingForTesting)
    }

    func test_castPackage_rejectsFutureFormatVersionOnApply() throws {
        // Decode still works; applyImportedPackage is what rejects.
        var package = CastPackageBuilder.make(
            castID: UUID(),
            castName: "X",
            scene: "s",
            mood: "m",
            userPeerName: "You",
            personas: [Persona(name: "A", voiceID: "cosette", systemPrompt: "")],
            turnMode: .director,
            rngMode: .shuffleOnce,
            paceSeconds: 0.6,
            maxTurns: 60,
            contextWindowTurns: 16,
            rollingSummaryEnabled: true,
            voicedPlayback: true
        )
        package.formatVersion = 99
        XCTAssertGreaterThan(package.formatVersion, CastPackage.currentFormatVersion)
    }

    // MARK: - Sessions

    func test_appendSession_persistsSpeakersInOrder() throws {
        let ctx = try makeContext()
        let speakers = [
            SpeakerRef(name: "Picard", voiceID: "javert"),
            SpeakerRef(name: "Q", voiceID: "marius"),
        ]
        EnsembleStore.appendSession(ctx, scene: "bridge", mood: "tense",
                                    transcriptMultiTalk: "{Picard} Report. {Q} Mon capitaine.",
                                    speakers: speakers)
        let sessions = EnsembleStore.sessions(ctx)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sortedSpeakers.map(\.name), ["Picard", "Q"])
        XCTAssertEqual(sessions[0].transcriptMultiTalk, "{Picard} Report. {Q} Mon capitaine.")
    }

    // MARK: - Prompt seeding

    func test_loadOrSeedPrompts_seedsEnsembleScope_idempotently() throws {
        let ctx = try makeContext()
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])

        let first = AppDataStore.prompts(ctx, scope: .ensemble)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].isActive)
        XCTAssertNotNil(AppDataStore.activePrompt(ctx, scope: .ensemble))

        // Idempotent: a second pass adds nothing.
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).count, 1)

        // Other scopes still seeded.
        for scope in PromptScope.allCases {
            XCTAssertEqual(AppDataStore.prompts(ctx, scope: scope).count, 1, "scope \(scope) should have one seeded prompt")
        }
    }

    func test_loadOrSeedPrompts_backfillsEmptyNamedDefault() throws {
        let ctx = try makeContext()
        // Old build: the ensemble default was seeded with EMPTY content.
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).first?.content, "")

        // A later launch passes the real default → backfills the untouched row.
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [.ensemble: "THE DEFAULT BODY"])
        let after = AppDataStore.prompts(ctx, scope: .ensemble)
        XCTAssertEqual(after.count, 1, "no duplicate row created")
        XCTAssertEqual(after.first?.content, "THE DEFAULT BODY", "empty named default is backfilled")

        // But an EDITED default is never clobbered.
        after.first?.content = "my tweaks"
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [.ensemble: "THE DEFAULT BODY"])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).first?.content, "my tweaks")
    }

    // MARK: - Migration safety (on-disk reopen)

    func test_onDiskStore_preservesLegacyRows_andSeedsEnsemble_acrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")

        // First open: write a legacy row + seed prompts (incl. ensemble).
        do {
            let config = ModelConfiguration(schema: HistoryStore.schema, url: storeURL)
            let container = try ModelContainer(for: HistoryStore.schema, configurations: [config])
            let ctx = ModelContext(container)
            HistoryStore.appendSingle(text: "legacy entry", voiceID: "cosette", context: ctx)
            AppDataStore.loadOrSeedPrompts(ctx, seedContent: [.chat: "hello"])
            try ctx.save()
        }

        // Reopen with the same (Ensemble-inclusive) schema.
        let config = ModelConfiguration(schema: HistoryStore.schema, url: storeURL)
        let container = try ModelContainer(for: HistoryStore.schema, configurations: [config])
        let ctx = ModelContext(container)

        let legacy = try ctx.fetch(FetchDescriptor<TTSHistoryItem>())
        XCTAssertEqual(legacy.count, 1, "legacy history must survive the reopen")
        XCTAssertEqual(legacy.first?.text, "legacy entry")

        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).count, 1,
                       "ensemble prompt seeded on first open should persist")

        // Re-seed on reopen stays idempotent (no duplicate rows).
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).count, 1)
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .chat).count, 1)
    }
}
