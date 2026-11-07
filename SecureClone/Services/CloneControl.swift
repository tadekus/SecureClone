//
//  CloneControl.swift
//  SecureClone
//
//  Pause / resume / cancel switch shared between the UI (main thread) and
//  the engine's reader thread. The reader calls checkpoint() between chunks:
//  it blocks while paused and returns false once cancelled.
//

import Foundation

final class CloneControl: @unchecked Sendable {
    private let cond = NSCondition()
    private var paused = false
    private var cancelled = false

    var isPaused: Bool    { cond.lock(); defer { cond.unlock() }; return paused }
    var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }

    func pause()  { cond.lock(); paused = true;  cond.unlock() }
    func resume() { cond.lock(); paused = false; cond.broadcast(); cond.unlock() }
    func cancel() { cond.lock(); cancelled = true; paused = false; cond.broadcast(); cond.unlock() }

    /// Called by the engine between chunks. Blocks while paused.
    /// Returns false if the job was cancelled.
    func checkpoint() -> Bool {
        cond.lock(); defer { cond.unlock() }
        while paused && !cancelled { cond.wait() }
        return !cancelled
    }
}
