//
//  CloneViewModel.swift
//  SecureClone
//
//  Orchestrates everything the UI does:
//    • a queue of offload jobs (JobSpec) that run one after another
//    • auto-start on card mount, auto-eject on verified completion
//    • reel detection → job name / naming template → destination folder
//    • optional source subfolder and per-destination base folder
//    • duplicate-card guard, resume prompt, blocking free-space check
//    • skip files whose identical verified copy already exists
//    • the offload pipeline (scan → copy → verify → metadata → reports →
//      history → day summary → thumbnails)
//    • verify-only mode: re-hash a drive against one of its MHLs
//

import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class CloneViewModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case offload = "Offload", verify = "Verify", speed = "Speed test"
        var id: String { rawValue }
    }

    // Dependencies
    let settings: AppSettings
    let log: LogStore
    private weak var monitor: DriveMonitor?
    private var cancellables = Set<AnyCancellable>()

    // Offload selection
    @Published var mode: Mode = .offload
    @Published var selectedSource: VolumeInfo?
    @Published var sourceFolder: URL? = nil                 // nil = whole card
    @Published var selectedDestinations: Set<VolumeInfo> = [] { didSet { rememberDestinations() } }
    @Published var destinationBases: [URL: URL] = [:]       // volume → chosen folder
    @Published var jobName: String = ""
    @Published var jobNameEdited = false
    @Published var camera: String = ""
    @Published var reel: String = ""
    @Published var detectedReel: ReelInfo? = nil
    @Published var detecting = false

    // Verify selection
    @Published var verifyVolume: VolumeInfo?
    @Published var availableMHLs: [URL] = []
    @Published var selectedMHL: URL?
    @Published var scanningMHLs = false

    // Queue & jobs
    @Published var queue: [JobSpec] = []
    @Published var job: CloneJob?
    @Published var finishedJobs: [CloneJob] = []
    @Published var isRunning = false

    // Prompts
    @Published var pendingResume: CloneSession? = nil
    @Published var showResumePrompt = false
    @Published var duplicateOf: HistoryEntry? = nil
    @Published var showDuplicatePrompt = false
    @Published var showSummary = false
    @Published var errorMessage: String? = nil
    @Published var showError = false

    private let engine = CloneEngine()
    private var control = CloneControl()
    private var thumbnailTask: Task<Void, Never>? = nil
    private var sleepActivity: NSObjectProtocol? = nil
    private var pendingSpec: JobSpec? = nil
    private var pendingFiles: [ScannedFile] = []

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    // MARK: - Wiring

    func attach(monitor: DriveMonitor) {
        guard self.monitor == nil else { return }
        self.monitor = monitor
        monitor.mounted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.handleMount(v) }
            .store(in: &cancellables)
        monitor.unmounted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.handleUnmount(url) }
            .store(in: &cancellables)
        let remembered = Set(settings.rememberedDestinations)
        selectedDestinations = Set(monitor.volumes.filter { remembered.contains($0.url.path) })
    }

    private func rememberDestinations() {
        settings.rememberedDestinations = selectedDestinations.map { $0.url.path }.sorted()
    }

    var canStart: Bool {
        switch mode {
        case .offload: return selectedSource != nil && !selectedDestinations.isEmpty
        case .verify:  return verifyVolume != nil && selectedMHL != nil && !isRunning
        case .speed:   return false      // the speed-test pane has its own button
        }
    }
    var isPaused: Bool { job?.state == .paused }

    private var currentFields: NamingFields {
        NamingFields(project: settings.project, day: settings.day, camera: camera, reel: reel,
                     template: settings.template)
    }

    /// e.g. "SSD15/MYFILM/DAY_03/A/A_0071" for the first destination.
    var namingPreview: String {
        let rel = currentFields.render(jobName: jobName, cardName: selectedSource?.name ?? "CARD")
        let first = selectedDestinations.sorted { $0.name < $1.name }.first
        let base = first.map { v in (destinationBases[v.url] ?? v.url).lastPathComponent } ?? "<drive>"
        return rel.isEmpty ? base : "\(base)/\(rel)"
    }

    // MARK: - Source selection & reel detection

    func selectSource(_ v: VolumeInfo?) {
        selectedSource = v
        sourceFolder = nil
        detectedReel = nil
        guard let v else { return }
        selectedDestinations.remove(v)
        detectReel(for: v) { [weak self] info in
            guard let self, self.selectedSource == v else { return }
            self.applyReel(info)
        }
    }

    private func detectReel(for v: VolumeInfo, completion: @escaping @MainActor (ReelInfo) -> Void) {
        detecting = true
        Task.detached(priority: .userInitiated) {
            let info = ReelDetector.detect(volume: v)
            await MainActor.run {
                self.detecting = false
                completion(info)
            }
        }
    }

    private func applyReel(_ info: ReelInfo) {
        detectedReel = info
        reel = info.reel
        if let c = info.camera { camera = c }
        jobName = info.reel
        log.log("Detected \(info.system) card: reel \(info.reel)\(info.camera.map { ", camera \($0)" } ?? "")")
    }

    private func handleMount(_ v: VolumeInfo) {
        guard v.isRemovable else { return }
        if selectedDestinations.contains(v) { return }
        log.log("Card mounted: \(v.name) (\(v.totalCapacityFormatted))")
        if settings.autoStart && !selectedDestinations.isEmpty {
            detectReel(for: v) { [weak self] info in
                guard let self else { return }
                var fields = self.currentFields
                fields.reel = info.reel
                if let c = info.camera { fields.camera = c }
                var spec = JobSpec(source: v, destinations: Array(self.selectedDestinations),
                                   jobName: info.reel, naming: fields,
                                   algorithm: self.settings.algorithm, reelInfo: info, autoAdded: true)
                spec.destinationBases = self.destinationBases
                self.log.log("Auto-start: queued \(info.reel) from \(v.name)")
                self.enqueue(spec)
            }
        } else if selectedSource == nil || !isRunning {
            selectSource(v)
        }
    }

    private func handleUnmount(_ url: URL) {
        if selectedSource?.url == url { selectedSource = nil; sourceFolder = nil; detectedReel = nil }
        selectedDestinations = selectedDestinations.filter { $0.url != url }
        destinationBases[url] = nil
        if verifyVolume?.url == url { verifyVolume = nil; availableMHLs = []; selectedMHL = nil }
        queue.removeAll { spec in
            if spec.source.url == url || spec.destinations.contains(where: { $0.url == url }) {
                log.log("Removed \(spec.jobName) from queue — a drive was unplugged", level: .warn)
                return true
            }
            return false
        }
    }

    // MARK: - Folder pickers

    func chooseSourceFolder() {
        guard let v = selectedSource else { return }
        if let u = pickFolder(startingAt: v.url, message: "Choose the folder on \(v.name) to copy (Cancel = whole card)") {
            guard u.path.hasPrefix(v.url.path) else { presentError("Pick a folder on \(v.name)."); return }
            sourceFolder = (u.standardizedFileURL == v.url.standardizedFileURL) ? nil : u
            log.log("Source folder: \(sourceFolder?.path ?? "whole card")")
        }
    }

    func clearSourceFolder() { sourceFolder = nil }

    func chooseDestinationFolder(for v: VolumeInfo) {
        if let u = pickFolder(startingAt: destinationBases[v.url] ?? v.url,
                              message: "Choose the base folder on \(v.name) (the naming template is added below it)") {
            guard u.path.hasPrefix(v.url.path) else { presentError("Pick a folder on \(v.name)."); return }
            destinationBases[v.url] = (u.standardizedFileURL == v.url.standardizedFileURL) ? nil : u
            selectedDestinations.insert(v)
            log.log("Destination folder on \(v.name): \(destinationBases[v.url]?.path ?? "drive root")")
        }
    }

    func clearDestinationFolder(for v: VolumeInfo) { destinationBases[v.url] = nil }

    private func pickFolder(startingAt: URL, message: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = startingAt
        p.message = message
        p.prompt = "Choose"
        return p.runModal() == .OK ? p.url : nil
    }

    // MARK: - Start / queue

    func start() {
        switch mode {
        case .offload:
            guard let source = selectedSource, !selectedDestinations.isEmpty else { return }
            let name = jobName.isEmpty ? (detectedReel?.reel ?? source.name) : jobName
            var spec = JobSpec(source: source, destinations: Array(selectedDestinations),
                               jobName: name, naming: currentFields,
                               algorithm: settings.algorithm, reelInfo: detectedReel)
            spec.sourceFolder = sourceFolder
            spec.destinationBases = destinationBases
            enqueue(spec)
        case .verify:
            startVerify()
        case .speed:
            break
        }
    }

    func enqueue(_ spec: JobSpec) {
        if queue.contains(where: { $0.source.url == spec.source.url }) ||
           (isRunning && job?.source.url == spec.source.url) {
            log.log("\(spec.source.name) is already queued or running", level: .warn)
            return
        }
        queue.append(spec)
        if isRunning { log.log("Queued: \(spec.jobName) (\(queue.count) waiting)") }
        runNextIfIdle()
    }

    func removeFromQueue(_ spec: JobSpec) { queue.removeAll { $0.id == spec.id } }

    private func runNextIfIdle() {
        guard !isRunning, pendingSpec == nil, !queue.isEmpty else { return }
        let spec = queue.removeFirst()
        prepare(spec)
    }

    /// Scan the source, then the duplicate guard and the resume check
    /// (either may prompt and hold the queue), then launch.
    private func prepare(_ spec: JobSpec) {
        pendingSpec = spec
        isRunning = true
        let job = CloneJob(source: spec.source, destinations: spec.destinations, algorithm: spec.algorithm)
        job.spec = spec
        job.destinationFolders = spec.destinations.map { spec.destinationRoot(for: $0) }
        self.job = job
        job.state = .scanning
        log.log("── \(spec.jobName): \(spec.sourceFolder?.lastPathComponent ?? spec.source.name) → "
                + spec.destinations.map { spec.destinationRoot(for: $0).path.replacingOccurrences(of: "/Volumes/", with: "") }
                      .joined(separator: ", "))

        let root = spec.sourceRoot
        Task.detached(priority: .userInitiated) {
            let files = (try? SourceScanner.scan(root: root)) ?? []
            await MainActor.run { self.afterScan(spec: spec, files: files) }
        }
    }

    private func afterScan(spec: JobSpec, files: [ScannedFile]) {
        pendingFiles = files
        let total = SourceScanner.totalBytes(files)
        log.log("Found \(files.count) files, \(VolumeInfo.format(total)).")
        if files.isEmpty {
            log.log("Nothing to copy.", level: .warn)
            abandonPending(); return
        }
        let newest = files.compactMap { $0.modificationDate }.max()
        if let dup = HistoryStore.findDuplicate(reel: spec.naming.reel.isEmpty ? spec.jobName : spec.naming.reel,
                                                fileCount: files.count, totalBytes: total, newestFileDate: newest) {
            duplicateOf = dup
            showDuplicatePrompt = true
            return
        }
        afterDuplicateCheck(spec: spec)
    }

    func duplicateContinue() {
        guard let spec = pendingSpec else { return }
        duplicateOf = nil
        afterDuplicateCheck(spec: spec)
    }

    func duplicateCancel() {
        duplicateOf = nil
        log.log("Skipped \(pendingSpec?.jobName ?? "") — already offloaded.", level: .warn)
        abandonPending()
    }

    private func afterDuplicateCheck(spec: JobSpec) {
        let roots = spec.destinations.map { spec.destinationRoot(for: $0) }
        if let s = SessionStore.find(jobName: spec.jobName, source: spec.source, destinationRoots: roots),
           !s.completed.isEmpty {
            pendingResume = s
            showResumePrompt = true
            return
        }
        launch(spec: spec, files: pendingFiles, resuming: nil)
    }

    func resumePrevious() {
        guard let spec = pendingSpec else { return }
        let s = pendingResume; pendingResume = nil
        launch(spec: spec, files: pendingFiles, resuming: s)
    }

    func startOver() {
        guard let spec = pendingSpec else { return }
        SessionStore.delete(jobName: spec.jobName,
                            destinationRoots: spec.destinations.map { spec.destinationRoot(for: $0) })
        pendingResume = nil
        launch(spec: spec, files: pendingFiles, resuming: nil)
    }

    func cancelPending() {
        pendingResume = nil
        abandonPending()
    }

    private func abandonPending() {
        pendingSpec = nil
        pendingFiles = []
        job = nil
        isRunning = false
        runNextIfIdle()
    }

    // MARK: - Controls

    func pause() {
        guard let j = job, j.state == .copying || j.state == .verifying else { return }
        control.pause(); j.state = .paused
        log.log("⏸ Paused")
    }

    func resume() {
        guard let j = job, j.state == .paused else { return }
        control.resume(); j.state = j.kind == .verifyOnly ? .verifying : .copying
        log.log("▶ Resumed")
    }

    func stop() {
        guard job != nil, isRunning else { return }
        log.log("⏹ Stopping after current chunk…")
        control.cancel()
    }

    func clearFinished() {
        thumbnailTask?.cancel(); thumbnailTask = nil
        if let j = job, !j.state.isActive { job = nil }
        showSummary = false
    }

    func eject(_ v: VolumeInfo) {
        if isRunning, let j = job, j.source.url == v.url || j.destinations.contains(where: { $0.url == v.url }) {
            presentError("\(v.name) is in use by the running job."); return
        }
        do {
            try DriveMonitor.eject(v.url)
            log.log("⏏ Ejected \(v.name)", level: .ok)
        } catch {
            log.log("Could not eject \(v.name): \(error.localizedDescription)", level: .warn)
            presentError("Could not eject \(v.name): \(error.localizedDescription)")
        }
    }

    private func presentError(_ m: String) { errorMessage = m; showError = true }

    /// Free space that works on every file system. The "important usage"
    /// figure is APFS-only and reads as 0 on ExFAT / HFS+ / NTFS.
    static func freeSpace(on volume: URL, fallback: Int64) -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? volume.resourceValues(forKeys: keys) else { return fallback }
        if let imp = v.volumeAvailableCapacityForImportantUsage, imp > 0 { return imp }
        if let plain = v.volumeAvailableCapacity, plain > 0 { return Int64(plain) }
        return fallback
    }

    // MARK: - Sleep prevention

    private func beginActivity() {
        guard settings.preventSleep, sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "SecureClone is offloading media")
    }
    private func endActivity() {
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a); sleepActivity = nil }
    }

    // MARK: - Offload run

    private func launch(spec: JobSpec, files: [ScannedFile], resuming session: CloneSession?) {
        guard let job else { return }
        pendingSpec = nil
        pendingFiles = []
        control = CloneControl()
        beginActivity()
        Task { await run(job: job, spec: spec, files: files, resuming: session) }
    }

    private func run(job: CloneJob, spec: JobSpec, files: [ScannedFile], resuming session: CloneSession?) async {
        let startDate = session?.startedAt ?? Date()
        let destinationRoots = job.destinationFolders
        let control = self.control
        let engine = self.engine
        let algorithm = job.algorithm
        let jobName = spec.jobName
        let settings = self.settings

        do {
            job.totalBytes = SourceScanner.totalBytes(files)
            for root in destinationRoots {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }

            // 1. RESUME records
            var copied: [CopiedFile] = []
            var skip: Set<String> = []
            if let s = session {
                let valid = SessionStore.validRecords(s, destinationRoots: destinationRoots)
                let bySource = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
                for rec in valid {
                    guard let sf = bySource[rec.relativePath], sf.size == rec.size else { continue }
                    var destFiles: [URL: URL] = [:]
                    for root in destinationRoots { destFiles[root] = root.appendingPathComponent(rec.relativePath) }
                    copied.append(CopiedFile(source: sf, sourceHash: rec.sourceHash, destinationFiles: destFiles))
                    skip.insert(rec.relativePath)
                }
                job.resumedFileCount = skip.count
                log.log("↻ Resuming: \(skip.count) files already copied — will be re-verified.")
            }

            // Known hashes from MHLs already in the destination folders.
            var known: [URL: [String: (Int64?, String)]] = [:]
            if settings.skipIdentical {
                for root in destinationRoots { known[root] = MHLReader.knownHashes(in: root, algorithm: algorithm) }
                let n = known.values.map { $0.count }.min() ?? 0
                if n > 0 { log.log("Destination already holds \(n) verified files — identical ones will be skipped.") }
            }

            // 2. BLOCKING free-space check
            let remaining = files.filter { !skip.contains($0.relativePath) }.reduce(Int64(0)) { $0 + $1.size }
            for (dest, root) in zip(job.destinations, destinationRoots) {
                let free = Self.freeSpace(on: dest.url, fallback: dest.availableCapacity)
                _ = root
                if free < remaining {
                    throw NSError(domain: "SecureClone", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Not enough space on \(dest.name): needs \(VolumeInfo.format(remaining)), has \(VolumeInfo.format(free)) — short by \(VolumeInfo.format(remaining - free))"])
                }
            }

            var sessionState = CloneSession(
                jobName: jobName, sourceVolumeName: job.source.name,
                sourceTotalCapacity: job.source.totalCapacity,
                destinationPaths: destinationRoots.map { $0.path },
                algorithm: algorithm.rawValue, startedAt: startDate,
                totalFiles: files.count, totalBytes: job.totalBytes,
                completed: copied.map { SessionRecord(relativePath: $0.source.relativePath, size: $0.source.size,
                                                      modificationDate: $0.source.modificationDate, sourceHash: $0.sourceHash) },
                updatedAt: Date())
            SessionStore.save(sessionState, destinationRoots: destinationRoots)

            // 3. COPY
            job.state = .copying
            job.copyStartedAt = Date()
            let progress = ProgressThrottle()
            progress.add(Int(copied.reduce(0) { $0 + $1.source.size }))
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

                var result: CopiedFile? = nil

                // Skip-identical: every destination already has this file, same
                // size, with an MHL hash that matches the source's hash.
                if settings.skipIdentical, !known.isEmpty {
                    let rel = file.relativePath
                    let size = file.size
                    let sourceURL = file.url
                    let knownSnapshot = known
                    let allKnown = destinationRoots.allSatisfy { root in
                        guard let k = knownSnapshot[root]?[rel] else { return false }
                        let f = root.appendingPathComponent(rel)
                        let onDisk = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
                        return onDisk == size && (k.0 == nil || k.0 == size)
                    }
                    if allKnown {
                        let srcHash = try await Task.detached(priority: .userInitiated) {
                            try ChecksumService.hash(fileAt: sourceURL, algorithm: algorithm)
                        }.value
                        if destinationRoots.allSatisfy({ knownSnapshot[$0]?[rel]?.1 == srcHash }) {
                            var destFiles: [URL: URL] = [:]
                            for root in destinationRoots { destFiles[root] = root.appendingPathComponent(rel) }
                            result = CopiedFile(source: file, sourceHash: srcHash, destinationFiles: destFiles)
                            job.skippedFileCount += 1
                            job.skippedBytes += size
                            progress.add(Int(size))
                            log.log("= \(rel)  identical verified copy exists — skipped")
                        }
                    }
                }

                if result == nil {
                    let r = try await Task.detached(priority: .userInitiated) {
                        try engine.copyFile(source: file, destinationRoots: destinationRoots,
                                            algorithm: algorithm, control: control,
                                            onChunk: { progress.add($0) })
                    }.value
                    result = r
                    log.log("→ \(file.relativePath)  \(VolumeInfo.format(file.size)) in \(CloneJob.formatDuration(r.seconds)) (\(String(format: "%.0f", r.mbps)) MB/s)  [\(r.sourceHash)]")
                }
                guard let done = result else { continue }
                copied.append(done)

                for dp in job.destinationProgress { dp.filesCompleted += 1; dp.bytesCompleted += file.size }

                sessionState.completed.append(SessionRecord(relativePath: file.relativePath, size: file.size,
                                                            modificationDate: file.modificationDate,
                                                            sourceHash: done.sourceHash))
                sessionState.updatedAt = Date()
                SessionStore.save(sessionState, destinationRoots: destinationRoots)
            }

            poller.cancel()
            job.bytesProcessed = job.totalBytes
            job.overallProgress = 1.0
            job.etaSeconds = 0
            if let start = job.copyStartedAt { job.elapsedSeconds = Date().timeIntervalSince(start) }
            log.log("Copy complete in \(job.elapsedText)"
                    + (job.skippedFileCount > 0 ? " (\(job.skippedFileCount) identical files skipped)" : "")
                    + ". Verifying all destinations in parallel…")

            // 4. VERIFY
            job.state = .verifying
            job.currentFile = ""
            job.verifyTotalBytes = job.totalBytes * Int64(max(1, job.destinations.count))
            job.verifyBytesDone = 0
            let verifyProgress = ProgressThrottle()
            job.verifyStartedAt = Date()
            let verifyPoller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    if j.state != .paused { j.recordVerifyProgress(bytes: verifyProgress.snapshot()) }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            let copiedSnapshot = copied
            let outcomes = await Task.detached(priority: .userInitiated) {
                engine.verify(copied: copiedSnapshot, destinationRoots: destinationRoots,
                              algorithm: algorithm, control: control,
                              onBytes: { verifyProgress.add(Int($0)) })
            }.value
            verifyPoller.cancel()
            job.finishVerifyProgress()
            if control.isCancelled { throw CloneEngineError.cancelled }

            for outcome in outcomes {
                var fr = FileResult(relativePath: outcome.relativePath, size: outcome.size)
                fr.sourceHash = outcome.sourceHash
                fr.destinationHashes = outcome.destinationHashes
                fr.verified = outcome.verified
                job.fileResults.append(fr)
                for (dp, root) in zip(job.destinationProgress, destinationRoots) {
                    if let ok = outcome.verified[root] {
                        if ok { dp.verifiedCount += 1 } else { dp.failed = true }
                    }
                }
                if !outcome.allVerified { log.log("✗ MISMATCH \(outcome.relativePath)", level: .error) }
            }

            // 5. METADATA
            log.log("Reading clip metadata…")
            let metaRoot = destinationRoots[0]
            let clips = await MetadataService.metadata(outcomes: outcomes, root: metaRoot)
            job.clips = clips

            // 6. REPORTS
            let finishDate = Date()
            let report = LogWriter.makeReport(jobName: jobName, source: job.source, destinations: job.destinations,
                                              outcomes: outcomes, algorithm: algorithm,
                                              startDate: startDate, finishDate: finishDate,
                                              destinationFolders: destinationRoots, skipped: job.skippedFileCount,
                                              sourceFolder: spec.sourceFolder)
            let csv = CSVReportWriter.make(outcomes: outcomes, metadata: clips, algorithm: algorithm)
            var locations: [URL] = []
            for root in destinationRoots {
                try MHLWriter.write(destinationRoot: root, outcomes: outcomes, algorithm: algorithm,
                                    startDate: startDate, finishDate: finishDate, jobName: jobName)
                let u = try LogWriter.write(report: report, to: root, jobName: jobName, finishDate: finishDate)
                try CSVReportWriter.write(csv: csv, to: root, jobName: jobName, finishDate: finishDate)
                locations.append(u.deletingLastPathComponent())
            }
            log.log("Reports written to \(locations.count) destination\(locations.count == 1 ? "" : "s").")
            if settings.saveReportToSource {
                do {
                    let u = try LogWriter.write(report: report, to: job.source.url, jobName: jobName, finishDate: finishDate)
                    try CSVReportWriter.write(csv: csv, to: job.source.url, jobName: jobName, finishDate: finishDate)
                    locations.append(u.deletingLastPathComponent())
                } catch {
                    log.log("Could not write report to source: \(error.localizedDescription)", level: .warn)
                }
            }

            let ok = job.allDestinationsVerified
            job.state = ok ? .completed : .failed("Verification mismatch")
            job.finalReport = report
            job.reportLocations = locations
            if ok { SessionStore.delete(jobName: jobName, destinationRoots: destinationRoots) }
            log.log(ok ? "✅ \(jobName): ALL DESTINATIONS VERIFIED — SAFE TO WIPE SOURCE"
                       : "❌ \(jobName): VERIFICATION FAILED — DO NOT WIPE SOURCE", level: ok ? .ok : .error)

            // 7. HISTORY + DAY SUMMARY
            HistoryStore.append(HistoryEntry(
                date: finishDate, jobName: jobName,
                reel: spec.naming.reel.isEmpty ? jobName : spec.naming.reel,
                camera: spec.naming.camera.isEmpty ? nil : spec.naming.camera,
                system: spec.reelInfo?.system ?? "Generic",
                sourceName: job.source.name, sourceCapacity: job.source.totalCapacity,
                fileCount: outcomes.count, totalBytes: job.totalBytes,
                destinations: job.destinations.map { $0.name },
                destinationFolders: destinationRoots.map { $0.path },
                verified: ok, durationSeconds: finishDate.timeIntervalSince(startDate),
                appVersion: AppInfo.versionString,
                newestFileDate: files.compactMap { $0.modificationDate }.max()))
            for dest in job.destinations {
                _ = try? DaySummaryWriter.write(for: finishDate, to: dest.url, project: settings.project)
            }
            showSummary = true

            // 8. AUTO-EJECT (source only; thumbnails read from the destination)
            var ejected = false
            if ok && settings.autoEject {
                isRunning = false              // so eject() doesn't refuse
                eject(job.source)
                ejected = true
            }

            // 9. THUMBNAILS (background)
            var extra = Array(destinationRoots.dropFirst())
            if settings.saveReportToSource && !ejected { extra.append(job.source.url) }
            startThumbnailPass(job: job, root: metaRoot, extraRoots: extra, jobName: jobName, finishDate: finishDate)

        } catch CloneEngineError.cancelled {
            job.state = .stopped
            job.currentFile = ""
            log.log("⏹ Stopped. Progress saved — start the same card again to resume.", level: .warn)
        } catch {
            job.state = .failed(error.localizedDescription)
            log.log("ERROR: \(error.localizedDescription)", level: .error)
        }

        finishedJobs.insert(job, at: 0)
        if finishedJobs.count > 50 { finishedJobs.removeLast() }
        isRunning = false
        if queue.isEmpty { endActivity() }
        runNextIfIdle()
    }

    private func startThumbnailPass(job: CloneJob, root: URL, extraRoots: [URL], jobName: String, finishDate: Date) {
        let targets = job.clips.filter {
            let k = MediaKind.of(URL(fileURLWithPath: $0.relativePath)); return k == .video || k == .still
        }
        job.thumbnailsTotal = targets.count
        job.thumbnailsDone = 0
        guard !targets.isEmpty else { return }
        log.log("Generating \(targets.count) thumbnails in the background…")

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self, weak job] in
            let clips = job?.clips ?? []
            await MetadataService.thumbnails(clips: clips, root: root) { path, data in
                guard let job else { return }
                if let i = job.clips.firstIndex(where: { $0.relativePath == path }) { job.clips[i].thumbnailJPEG = data }
                job.thumbnailsDone += 1
            }
            guard !Task.isCancelled, let self, let job else { return }
            var written = 0
            for r in [root] + extraRoots {
                if (try? MetadataService.writeContactSheet(clips: job.clips, to: r, jobName: jobName, finishDate: finishDate)) != nil { written += 1 }
            }
            let missing = job.thumbnailsTotal - job.thumbnailsDone
            self.log.log("Thumbnails: \(job.thumbnailsDone)/\(job.thumbnailsTotal)"
                         + (missing > 0 ? " (\(missing) not decodable — ARRIRAW/RED need Phase 3)" : "")
                         + ". Contact sheet written to \(written) location\(written == 1 ? "" : "s").")
        }
    }

    // MARK: - Verify-only mode

    func selectVerifyVolume(_ v: VolumeInfo?) {
        verifyVolume = v
        availableMHLs = []
        selectedMHL = nil
        guard let v else { return }
        scanningMHLs = true
        Task.detached(priority: .userInitiated) {
            let found = MHLReader.findMHLs(under: v.url)
            await MainActor.run {
                guard self.verifyVolume == v else { return }
                self.availableMHLs = found
                self.selectedMHL = found.first
                self.scanningMHLs = false
                self.log.log("Found \(found.count) MHL\(found.count == 1 ? "" : "s") on \(v.name)")
            }
        }
    }

    func chooseMHLFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "mhl") ?? .xml]
        p.allowsMultipleSelection = false
        p.message = "Choose an MHL manifest to verify against"
        if p.runModal() == .OK, let u = p.url {
            if !availableMHLs.contains(u) { availableMHLs.insert(u, at: 0) }
            selectedMHL = u
        }
    }

    private func startVerify() {
        guard let v = verifyVolume, let mhl = selectedMHL, !isRunning else { return }
        let job = CloneJob(source: v, destinations: [v], algorithm: settings.algorithm, kind: .verifyOnly)
        job.mhlURL = mhl
        self.job = job
        isRunning = true
        control = CloneControl()
        beginActivity()
        Task { await runVerify(job: job, mhlURL: mhl) }
    }

    private func runVerify(job: CloneJob, mhlURL: URL) async {
        let control = self.control
        let start = Date()
        log.log("── Verify \(job.source.name) against \(mhlURL.lastPathComponent)")
        job.state = .scanning

        guard let doc = MHLReader.read(mhlURL) else {
            job.state = .failed("Could not read MHL")
            finishedJobs.insert(job, at: 0); isRunning = false; endActivity(); return
        }
        var algo = job.algorithm
        if let first = doc.entries.first {
            for a in HashAlgorithm.allCases where first.hash(for: a) != nil { algo = a; break }
        }
        let base = doc.baseFolder
        job.totalBytes = doc.totalBytes
        job.verifyTotalBytes = doc.totalBytes
        log.log("MHL: \(doc.entries.count) files, \(VolumeInfo.format(doc.totalBytes)), \(algo.rawValue), written by \(doc.tool ?? "unknown tool")")

        job.state = .verifying
        job.verifyStartedAt = start
        let progress = ProgressThrottle()
        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let j = self.job else { break }
                if j.state != .paused { j.recordVerifyProgress(bytes: progress.snapshot()) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        var okCount = 0, missing = 0, mismatched = 0, noHash = 0
        var problems: [String] = []
        var cancelled = false
        let dp = job.destinationProgress.first

        for e in doc.entries {
            if !control.checkpoint() { cancelled = true; break }
            job.currentFile = e.file
            let url = base.appendingPathComponent(e.file)
            guard let expected = e.hash(for: algo) else { noHash += 1; continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing += 1
                problems.append("MISSING   \(e.file)")
                log.log("✗ missing \(e.file)", level: .error)
                dp?.failed = true
                continue
            }
            let actual = await Task.detached(priority: .userInitiated) {
                (try? ChecksumService.hash(fileAt: url, algorithm: algo)) ?? "READ-ERROR"
            }.value
            progress.add(Int(e.size ?? 0))
            var fr = FileResult(relativePath: e.file, size: e.size ?? 0)
            fr.sourceHash = expected
            fr.destinationHashes = [job.source.url: actual]
            let match = (actual == expected)
            fr.verified = [job.source.url: match]
            job.fileResults.append(fr)
            dp?.filesCompleted += 1
            dp?.bytesCompleted += e.size ?? 0
            if match {
                okCount += 1
                dp?.verifiedCount += 1
            } else {
                mismatched += 1
                dp?.failed = true
                problems.append("MISMATCH  \(e.file)  expected \(expected)  got \(actual)")
                log.log("✗ mismatch \(e.file)", level: .error)
            }
        }
        poller.cancel()
        job.currentFile = ""
        if !cancelled { job.finishVerifyProgress() }

        if cancelled {
            job.state = .stopped
            log.log("⏹ Verification stopped.", level: .warn)
        } else {
            let finish = Date()
            let ok = missing == 0 && mismatched == 0
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var r: [String] = []
            r.append("\(AppInfo.fullName) — Verification Report")
            r.append("=========================================")
            r.append("Drive:      \(job.source.url.path)  (\(job.source.name))")
            r.append("Manifest:   \(mhlURL.path)")
            r.append("Written by: \(doc.tool ?? "unknown")\(doc.finishDate.map { " on \($0)" } ?? "")")
            r.append("Algorithm:  \(algo.rawValue)")
            r.append("Started:    \(df.string(from: start))")
            r.append("Completed:  \(df.string(from: finish))")
            r.append("")
            r.append("Files in manifest: \(doc.entries.count)")
            r.append("Verified OK:       \(okCount)")
            r.append("Mismatched:        \(mismatched)")
            r.append("Missing:           \(missing)")
            if noHash > 0 { r.append("No \(algo.rawValue) hash: \(noHash)") }
            if !problems.isEmpty { r.append(""); r.append("PROBLEMS:"); r.append(contentsOf: problems.map { "  " + $0 }) }
            r.append("")
            r.append("Result:     " + (ok ? "ALL FILES VERIFIED AGAINST MANIFEST" : "VERIFICATION FAILED"))
            let report = r.joined(separator: "\n") + "\n"
            job.finalReport = report
            job.overallProgress = 1
            job.state = ok ? .completed : .failed("\(mismatched) mismatched, \(missing) missing")
            let name = "VERIFY_" + mhlURL.deletingPathExtension().lastPathComponent
            if let u = try? LogWriter.write(report: report, to: job.source.url, jobName: name, finishDate: finish) {
                job.reportLocations = [u.deletingLastPathComponent()]
            }
            log.log(ok ? "✅ Verified: \(okCount)/\(doc.entries.count) files match the manifest"
                       : "❌ Verification failed: \(mismatched) mismatched, \(missing) missing", level: ok ? .ok : .error)
            showSummary = true
        }
        finishedJobs.insert(job, at: 0)
        isRunning = false
        endActivity()
        runNextIfIdle()
    }
}
