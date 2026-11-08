//
//  BufferPool.swift
//  SecureClone
//
//  Fixed pool of page-aligned buffers for the copy pipeline. A Chunk is one
//  filled buffer; it is shared by the hasher and every writer and returns
//  its buffer to the pool automatically when the last holder releases it.
//  No per-chunk allocation, no page-fault zeroing, and the alignment lets
//  F_NOCACHE I/O go straight between the device and our memory.
//

import Foundation
import Darwin

final class BufferPool: @unchecked Sendable {
    let bufferSize: Int
    private var free: [UnsafeMutableRawPointer] = []
    private var all: [UnsafeMutableRawPointer] = []
    private let cond = NSCondition()
    private var closed = false

    init(bufferSize: Int, count: Int) {
        self.bufferSize = bufferSize
        for _ in 0..<max(2, count) {
            var p: UnsafeMutableRawPointer? = nil
            // 16 KB alignment satisfies the page size on Apple Silicon and Intel.
            if posix_memalign(&p, 16384, bufferSize) == 0, let p { free.append(p); all.append(p) }
        }
    }

    deinit {
        for p in all { Darwin.free(p) }
    }

    /// Blocks until a buffer is free. Returns nil once the pool is closed.
    func acquire() -> UnsafeMutableRawPointer? {
        cond.lock(); defer { cond.unlock() }
        while free.isEmpty && !closed { cond.wait() }
        if closed { return nil }
        return free.removeLast()
    }

    fileprivate func release(_ p: UnsafeMutableRawPointer) {
        cond.lock(); free.append(p); cond.signal(); cond.unlock()
    }

    /// Unblock any waiter (used when the copy is aborted).
    func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }
}

/// One filled buffer from the pool. Shared read-only by all consumers;
/// returns to the pool when the last reference goes away.
final class Chunk: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let count: Int
    private let pool: BufferPool

    init(base: UnsafeMutableRawPointer, count: Int, pool: BufferPool) {
        self.base = base; self.count = count; self.pool = pool
    }
    deinit { pool.release(base) }

    var isEmpty: Bool { count == 0 }
}
