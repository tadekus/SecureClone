//
//  PipelinedVerifier.swift
//  SecureClone
//
//  Verifies files as soon as they are copied, while the next file copies.
//  One file is verified at a time (all destinations of that file in
//  parallel, inside CloneEngine.verify), on a serial queue, so the drives
//  see a steady mix of one write stream and one read stream instead of a
//  write burst followed by a read burst.
//

import Foundation

final class PipelinedVerifier: @unchecked Sendable {
    private let engine: CloneEngine
    private let roots: [URL]
    private let algorithm: HashAlgorithm
    private let mode: VerificationMode
    private let control: CloneControl
    private let onBytes: @Sendable (Int64) -> Void
    private let onFileDone: @Sendable (FileCloneOutcome, Double) -> Void   // outcome, verify seconds
    private let queue = DispatchQueue(label: "secureclone.verify", qos: .userInitiated)
    private let lock = NSLock()
    private var outcomes: [String: FileCloneOutcome] = [:]
    private var order: [String] = []

    init(engine: CloneEngine, roots: [URL], algorithm: HashAlgorithm, mode: VerificationMode,
         control: CloneControl,
         onBytes: @escaping @Sendable (Int64) -> Void,
         onFileDone: @escaping @Sendable (FileCloneOutcome, Double) -> Void) {
        self.engine = engine; self.roots = roots; self.algorithm = algorithm; self.mode = mode
        self.control = control; self.onBytes = onBytes; self.onFileDone = onFileDone
    }

    /// Queue one copied file for verification. Returns immediately.
    func submit(_ c: CopiedFile) {
        lock.lock(); order.append(c.source.relativePath); lock.unlock()
        queue.async { [self] in
            if control.isCancelled { return }
            let t0 = Date()
            let outs = engine.verify(copied: [c], destinationRoots: roots, algorithm: algorithm,
                                     mode: mode, control: control, onBytes: onBytes)
            guard let o = outs.first else { return }
            var withTime = o
            withTime.verifySeconds = Date().timeIntervalSince(t0)
            lock.lock(); outcomes[o.relativePath] = withTime; lock.unlock()
            onFileDone(withTime, withTime.verifySeconds)
        }
    }

    /// Wait for everything submitted so far, then return outcomes in
    /// submission order.
    func drain() async -> [FileCloneOutcome] {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { outcomes[$0] }
    }
}
