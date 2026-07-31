//
//  EnsembleLoopTests.swift
//  mimika-ai-voice-studioTests
//
//  Loop-path coverage for EnsembleViewModel.runOneTurn, exercising the three
//  regressions caught in review:
//    * resolved-model fallback (empty pinned model -> connection-probe model)
//    * the in-flight placeholder turn is NOT sent as request context
//    * an HTTP error is preserved as .error and stops the loop
//
//  The LLM is stubbed via LLMStubURLProtocol (defined in LocalLLMClientTests)
//  by injecting an ephemeral URLSession into the view model. speak:false keeps
//  audio out of it; the no-op StubEngine is never asked to synthesize.
//

import XCTest
import SwiftData
@testable import mimika_ai_voice_studio

@MainActor
final class EnsembleLoopTests: XCTestCase {

    private struct StubEngine: TTSEngineProtocol {
        nonisolated func availableVoiceIDs() -> [String] { [] }
        nonisolated func synthesize(
            text: String, voiceID: String, options: SynthesisOptions
        ) -> AsyncStream<PCMFrame> {
            AsyncStream { $0.finish() }
        }
    }

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    private func makeVM(
        pinnedModel: String,
        connectedModel: String,
        personaReasoningEffort: String? = nil
    ) throws -> EnsembleViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        let session = URLSession(configuration: config)

        let appState = AppState()
        appState.chatSettings.model = pinnedModel

