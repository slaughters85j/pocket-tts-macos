//
//  SynthesisCancellation.swift
//  mimika-ai-voice-studio
//
//  Shared cancellation primitive for engine.synthesize streams.
//
//  The engines hand back an `AsyncStream<PCMFrame>` produced by an unstructured `Task` inside `AsyncStream { … }`, and unstructured tasks do NOT inherit cancellation from the consuming task. So a ViewModel calling `currentTask?.cancel()` on stop left the producer running, burning GPU on audio nobody would hear.
//
//  Instead every engine wires `AsyncStream.Continuation.onTermination` to flip a `CancellationFlag`, and its generation loop polls that flag at chunk and frame boundaries. Cancelling the consumer drops the iterator, which terminates the continuation, which fires the callback, which flips the flag — and the producer bails at its next check.

import Foundation
import Synchronization

// MARK: - CancellationFlag

@preconcurrency
final class CancellationFlag: @unchecked Sendable {
    nonisolated let atomic: Atomic<Bool>
    nonisolated init() { atomic = Atomic<Bool>(false) }
    nonisolated func cancel() { atomic.store(true, ordering: .relaxed) }
    nonisolated var isCancelled: Bool { atomic.load(ordering: .relaxed) }
}

// MARK: - SynthesisQuiescence

/// App-wide registry of in-flight synthesis producer loops, used to gate process termination.
///
/// `-[NSApplication terminate:]` calls `exit()`, which runs C++ static destructors on the main thread — including MetalPerformanceShadersGraph's global registries. A Core ML `prediction(from:usingState:)` still executing on the cooperative pool at that instant dereferences those destroyed globals and dies with EXC_BAD_ACCESS: a "quit unexpectedly" dialog on every quit-while-speaking, and a crash row in App Store Connect.
///
/// So every producer registers its `CancellationFlag` here for the life of its loop. `AppDelegate.applicationShouldTerminate` flips them all via `beginShutdown()`, returns `.terminateLater` while `drain(timeout:)` waits for the producers to exit at their next frame boundary, and only then lets AppKit reach `exit()`. A producer starting AFTER shutdown began is cancelled at registration, before its first model call.
///
/// `nonisolated` opts the whole type out of the target's MainActor-by-default isolation: `begin`/`end` are called from the engines' nonisolated producer tasks (including inside a synchronous `defer`), so they must not hop actors.
nonisolated final class SynthesisQuiescence: Sendable {

    static let shared = SynthesisQuiescence()

    private struct State {
        var active: [ObjectIdentifier: CancellationFlag] = [:]
        var isShuttingDown = false
    }

    private let state = Mutex(State())

    // MARK: Producer registration

    /// Called by an engine's producer task before its first model call. If termination has already begun, the flag is flipped immediately so the producer's first cancellation check bails before any inference.
    func begin(_ flag: CancellationFlag) {
        let cancelNow = state.withLock { s in
            s.active[ObjectIdentifier(flag)] = flag
            return s.isShuttingDown
        }
        if cancelNow { flag.cancel() }
    }

    /// Called (via `defer`) when the producer loop exits for any reason.
    func end(_ flag: CancellationFlag) {
        state.withLock { s in
            s.active[ObjectIdentifier(flag)] = nil
        }
    }

    /// True while any producer loop is between `begin` and `end`.
    var hasActiveWork: Bool {
        state.withLock { !$0.active.isEmpty }
    }

    // MARK: Termination

    /// Latch shutdown and cancel every registered producer. Returns `true` if any producer is still active — the caller should defer termination and `drain(timeout:)` before allowing `exit()`. Once latched, later `begin(_:)` calls are auto-cancelled.
    func beginShutdown() -> Bool {
        let flags = state.withLock { s in
            s.isShuttingDown = true
            return Array(s.active.values)
        }
        for flag in flags { flag.cancel() }
        return hasActiveWork
    }

    /// Waits for every producer to deregister, or `timeout`. Polls at 50 ms, under the producers' 80 ms frame cadence, so it normally exits within a tick or two.
    func drain(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while hasActiveWork && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
