//
//  ChatAudioPlaying.swift
//  mimika-ai-voice-studio
//
//  Testable playback dependency used by Solo Chat.

import Foundation

// MARK: - Playback surface

/// Minimal playback surface Solo Chat needs from StreamingPlayer.
protocol ChatAudioPlaying: Sendable {
    func play(stream: AsyncStream<PCMFrame>) async throws
    func stop() async
}

extension StreamingPlayer: ChatAudioPlaying {}
