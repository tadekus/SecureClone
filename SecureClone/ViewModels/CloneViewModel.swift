//
//  CloneViewModel.swift
//  SecureClone
//
//  Orchestrates a job:
//    scan source → (resume check) → pipelined copy → parallel verify
//    → write MHL / TXT / CSV reports → show summary.
//  Supports pause / resume / stop; a stopped job saves a session file on
//  every destination and can be picked up later.
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
    @Published var saveReportToSource: Bool = true

    // Live job
    @Published var job: CloneJob?
    @Published var isRunning = false
    @Published var logTail: [String] = []

    // Resume prompt
    @Published var pendingResume: CloneSession? = nil
    @Published var showResumePrompt = false

    // Completion sheet
    @Published var showSummary = false

    private let engine = CloneEngine()
    private var control = CloneControl()
    private var thumbnailTask: Task<Void, Never>? = nil

    var canStart: Bool {
        selectedSource != nil && !selectedDestinations.isEmpty && !isRunning
    }
    var isPaused: Bool { job?.state == .paused }

    // MARK: - Controls

    func start() {
        guard let source = selectedSource, !selectedDestinations.isEmpty else { return }
        let roots = selectedDestinations.map { $0.url }
        // A previous stopped session for the same card + drives + job name?
        if let s = SessionStore.find(jobName: jobName, source: source, destinationRoots: roots),
           !s.completed.isEmpty {
            pendingResume = s
            showResumePrompt = true
            return
        }
        launch(resuming: nil)
    }

    func resumePrevious() {
        let s = pendingResume
        pendingResume = nil
        launch(resuming: s)
    }

    func startOver() {
        SessionStore.delete(jobName: jobName,
                            destinationRoots: selectedDestinations.map { $0.url })
        pendingResume = nil
        launch(resuming: nil)
    }

    func pause() {
        guard let j = job, j.state == .copying || j.state == .verifying else { return }
        control.pause()
        j.state = .paused
        appendLog("⏸ Paused")
    }

    func resume() {
        guard let j = job, j.state == .paused else { return }
        control.resume()
        j.state = .copying
        appendLog("▶ Resumed")
    }

    func stop() {
        guard job != nil, isRunning else { return }
        appendLog("⏹ Stopping after current chunk…")
        control.cancel()
    }

    /// Clear the finished / stopped job so a new one can be configured.
    func reset() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        job = nil
        logTail = []
        showSummary = false
    }

    private func startThumbnailPass(job: CloneJob, root: URL, destinationRoots: [URL],
                                    sourceRoot: URL?, jobName: String, finishDate: Date) {
        let targets = job.clips.filter {
            let k = MediaKind.of(URL(fileURLWithPath: $0.relativePath)); return k == .video || k == .still
        }
        job.thumbnailsTotal = targets.count
        job.thumbnailsDone = 0
        guard !targets.isEmpty else { return }
        appendLog("Generating \(targets.count) thumbnails in the background…")

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self, weak job] in
            let clips = job?.clips ?? []
            await MetadataService.thumbnails(clips: clips, root: root) { path, data in
                guard let job else { return }
                if let i = job.clips.firstIndex(where: { $0.relativePath == path }) {
                    job.clips[i].thumbnailJPEG = data
                }
                job.thumbnailsDone += 1
            }
            guard !Task.isCancelled, let self, let job else { return }
            var written = 0
            for r in destinationRoots + (sourceRoot.map { [$0] } ?? []) {
                if (try? MetadataService.writeContactSheet(clips: job.clips, to: r,
                                                           jobName: jobName, finishDate: finishDate)) != nil {
                    written += 1
                }
            }
            let missing = job.thumbnailsTotal - job.thumbnailsDone
            self.appendLog("Thumbnails done: \(job.thumbnailsDone)/\(job.thumbnailsTotal)"
                           + (missing > 0 ? " (\(missing) not decodable — ARRIRAW/RED need Phase 3)" : "")
                           + ". Contact sheet written to \(written) location\(written == 1 ? "" : "s").")
        }
    }

    // MARK: - Run

    private func launch(resuming session: CloneSession?) {
        guard let source = selectedSource, !selectedDestinations.isEmpty else { return }
        let destinations = Array(selectedDestinations)
        let job = CloneJob(source: source, destinations: destinations, algorithm: algorithm)
        self.job = job
        self.isRunning = true
        self.logTail = []
        self.control = CloneControl()
        Task { await run(job: job, resuming: session) }
    }

    private func run(job: CloneJob, resuming session: CloneSession?) async {
        let startDate = session?.startedAt ?? Date()
        let destinationRoots = job.destinations.map { $0.url }
        let control = self.control
        let engine = self.engine
        let algorithm = job.algorithm
        let jobName = self.jobName

        do {
            // 1. SCAN
            job.state = .scanning
            appendLog("Scanning \(job.source.url.path)…")
            let files = try SourceScanner.scan(root: job.source.url)
            job.totalBytes = SourceScanner.totalBytes(files)
            appendLog("Found \(files.count) files, \(VolumeInfo.format(job.totalBytes)).")

            for dest in job.destinations where dest.availableCapacity < job.totalBytes {
                appendLog("⚠️ \(dest.name) may not have enough free space "
                          + "(\(dest.availableCapacityFormatted) free).")
            }

            // 2. RESUME — trust only records whose files still exist with the right size.
            var copied: [CopiedFile] = []
            var skip: Set<String> = []
            if let s = session {
                let valid = SessionStore.validRecords(s, destinationRoots: destinationRoots)
                let bySource = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
                for rec in valid {
                    guard let sf = bySource[rec.relativePath], sf.size == rec.size else { continue }
                    var destFiles: [URL: URL] = [:]
                    for root in destinationRoots {
                        destFiles[root] = root.appendingPathComponent(rec.relativePath)
                    }
                    copied.append(CopiedFile(source: sf, sourceHash: rec.sourceHash,
                                             destinationFiles: destFiles))
                    skip.insert(rec.relativePath)
                }
                job.resumedFileCount = skip.count
                appendLog("↻ Resuming: \(skip.count) files already copied, "
                          + "\(VolumeInfo.format(copied.reduce(0) { $0 + $1.source.size })) — will be re-verified.")
            }

            var sessionState = CloneSession(
                jobName: jobName,
                sourceVolumeName: job.source.name,
                sourceTotalCapacity: job.source.totalCapacity,
                destinationPaths: destinationRoots.map { $0.path },
                algorithm: algorithm.rawValue,
                startedAt: startDate,
                totalFiles: files.count,
                totalBytes: job.totalBytes,
                completed: copied.map {
                    SessionRecord(relativePath: $0.source.relativePath, size: $0.source.size,
                                  modificationDate: $0.source.modificationDate,
                                  sourceHash: $0.sourceHash)
                },
                updatedAt: Date())
            SessionStore.save(sessionState, destinationRoots: destinationRoots)

            // 3. COPY — pipelined.
            job.state = .copying
            job.copyStartedAt = Date()
            let progress = ProgressThrottle()
            progress.add(Int(copied.reduce(0) { $0 + $1.source.size }))   // resumed bytes count as done
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    if j.state != .paused { j.recordProgress(bytes: progress.snapshot()) }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { poller.cancel() }

            for file in files where !skip.contains(file.relativePath) {
                if control.isCancelled { throw CloneEngineError.cancelled }
                job.currentFile = file.relativePath

                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.copyFile(source: file,
                                        destinationRoots: destinationRoots,
                                        algorithm: algorithm,
                                        control: control,
                                        onChunk: { progress.add($0) })
                }.value
                copied.append(result)

                for dp in job.destinationProgress {
                    dp.filesCompleted += 1
                    dp.bytesCompleted += file.size
                }
                appendLog("→ \(file.relativePath)  [\(result.sourceHash)]")

                // Checkpoint the session after every completed file.
                sessionState.completed.append(SessionRecord(
                    relativePath: file.relativePath, size: file.size,
                    modificationDate: file.modificationDate, sourceHash: result.sourceHash))
                sessionState.updatedAt = Date()
                SessionStore.save(sessionState, destinationRoots: destinationRoots)
            }

            poller.cancel()
            job.bytesProcessed = job.totalBytes
            job.overallProgress = 1.0
            job.etaSeconds = 0
            if let start = job.copyStartedAt { job.elapsedSeconds = Date().timeIntervalSince(start) }
            appendLog("Copy complete in \(job.elapsedText). Verifying all destinations in parallel…")

            // 4. VERIFY — every destination concurrently (resumed files included).
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
                              control: control,
                              onBytes: { verifyProgress.add(Int($0)) })
            }.value
            verifyPoller.cancel()
            job.verifyBytesDone = job.verifyTotalBytes
            if control.isCancelled { throw CloneEngineError.cancelled }

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
                if !outcome.allVerified { appendLog("✗ MISMATCH \(outcome.relativePath)") }
            }

            // 5. METADATA — from the verified copy on the first destination.
            appendLog("Reading clip metadata…")
            let metaRoot = destinationRoots[0]
            let outcomesSnapshot = outcomes
            let clips = await MetadataService.metadata(outcomes: outcomesSnapshot, root: metaRoot)
            job.clips = clips
            let withMeta = clips.filter { $0.isMediaClip && ($0.fps != nil || $0.resolution != nil || $0.durationSeconds != nil) }.count
            let aleCount = outcomesSnapshot.filter { $0.relativePath.lowercased().hasSuffix(".ale") }.count
            appendLog("Metadata: \(withMeta) clips\(aleCount > 0 ? " (\(aleCount) ALE sidecar\(aleCount == 1 ? "" : "s") used)" : "").")

            // 6. REPORTS — MHL + TXT + CSV on every destination, optionally the source.
            let finishDate = Date()
            let report = LogWriter.makeReport(jobName: jobName, source: job.source,
                                              destinations: job.destinations, outcomes: outcomes,
                                              algorithm: algorithm, startDate: startDate,
                                              finishDate: finishDate)
            let csv = CSVReportWriter.make(outcomes: outcomes, metadata: clips, algorithm: algorithm)
            var locations: [URL] = []
            for dest in job.destinations {
                try MHLWriter.write(destinationRoot: dest.url, outcomes: outcomes, algorithm: algorithm,
                                    startDate: startDate, finishDate: finishDate, jobName: jobName)
                let logURL = try LogWriter.write(report: report, to: dest.url,
                                                 jobName: jobName, finishDate: finishDate)
                try CSVReportWriter.write(csv: csv, to: dest.url, jobName: jobName, finishDate: finishDate)
                locations.append(logURL.deletingLastPathComponent())
                appendLog("Reports written → \(dest.name)/\(SessionStore.folderName)/")
            }
            if saveReportToSource {
                do {
                    let u = try LogWriter.write(report: report, to: job.source.url,
                                                jobName: jobName, finishDate: finishDate)
                    try CSVReportWriter.write(csv: csv, to: job.source.url,
                                              jobName: jobName, finishDate: finishDate)
                    locations.append(u.deletingLastPathComponent())
                    appendLog("Reports also written → \(job.source.name)/\(SessionStore.folderName)/")
                } catch {
                    appendLog("⚠️ Could not write report to source (\(error.localizedDescription)) — destinations are unaffected.")
                }
            }

            let ok = job.allDestinationsVerified
            job.state = ok ? .completed : .failed("Verification mismatch")
            job.finalReport = report
            job.reportLocations = locations
            if ok { SessionStore.delete(jobName: jobName, destinationRoots: destinationRoots) }
            appendLog(ok ? "✅ ALL DESTINATIONS VERIFIED — SAFE TO WIPE SOURCE"
                         : "❌ VERIFICATION FAILED — DO NOT WIPE SOURCE")
            showSummary = true

            // 7. THUMBNAILS — background, from the verified copy; contact sheet at the end.
            startThumbnailPass(job: job, root: metaRoot, destinationRoots: destinationRoots,
                               sourceRoot: saveReportToSource ? job.source.url : nil,
                               jobName: jobName, finishDate: finishDate)

        } catch CloneEngineError.cancelled {
            job.state = .stopped
            job.currentFile = ""
            appendLog("⏹ Stopped. Progress saved — press Start Clone again to resume.")
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
