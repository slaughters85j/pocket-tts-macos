//
//  ReadAloudController.swift
//  mimika-ai-voice-studio
//
//  The single "speak this text aloud" brain shared by the menu-bar item and the macOS "Read Selection Aloud" Service. Reuses the app's already-warm engine + player (mirrors SingleVoiceViewModel's synth loop, minus history/preview) so a read-aloud has no extra model-load cost. Cancels any in-flight read first.
//

import Foundation
import Observation

@MainActor
@Observable
final class ReadAloudController {

    private unowned let appState: AppState
    private var task: Task<Void, Never>?
    /// Bumped by every `speak` and `stop`. Only the newest read may report itself finished, so a straggler completing late cannot clear the flag out from under the read that replaced it.
    private var generation = 0
    private(set) var isSpeaking = false

    init(appState: AppState) {
        self.appState = appState
    }

    /// Synthesize + play `raw` aloud with the configured read-aloud voice.
    func speak(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard appState.engineStatus == .ready, let player = appState.player else {
            appState.toastMessage = "mimika's voice models are still loading — try again in a moment."
            return
        }

        let engine = appState.activeEngine
        let voice = appState.chatSettings.readAloudVoiceID
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget
        options.seed = VoiceManager.shared.resolveSeedForSynthesis(voiceID: voice)

        let previous = task
        previous?.cancel()
        generation &+= 1
        let thisGeneration = generation
        isSpeaking = true
        task = Task { [weak self] in
            // Cancelling `previous` does NOT unblock it. `StreamingPlayer.play()` parks on a single shared drain continuation, is not cancellation-aware, and the next `play()` nils that continuation out from under the parked call — stranding it forever. `stop()` is the only thing that resumes it, which is why the menu bar's Stop Speaking was the manual cure. Stop first, then wait for the old read to actually unwind, so exactly one read owns the player.
            if previous != nil {
                await player.stop()
                _ = await previous?.value
            }

            // Runs however this read ends — finished, cancelled, or thrown — so the flag cannot stick true and leave Stop Speaking as the only way out.
            defer {
                if let self, self.generation == thisGeneration { self.isSpeaking = false }
            }

            // Tee the engine stream into the player (same pattern as Single Voice).
            let (relay, relayCont) = AsyncStream<PCMFrame>.makeStream(of: PCMFrame.self)
            async let playerResult: Void = {
                do { try await player.play(stream: relay) }
                catch { FileHandle.standardError.write(Data("read-aloud player error: \(error)\n".utf8)) }
            }()

            let gain = VoiceLevel.gainFactor(forVoice: voice)
            for await frame in engine.synthesize(text: text, voiceID: voice, options: options) {
                if Task.isCancelled { break }
                relayCont.yield(PCMFrame(
                    samples: VoiceLevel.applyGain(frame.samples, gain: gain),
                    isFinal: frame.isFinal
                ))
                if frame.isFinal { break }
            }
            relayCont.finish()
            _ = await playerResult
        }
    }

    /// Stop the current read-aloud (also surfaced as the menu bar's "Stop").
    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        if let player = appState.player {
            Task { await player.stop() }
        }
        isSpeaking = false
    }
}
