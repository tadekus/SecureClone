//
//  ChunkQueue.swift
//  SecureClone
//
//  A bounded producer/consumer queue of data chunks, one per destination.
//  The reader thread pushes chunks; each writer thread pops at its own pace.
//  When a queue is full (a slow drive), only the reader blocks — other
//  drives keep draining their own queues at full speed.
//
//  Built on NSCondition (classic blocking queue) because the reader and
//  writers are dedicated threads doing blocking I/O, not Swift tasks.
//

import Foundation

final class ChunkQueue: @unchecked Sendable {
    private var items: [Data] = []
    private let capacity: Int
    private let cond = NSCondition()
    private var closed = false
    private var failure: Error? = nil

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Blocks while the queue is full. Returns false if the consumer failed.
    @discardableResult
    func push(_ chunk: Data) -> Bool {
        cond.lock(); defer { cond.unlock() }
        while items.count >= capacity && failure == nil && !closed {
            cond.wait()
        }
        if failure != nil || closed { return false }
        items.append(chunk)
        cond.signal()
        return true
    }

    /// Blocks until a chunk is available. Returns nil when closed and drained.
    func pop() -> Data? {
        cond.lock(); defer { cond.unlock() }
        while items.isEmpty && !closed && failure == nil {
            cond.wait()
        }
        if failure != nil { return nil }
        if items.isEmpty { return nil }      // closed and drained
        let c = items.removeFirst()
        cond.broadcast()                     // wake a blocked producer
        return c
    }

    /// Producer is done: consumers drain what's left, then get nil.
    func close() {
        cond.lock(); closed = true; cond.broadcast(); cond.unlock()
    }

    /// Consumer failed: unblock the producer immediately.
    func fail(_ error: Error) {
        cond.lock(); failure = error; items.removeAll(); cond.broadcast(); cond.unlock()
    }

    var error: Error? {
        cond.lock(); defer { cond.unlock() }
        return failure
    }
}
