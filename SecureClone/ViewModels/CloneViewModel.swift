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

            // 2. Clone + verify, file by file
            job.state = .copying
            var outcomes: [FileCloneOutcome] = []
            let destCount = max(job.destinations.count, 1)
            _ = destCount

            // Throttle UI updates: accumulate bytes off the main actor and
            // publish at most ~10×/sec instead of once per 8 MB chunk. A poller
            // keeps the bar moving smoothly even within a single huge file.
            let progress = ProgressThrottle()
            job.copyStartedAt = Date()
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    j.recordProgress(bytes: progress.snapshot())
                    try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
                }
            }
            defer { poller.cancel() }

            for file in files {
                job.currentFile = file.relativePath

                let outcome = try await engine.cloneFile(
                    source: file,
                    destinationRoots: destinationRoots,
                    algorithm: job.algorithm,
                    onChunk: { chunkBytes in
                        progress.add(chunkBytes)
                    }
                )

                // (Live progress is published by the poller above.)
                outcomes.append(outcome)

                // Update per-file + per-destination UI state.
                var fr = FileResult(relativePath: outcome.relativePath, size: outcome.size)
                fr.sourceHash = outcome.sourceHash
                fr.destinationHashes = outcome.destinationHashes
                fr.verified = outcome.verified
                job.fileResults.append(fr)

                for dp in job.destinationProgress {
                    if let ok = outcome.verified[dp.volume.url] {
                        dp.filesCompleted += 1
                        dp.bytesCompleted += outcome.size
                        if ok { dp.verifiedCount += 1 } else { dp.failed = true }
                    }
                }

                let mark = outcome.allVerified ? "✓" : "✗"
                appendLog("\(mark) \(outcome.relativePath)  [\(outcome.sourceHash)]")
            }

            // Stop the progress poller and pin the bar to 100%.
            poller.cancel()
            job.bytesProcessed = job.totalBytes
            job.overallProgress = 1.0
            job.etaSeconds = 0
            if let start = job.copyStartedAt {
                job.elapsedSeconds = Date().timeIntervalSince(start)
            }

            // 3. Verify summary + write reports
            job.state = .verifying
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
