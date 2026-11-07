//
//  CloneViewModel.swift
//  SecureClone
//
//  Orchestrates a job: scan source → clone+verify each file → write MHL + logs.
//  Publishes progress for the UI.
//

import Foundation
import Combine

@MainActor
final class CloneViewModel: ObservableObject {

    // Selection
    @Published var selectedSource: VolumeInfo?
    @Published var selectedDestinations: Set<VolumeInfo> = []
    @Published var algorithm: HashAlgorithm = .xxh64
    @Published var jobName: String = "Offload"

    // Live job
    @Published var job: CloneJob?
    @Published var isRunning = false
    @Published var logTail: [String] = []

    private let engine = CloneEngine()

    var canStart: Bool {
        selectedSource != nil && !selectedDestinations.isEmpty && !isRunning
    }

    func start() {
        guard let source = selectedSource, !selectedDestinations.isEmpty else { return }
        let destinations = Array(selectedDestinations)
        let job = CloneJob(source: source, destinations: destinations, algorithm: algorithm)
        self.job = job
        self.isRunning = true
        self.logTail = []

        Task { await run(job: job) }
    }

    private func run(job: CloneJob) async {
        let startDate = Date()
        let destinationRoots = job.destinations.map { $0.url }

        do {
            // 1. Scan
            job.state = .scanning
            appendLog("Scanning \(job.source.url.path)…")
            let files = try SourceScanner.scan(root: job.source.url)
            job.totalBytes = SourceScanner.totalBytes(files)
            appendLog("Found \(files.count) files, \(VolumeInfo.format(job.totalBytes)).")

            // Pre-flight: capacity check on each destination.
            for dest in job.destinations {
                if dest.availableCapacity < job.totalBytes {
                    appendLog("⚠️ \(dest.name) may not have enough free space "
                              + "(\(dest.availableCapacityFormatted) free).")
                }
            }

            // 2. COPY PHASE — pipelined: read once, every drive writes concurrently.
            job.state = .copying
            job.copyStartedAt = Date()

            // Progress bytes are accumulated off the main actor; a poller
            // publishes them ~4×/sec so the bar moves even inside one huge file.
            let progress = ProgressThrottle()
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    j.recordProgress(bytes: progress.snapshot())
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { poller.cancel() }

            let engine = self.engine
            let algorithm = job.algorithm
            var copied: [CopiedFile] = []

            for file in files {
                job.currentFile = file.relativePath
                // Blocking disk I/O runs off the main actor.
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.copyFile(source: file,
                                        destinationRoots: destinationRoots,
                                        algorithm: algorithm,
                                        onChunk: { progress.add($0) })
                }.value
                copied.append(result)

                for dp in job.destinationProgress {
                    dp.filesCompleted += 1
                    dp.bytesCompleted += file.size
                }
                appendLog("→ \(file.relativePath)  [\(result.sourceHash)]")
            }

            poller.cancel()
            job.bytesProcessed = job.totalBytes
            job.overallProgress = 1.0
            job.etaSeconds = 0
            if let start = job.copyStartedAt {
                job.elapsedSeconds = Date().timeIntervalSince(start)
            }
            appendLog("Copy complete in \(job.elapsedText). Verifying all destinations in parallel…")

            // 3. VERIFY PHASE — every destination re-read concurrently.
            job.state = .verifying
            job.currentFile = ""
            job.verifyTotalBytes = job.totalBytes * Int64(max(1, job.destinations.count))
            job.verifyBytesDone = 0

            let verifyProgress = ProgressThrottle()
            let verifyPoller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    j.verifyBytesDone = verifyProgress.snapshot()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            let copiedSnapshot = copied
            let outcomes = await Task.detached(priority: .userInitiated) {
                engine.verify(copied: copiedSnapshot,
                              destinationRoots: destinationRoots,
                              algorithm: algorithm,
                              onFileVerified: nil,
                              onBytes: { verifyProgress.add(Int($0)) })
            }.value
            verifyPoller.cancel()
            job.verifyBytesDone = job.verifyTotalBytes

            // Publish per-file + per-destination results.
            for outcome in outcomes {
                var fr = FileResult(relativePath: outcome.relativePath, size: outcome.size)
                fr.sourceHash = outcome.sourceHash
                fr.destinationHashes = outcome.destinationHashes
                fr.verified = outcome.verified
                job.fileResults.append(fr)

                for dp in job.destinationProgress {
                    if let ok = outcome.verified[dp.volume.url] {
                        if ok { dp.verifiedCount += 1 } else { dp.failed = true }
                    }
                }
                if !outcome.allVerified {
                    appendLog("✗ MISMATCH \(outcome.relativePath)")
                }
            }

            // 4. Write reports
            let finishDate = Date()

            for dest in job.destinations {
                let mhlURL = try MHLWriter.write(
                    destinationRoot: dest.url,
                    outcomes: outcomes,
                    algorithm: job.algorithm,
                    startDate: startDate,
                    finishDate: finishDate,
                    jobName: jobName
                )
                appendLog("Wrote MHL → \(mhlURL.lastPathComponent)")

                let report = LogWriter.makeReport(
                    jobName: jobName,
                    source: job.source,
                    destinations: job.destinations,
                    outcomes: outcomes,
                    algorithm: job.algorithm,
                    startDate: startDate,
                    finishDate: finishDate
                )
                let logURL = try LogWriter.write(report: report, to: dest.url,
                                                 jobName: jobName, finishDate: finishDate)
                appendLog("Wrote log → \(logURL.lastPathComponent)")
            }

            job.state = job.allDestinationsVerified ? .completed : .failed("Verification mismatch")
            appendLog(job.allDestinationsVerified
                      ? "✅ ALL DESTINATIONS VERIFIED — SAFE TO WIPE SOURCE"
                      : "❌ VERIFICATION FAILED — DO NOT WIPE SOURCE")

        } catch {
            job.state = .failed(error.localizedDescription)
            appendLog("ERROR: \(error.localizedDescription)")
        }

        isRunning = false
    }

    private func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 500 { logTail.removeFirst(logTail.count - 500) }
    }
}