        let vm = EnsembleViewModel(
            engine: StubEngine(),
            player: try StreamingPlayer(),
            appState: appState,
            session: session,
            personaReasoningEffort: { personaReasoningEffort }
        )
        vm.connectionState = .connected(model: connectedModel)
        vm.voicedPlayback = false   // exercise the generate path without audio
        return vm
    }

    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
        return Data((chunk + "data: [DONE]\n\n").utf8)
    }

    // MARK: - Reuse last cast

    func test_loadLastCast_restoresSavedCast() throws {
        let ctx = ModelContext(try HistoryStore.makeInMemoryContainer())
        let appState = AppState()
        appState.modelContext = ctx

        // Seed a saved cast directly via the store (no persona-writer round-trip).
        let saved = EnsembleStore.create(ctx, name: "Bridge", scene: "the bridge", mood: "tense")
        EnsembleStore.addPersona(ctx, to: saved, name: "Picard", voiceID: "javert",
                                 personaPrompt: "Engage.", temperature: 0.6,
                                 samplingPreset: .strict, sortOrder: 0)
        EnsembleStore.addPersona(ctx, to: saved, name: "Q", voiceID: "marius",
                                 personaPrompt: "Mon capitaine.", temperature: 0.9,
                                 samplingPreset: .spirited, sortOrder: 1)

        let vm = EnsembleViewModel(engine: StubEngine(), player: try StreamingPlayer(), appState: appState)
        XCTAssertTrue(vm.hasSavedCast)
        XCTAssertTrue(vm.loadLastCast())
        XCTAssertEqual(vm.scene, "the bridge")
        XCTAssertEqual(vm.mood, "tense")
        XCTAssertEqual(vm.cast.map(\.name), ["Picard", "Q"])
        XCTAssertEqual(vm.cast.map(\.voiceID), ["javert", "marius"])
        XCTAssertEqual(vm.cast.map(\.samplingPreset), [.strict, .spirited])
        XCTAssertEqual(vm.cast.first?.systemPrompt, "Engage.")
    }

    func test_loadLastCast_returnsFalse_whenNothingSaved() throws {
        let ctx = ModelContext(try HistoryStore.makeInMemoryContainer())
        let appState = AppState()
        appState.modelContext = ctx

        let vm = EnsembleViewModel(engine: StubEngine(), player: try StreamingPlayer(), appState: appState)
        XCTAssertFalse(vm.hasSavedCast)
        XCTAssertFalse(vm.loadLastCast(), "no saved cast → no-op")
        XCTAssertEqual(vm.cast.map(\.name), EnsembleViewModel.demoCast.map(\.name),
                       "falls back to the demo cast loaded at init")
    }

    // MARK: - Barge-in

    func test_truncatedSpokenText_keepsPlayedSentencesDropsInFlight() {
        let s1 = "The first thing I want to say is genuinely important here."
        let s2 = "The second point follows on quite naturally from that one."
        let s3 = "And a third sentence that was mid-play when it got cut off."
        let content = "\(s1) \(s2) \(s3)"
        // 2 sentences fully played → keep both; the in-flight 3rd is excluded.
        let kept = EnsembleViewModel.truncatedSpokenText(content: content, playedSentences: 2)
        XCTAssertNotNil(kept)
        XCTAssertTrue(kept!.contains("first thing"))
        XCTAssertTrue(kept!.contains("second point"))
        XCTAssertFalse(kept!.contains("third"), "the unplayed in-flight sentence is excluded")
        // 0 played → nothing heard → nil (whole turn dropped).
        XCTAssertNil(EnsembleViewModel.truncatedSpokenText(content: content, playedSentences: 0))
    }

    func test_submitUserTurn_inUserTurnState_appendsAndResumes() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.cast = []                    // no cast → resumeCast lands on .idle (no loop spun)
        vm.runState = .userTurn         // simulate a post-barge-in state
        vm.draft = "What do you make of that?"
        vm.submitUserTurn()             // routes to finishBargeIn
        XCTAssertEqual(vm.turns.count, 1)
        XCTAssertNil(vm.turns.last?.speakerID, "appended as a user turn")
        XCTAssertEqual(vm.turns.last?.content, "What do you make of that?")
        XCTAssertTrue(vm.draft.isEmpty)
        XCTAssertEqual(vm.runState, .idle, "no cast to resume → idle")
    }

    // MARK: - Context management (Phase 5)

    func test_shouldSummarize_firesPastWindowPlusBatch() {
        XCTAssertFalse(EnsembleViewModel.shouldSummarize(turnCount: 23, verbatimWindow: 16, summarizedUpTo: 0, batch: 8))
        XCTAssertTrue(EnsembleViewModel.shouldSummarize(turnCount: 24, verbatimWindow: 16, summarizedUpTo: 0, batch: 8))
        // After folding through 8, it needs 8 more out-of-window turns.
        XCTAssertFalse(EnsembleViewModel.shouldSummarize(turnCount: 31, verbatimWindow: 16, summarizedUpTo: 8, batch: 8))
        XCTAssertTrue(EnsembleViewModel.shouldSummarize(turnCount: 32, verbatimWindow: 16, summarizedUpTo: 8, batch: 8))
    }

    func test_messagesForPersona_keepsUnsummarizedTurns_noGap() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let ada = Persona(name: "Ada", voiceID: "x", systemPrompt: "")
        vm.cast = [ada]
        vm.verbatimWindow = 4
        vm.turns = (0..<10).map { EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "line \($0)") }
        vm.summarizedUpTo = 2          // turns 0–1 folded into the summary
        vm.rollingSummary = "earlier stuff"
        let msgs = vm.messagesForPersona(ada)
        let verbatim = msgs.filter { $0.content.contains("line ") }
        XCTAssertEqual(verbatim.count, 8, "all 8 un-summarized turns shown — none lost to the window")
        XCTAssertTrue(msgs.contains { $0.content.contains("earlier stuff") }, "rolling summary is prepended")
    }

    func test_messagesForPersona_capsContextWhenSummarizerStalls() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let ada = Persona(name: "Ada", voiceID: "x", systemPrompt: "")
        vm.cast = [ada]
        vm.verbatimWindow = 16
        vm.turns = (0..<60).map { EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "line \($0)") }
        vm.summarizedUpTo = 0   // summarizer never advanced (stalled / failing)
        let verbatim = vm.messagesForPersona(ada).filter { $0.content.contains("line ") }
        XCTAssertEqual(verbatim.count, EnsembleViewModel.maxContextTurns,
                       "context is capped at maxContextTurns, not unbounded")
    }

    // MARK: - Director + grenade (Phase 6)

    func test_directorPrompt_resolvesNameExcludingSelf() {
        let mulder = Persona(name: "Fox Mulder", voiceID: "x", systemPrompt: "")
        let scully = Persona(name: "Dana Scully", voiceID: "y", systemPrompt: "")
        let cast = [mulder, scully]
        XCTAssertEqual(DirectorPrompt.resolve("Dana Scully should go next.", cast: cast, excluding: mulder.id), scully.id)
        XCTAssertEqual(DirectorPrompt.resolve("scully", cast: cast, excluding: nil), scully.id)
        XCTAssertNil(DirectorPrompt.resolve("Fox Mulder", cast: cast, excluding: mulder.id), "can't pick the last speaker")
        XCTAssertNil(DirectorPrompt.resolve("nobody here", cast: cast, excluding: nil))
    }

    func test_detectsAgreementCollapse() {
        let id = UUID()
        func turn(_ s: String) -> EnsembleTurn { EnsembleTurn(speakerID: id, speakerName: "A", content: s) }
        XCTAssertTrue(EnsembleViewModel.detectsAgreementCollapse(turns: [
            turn("I completely agree with that."),
            turn("Exactly, well said."),
            turn("Absolutely, you're right.")
        ]))
        XCTAssertFalse(EnsembleViewModel.detectsAgreementCollapse(turns: [
            turn("I agree with that."),
            turn("But I'm not so sure, actually."),
            turn("Exactly though.")
        ]), "a pushback breaks the collapse")
        XCTAssertFalse(EnsembleViewModel.detectsAgreementCollapse(turns: [turn("I agree."), turn("Exactly.")]),
                       "too few turns")
    }

    // MARK: - Export (Phase 6)

    func test_formatMultiTalkScript_tagsByLabelSkipsEmpty() {
        let a = UUID(); let b = UUID()
        let turns = [
            EnsembleTurn(speakerID: a, speakerName: "Fox", content: "The truth is out there."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "   "),       // empty → skipped
            EnsembleTurn(speakerID: b, speakerName: "Dana", content: "Show me evidence."),
        ]
        let label: (UUID?) -> String = { id in
            if id == a { return "Fox Mulder" }
            if id == b { return "Dana Scully" }
            return "You"
        }
        let script = EnsembleViewModel.formatMultiTalkScript(turns: turns, label: label, stripBrackets: true)
        XCTAssertTrue(script.contains("{Fox Mulder} The truth is out there."))
        XCTAssertTrue(script.contains("{Dana Scully} Show me evidence."))
        XCTAssertFalse(script.contains("{You}"), "the empty user turn is skipped")
        XCTAssertEqual(script.split(separator: "\n").count, 2)
    }

    func test_exportLabels_disambiguatesDuplicateNames() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let a = Persona(name: "Alex", voiceID: "v1", systemPrompt: "")
        let b = Persona(name: "Alex", voiceID: "v2", systemPrompt: "")
        vm.cast = [a, b]
        vm.userPeer.name = "Alex"
        vm.turns = [
            EnsembleTurn(speakerID: a.id, speakerName: "Alex", content: "One."),
            EnsembleTurn(speakerID: b.id, speakerName: "Alex", content: "Two."),
            EnsembleTurn(speakerID: nil, speakerName: "Alex", content: "Three."),
        ]
        let labels = vm.exportLabels()
        XCTAssertEqual(labels.speakers.count, 3, "three distinct speakers")
        XCTAssertEqual(Set(labels.speakers.map(\.name)).count, 3, "tags are unique per speaker")
        let script = vm.formatTranscriptMultiTalk()
        XCTAssertTrue(script.contains("{Alex} One."))
        XCTAssertTrue(script.contains("{Alex 2} Two."))
        XCTAssertTrue(script.contains("{Alex 3} Three."))
    }

    func test_resolvedModel_honorsSavedOnlyWhenLoaded() throws {
        let vm = try makeVM(pinnedModel: "dolphin", connectedModel: "dolphin")
        // Endpoint now serves only gemma — the saved "dolphin" is stale.
        vm.availableModels = ["gemma"]
        XCTAssertEqual(vm.resolvedModel, "gemma", "a saved model not served falls back to the loaded one")
        // When the saved model IS served, honour it.
        vm.availableModels = ["dolphin", "gemma"]
        XCTAssertEqual(vm.resolvedModel, "dolphin")
    }

    func test_userTurns_useModelNameNotDisplayPronoun_inPOV() throws {
        // The "You: …" leak: the user's display name reached the model, which
        // echoed it back as address ("Your skepticism"). The model must see a
        // non-pronoun proper noun instead; display keeps "You".
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let data = Persona(name: "Data", voiceID: "v", systemPrompt: "")
        vm.cast = [data]
        vm.turns = [
            EnsembleTurn(speakerID: data.id, speakerName: "Data", content: "Curious."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "And I am Odo."),
        ]
        let joined = vm.messagesForPersona(data).map(\.content).joined(separator: "\n")
        XCTAssertFalse(joined.contains("You:"), "the display pronoun must never reach the model")
        XCTAssertTrue(joined.contains("Guest: And I am Odo."), "user line uses the model-facing name")
        XCTAssertEqual(vm.turns[1].speakerName, "You", "raw transcript (display/export) is untouched")
    }

    func test_turnsForModel_isIdentityWhenUserSetARealName() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.userPeer.name = "John"
        vm.userPeer.modelName = "John"
        vm.turns = [EnsembleTurn(speakerID: nil, speakerName: "John", content: "Hi.")]
        XCTAssertEqual(vm.turnsForModel().map(\.speakerName), ["John"])  // a real name passes through
    }

    func test_exportLabels_userGetsVoiceDistinctFromCast() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let fox = Persona(name: "Fox Mulder", voiceID: "javert", systemPrompt: "")
        let data = Persona(name: "Commander Data", voiceID: "jean", systemPrompt: "")
        vm.cast = [fox, data]
        vm.turns = [
            EnsembleTurn(speakerID: fox.id, speakerName: "Fox Mulder", content: "The truth is out there."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "Hello."),
        ]
        let refs = vm.exportLabels().speakers
        let userRef = refs.first { $0.name == "You" }
        XCTAssertNotNil(userRef, "the user is a distinct export speaker")
        XCTAssertFalse(["javert", "jean"].contains(userRef!.voiceID),
                       "the user's export voice must be distinct from every cast voice (no shared-voice tag collision)")
    }

    func test_effectiveCastForTurnOrder_includesUserWhenEnabled() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let picard = Persona(name: "Picard", voiceID: "javert", systemPrompt: "")
        vm.cast = [picard]
        vm.userPeer.name = "You"
        vm.userPeer.modelName = "Guest"
        vm.setIncludeUserInTurnOrder(true)
        XCTAssertFalse(vm.includeUserInTurnOrder, "requires a real character name")
        XCTAssertEqual(vm.effectiveCastForTurnOrder().count, 1)

        vm.userPeer.name = "Milton"
        vm.userPeer.modelName = "Milton"
        vm.setIncludeUserInTurnOrder(true)
        XCTAssertTrue(vm.includeUserInTurnOrder)
        let roster = vm.effectiveCastForTurnOrder()
        XCTAssertEqual(roster.count, 2)
        XCTAssertEqual(roster.last?.id, EnsembleViewModel.userTurnSpeakerID)
        XCTAssertEqual(roster.last?.name, "Milton")
    }

    func test_softDumpBrief_includesSceneCastAndRecentLines() {
        let dropped = [
            EnsembleTurn(speakerID: UUID(), speakerName: "Picard", content: "Shields to maximum."),
            EnsembleTurn(speakerID: UUID(), speakerName: "Riker", content: "Aye, Captain — rerouting power."),
            EnsembleTurn.sceneBeat("ignored in samples"),
        ]
        let brief = EnsembleViewModel.buildSoftDumpBrief(
            droppedTurns: dropped,
            scene: "bridge under fire",
            mood: "tense",
            castNames: ["Picard", "Riker", "Worf"]
        )
        XCTAssertTrue(brief.contains("bridge under fire"), brief)
        XCTAssertTrue(brief.contains("Picard"), brief)
        XCTAssertTrue(brief.contains("Shields to maximum"), brief)
        XCTAssertTrue(brief.contains("Director compacted context") || brief.contains("compacted"), brief)
    }

    func test_softDumpContext_keepsTranscriptButShrinksModelWindow() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let a = Persona(name: "Ada", voiceID: "v", systemPrompt: "")
        vm.cast = [a]
        vm.verbatimWindow = 4
        vm.scene = "lab"
        for i in 0..<12 {
            vm.turns.append(EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "Line \(i)."))
        }
        XCTAssertTrue(vm.softDumpContext())
        XCTAssertEqual(vm.turns.count, 12, "full transcript must remain for export/UI")
        XCTAssertEqual(vm.summarizedUpTo, 8)
        XCTAssertFalse(vm.rollingSummary.isEmpty)
        XCTAssertTrue(vm.rollingSummary.contains("lab") || vm.rollingSummary.contains("Line"),
                      vm.rollingSummary)
        // Model-facing window should be the last 4 lines (+ brief of earlier).
        let msgs = vm.messagesForPersona(a)
        let joined = msgs.map(\.content).joined(separator: "\n")
        XCTAssertTrue(joined.contains("Line 11"), joined)
        XCTAssertTrue(
            joined.contains("Earlier in the conversation") || joined.contains("compacted") || joined.contains("Director"),
            joined
        )
    }

    func test_exportLabels_bootedSpeakersKeepOwnTagsAndVoices() throws {
        // Boot removes from live cast but past turns keep the UUID. Export must
        // still map those lines to the booted name/voice — not "You"/alba.
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let riker = Persona(name: "Cmdr. Riker", voiceID: "jean", systemPrompt: "")
        let picard = Persona(name: "Picard", voiceID: "javert", systemPrompt: "")
        let worf = Persona(name: "Worf", voiceID: "marius", systemPrompt: "")
        vm.cast = [picard, worf]          // riker already booted out of live cast
        vm.departedSpeakers = [riker]
        vm.userPeer.name = "Milton"
        vm.userPeer.modelName = "Milton"
        vm.turns = [
            EnsembleTurn(speakerID: riker.id, speakerName: "Cmdr. Riker", content: "Shields up."),
            EnsembleTurn(speakerID: picard.id, speakerName: "Picard", content: "Make it so."),
            EnsembleTurn(speakerID: nil, speakerName: "Milton", content: "I'm here."),
            EnsembleTurn(speakerID: worf.id, speakerName: "Worf", content: "Aye."),
        ]
        let labels = vm.exportLabels()
        let script = EnsembleViewModel.formatMultiTalkScript(
            turns: vm.turns, label: labels.label, stripBrackets: false
        )
        XCTAssertTrue(script.contains("{Cmdr. Riker} Shields up."), script)
        XCTAssertTrue(script.contains("{Picard} Make it so."), script)
        XCTAssertTrue(script.contains("{Milton} I'm here."), script)
        XCTAssertTrue(script.contains("{Worf} Aye."), script)
        XCTAssertFalse(script.contains("{You}"), "booted lines must not collapse onto the user tag")
        XCTAssertFalse(script.contains("{Alba}"), "booted lines must not collapse onto default stock")
        let rikerRef = labels.speakers.first { $0.name == "Cmdr. Riker" }
        XCTAssertEqual(rikerRef?.voiceID, "jean")
        let userRef = labels.speakers.first { $0.name == "Milton" }
        XCTAssertNotNil(userRef)
        XCTAssertNotEqual(userRef?.voiceID, "jean")
        XCTAssertNotEqual(userRef?.voiceID, "javert")
        XCTAssertNotEqual(userRef?.voiceID, "marius")
    }

    func test_formatTranscriptMarkdown_realNames_preservesContentAndHeader() throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let mara = Persona(name: "Mara", voiceID: "v1", systemPrompt: "")
        vm.cast = [mara]
        vm.scene = "a rooftop bar"
        vm.mood = "easygoing"
        vm.turns = [
            EnsembleTurn(speakerID: mara.id, speakerName: "Mara", content: "Hey (waves)."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "Hi there."),
        ]
        let md = vm.formatTranscriptMarkdown()
        XCTAssertTrue(md.contains("**Mara**:\nHey (waves)."), "raw content preserved (NOT stripped)")
        XCTAssertTrue(md.contains("**You**:\nHi there."))
        XCTAssertTrue(md.contains("a rooftop bar · easygoing"), "scene/mood header")
        XCTAssertTrue(md.contains("\n\n---\n\n"), "blocks separated by rules")
    }

    private func requestBody() throws -> [String: Any] {
        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func test_runOneTurn_usesResolvedModelWhenPinnedIsEmpty() async throws {
        LLMStubURLProtocol.setResponse(sse("Hi."))
        let vm = try makeVM(pinnedModel: "", connectedModel: "resolved-model")

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        XCTAssertEqual(body["model"] as? String, "resolved-model",
                       "empty pinned model should fall back to the connection-probe model")
    }

    func test_runOneTurn_appliesReasoningEffortToPersonaResponse() async throws {
        LLMStubURLProtocol.setResponse(sse("Hi."))
        let vm = try makeVM(
            pinnedModel: "m",
            connectedModel: "m",
            personaReasoningEffort: "high"
        )

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    func test_runOneTurn_excludesInFlightPlaceholderFromRequest() async throws {
        LLMStubURLProtocol.setResponse(sse("Hi."))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")

        _ = await vm.runOneTurn(lastSpeaker: nil)   // empty transcript -> first turn

        let body = try requestBody()
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let hasEmptyAssistant = messages.contains {
            ($0["role"] as? String) == "assistant" && (($0["content"] as? String) ?? "").isEmpty
        }
        XCTAssertFalse(hasEmptyAssistant, "the in-flight placeholder turn must not be sent as context")
    }

    func test_runOneTurn_preservesErrorAndStopsLoopOnHTTPError() async throws {
        LLMStubURLProtocol.setResponse(Data("nope".utf8), statusCode: 400)
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")

        let shouldContinue = await vm.runOneTurn(lastSpeaker: nil)

        XCTAssertFalse(shouldContinue, "a failed turn must not advance the loop")
        if case .error = vm.runState {
            // expected
        } else {
            XCTFail("runState should be .error after an HTTP failure, was \(vm.runState)")
        }
    }

    func test_runOneTurn_framesRequestWithSceneAndMood() async throws {
        LLMStubURLProtocol.setResponse(sse("On topic."))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.scene = "Picard's ready room"
        vm.mood = "radiation away-mission danger, with light satire"

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = messages.first { ($0["role"] as? String) == "system" }
        let content = (system?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("Picard's ready room"), "scene must reach the speaker's system prompt")
        XCTAssertTrue(content.contains("radiation"), "mood/topic must reach the speaker's system prompt")
    }

    func test_interTurnDelay_scalesAndClamps() {
        XCTAssertEqual(EnsembleViewModel.interTurnDelay(for: ""), .seconds(1.8))
        XCTAssertEqual(EnsembleViewModel.interTurnDelay(for: String(repeating: "word ", count: 25)), .seconds(10))
        XCTAssertEqual(EnsembleViewModel.interTurnDelay(for: String(repeating: "word ", count: 200)), .seconds(12))
    }

    func test_runOneTurn_sendsStopSequencesForOtherSpeakers() async throws {
        LLMStubURLProtocol.setResponse(sse("hi"))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.cast = [
            Persona(name: "Ada", voiceID: "x", systemPrompt: ""),
            Persona(name: "Bertrand", voiceID: "y", systemPrompt: ""),
        ]
        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        let stop = (body["stop"] as? [String]) ?? []
        XCTAssertTrue(stop.contains("Guest:"), "the user's model-facing name should be a stop sequence (not the 'You' pronoun)")
        XCTAssertTrue(stop.contains("Ada:") || stop.contains("Bertrand:"),
                      "the non-speaking cast member should be a stop sequence")
        XCTAssertEqual(body["max_tokens"] as? Int, 250, "speaker turns should be length-capped")
    }

    func test_cleanedTurnText_stripsSelfPrefixAndOtherSpeakerLeakage() async throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let ada = Persona(name: "Ada", voiceID: "x", systemPrompt: "")
        vm.cast = [ada, Persona(name: "Bertrand", voiceID: "y", systemPrompt: "")]
        let raw = "Ada: Reporting in. Bertrand: I disagree. You: stop it."
        XCTAssertEqual(vm.cleanedTurnText(raw, speaker: ada), "Reporting in.")
    }

    func test_runOneTurn_sendsPresetSamplingAndRepeatPenalty() async throws {
        LLMStubURLProtocol.setResponse(sse("hi"))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.cast = [Persona(name: "Ada", voiceID: "x", systemPrompt: "", samplingPreset: .butterflyChaser)]

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        XCTAssertEqual(try XCTUnwrap(body["temperature"] as? Double), 1.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(body["top_p"] as? Double), 0.98, accuracy: 0.0001)
        XCTAssertEqual(body["top_k"] as? Int, 100)
        XCTAssertEqual(try XCTUnwrap(body["repeat_penalty"] as? Double), 1.2, accuracy: 0.0001)
    }
}
