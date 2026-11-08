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
    @Published var availableUpdate: UpdateInfo? = nil
    @Published var showUpdatePrompt = false
    @Published var remoteRunning = false

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

        if settings.notifications { Notifier.requestPermission() }
        if settings.checkUpdates,
           settings.lastUpdateCheck.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
            checkForUpdates(manual: false)
        }

        if let r = ActiveRunStore.takeLeftover() {
            let when = DateFormatter.localizedString(from: r.updatedAt, dateStyle: .short, timeStyle: .short)
            log.log("⚠️ The previous run of \"\(r.jobName)\" (\(r.sourceName) → \(r.destinations.joined(separator: ", "))) was interrupted at \(when) while \(r.phase): "
                    + "\(r.copiedFiles)/\(r.totalFiles) files copied, \(r.verifiedFiles) verified. "
                    + "Nothing from that run is proven safe — start the card again (it will resume).", level: .error)
            HistoryStore.append(HistoryEntry(date: r.updatedAt, jobName: r.jobName, reel: r.jobName, camera: nil,
                                             system: "Interrupted", sourceName: r.sourceName, sourceCapacity: r.sourceCapacity,
                                             fileCount: r.copiedFiles, totalBytes: 0, destinations: r.destinations,
                                             destinationFolders: r.destinationFolders, verified: false,
                                             durationSeconds: r.updatedAt.timeIntervalSince(r.startedAt),
                                             appVersion: r.appVersion, newestFileDate: nil))
        }
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
        let includeAD = settings.copyAppleDouble
        let allowSame = settings.allowSamePhysicalDisk
        let folders = job.destinationFolders
        Task.detached(priority: .userInitiated) {
            let files = (try? SourceScanner.scan(root: root, includeAppleDouble: includeAD)) ?? []
            let problems = SafetyValidator.check(source: spec.source, sourceFolder: spec.sourceFolder,
                                                 destinations: spec.destinations, destinationFolders: folders,
                                                 files: files, allowSamePhysicalDisk: allowSame)
            await MainActor.run { self.afterScan(spec: spec, files: files, problems: problems) }
        }
    }

    private func afterScan(spec: JobSpec, files: [ScannedFile], problems: [SafetyProblem]) {
        pendingFiles = files
        let total = SourceScanner.totalBytes(files)
        let ad = files.filter { $0.isAppleDouble }.count
        log.log("Found \(files.count) files, \(VolumeInfo.format(total))." + (ad > 0 ? " (\(ad) ._ sidecars included)" : ""))

        // Link speed warnings.
        for v in [spec.source] + spec.destinations {
            if let c = v.connection, c.isSlowLink {
                log.log("⚠️ \(v.name) is on a \(c.label) link — expect ≤ \(c.linkCeilingMBps ?? 40) MB/s.", level: .warn)
            }
        }

        // Safety.
        for p in problems where p.severity == .warn { log.log("⚠️ \(p.message)", level: .warn) }
        let refusals = problems.filter { $0.severity == .refuse }
        if !refusals.isEmpty {
            for p in refusals { log.log("⛔ \(p.message)", level: .error) }
            presentError("This job can't start:\n\n" + refusals.map { "• " + $0.message }.joined(separator: "\n"))
            abandonPending(); return
        }

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
    static func failureReason(_ outcome: FileCloneOutcome) -> String {
        var why: [String] = []
        if outcome.verified.values.contains(false) { why.append("hash mismatch") }
        if outcome.sourceRereadOK == false { why.append("card re-read differs — unreliable card read") }
        if outcome.byteCompareOK.values.contains(false) { why.append("byte compare differs") }
        if why.isEmpty { why.append("not verified") }
        return why.joined(separator: "; ")
    }

    enum SpotlightResult { case created, existed, failed(String) }

    /// Create `.metadata_never_index` at the volume root so Spotlight leaves
    /// the freshly written media alone while we read it back.
    static func preventSpotlightIndexing(on volume: URL) -> SpotlightResult {
        let marker = volume.appendingPathComponent(".metadata_never_index")
        if FileManager.default.fileExists(atPath: marker.path) { return .existed }
        do {
            try Data().write(to: marker)
            return .created
        } catch {
            return .failed(error.localizedDescription)
        }
    }

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
        let mode = settings.verificationMode
        job.mode = mode

        var journal = ActiveRun(jobName: jobName, sourceName: job.source.name, sourceCapacity: job.source.totalCapacity,
                                destinations: job.destinations.map { $0.name },
                                destinationFolders: destinationRoots.map { $0.path },
                                mode: mode.rawValue, startedAt: startDate, phase: "copying",
                                totalFiles: files.count, copiedFiles: 0, verifiedFiles: 0, currentFile: "",
                                updatedAt: Date(), appVersion: AppInfo.versionString,
                                pid: ProcessInfo.processInfo.processIdentifier)
        ActiveRunStore.write(journal)
        log.log("Verification mode: \(mode.rawValue) — \(mode.summary)")

        do {
            job.totalBytes = SourceScanner.totalBytes(files)
            for root in destinationRoots {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let n = CloneEngine.removePartials(under: root)
                if n > 0 { log.log("Removed \(n) leftover partial file\(n == 1 ? "" : "s") on \(root.lastPathComponent)", level: .warn) }
            }
            if settings.preventSpotlight {
                for dest in job.destinations {
                    switch Self.preventSpotlightIndexing(on: dest.url) {
                    case .created: log.log("Spotlight indexing disabled on \(dest.name) (.metadata_never_index)")
                    case .existed: break
                    case .failed(let e): log.log("Could not disable Spotlight on \(dest.name): \(e) — if verification stalls, run: mdutil -i off \"\(dest.url.path)\"", level: .warn)
                    }
                }
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
                var wasStalled = false
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    if j.state != .paused {
                        j.recordProgress(bytes: progress.snapshot())
                        if j.copyStalled != wasStalled {
                            wasStalled = j.copyStalled
                            if wasStalled {
                                self.log.log("⚠ No data written for \(Int(CloneJob.stallThreshold)) s during \(j.currentFile) — a destination drive stopped accepting writes (SSD cache flush / thermal throttling / Spotlight indexing?)", level: .warn)
                            } else {
                                self.log.log("▶ Writes resumed")
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { poller.cancel() }

            // Verification progress (started now when pipelined, else after the copy).
            var passes = Int64(max(1, job.destinations.count))
            if mode.rereadsSource { passes += 1 }
            if mode.byteCompare { passes += Int64(2 * max(1, job.destinations.count)) }
            job.verifyTotalBytes = job.totalBytes * passes
            job.verifyBytesDone = 0
            let verifyProgress = ProgressThrottle()
            let verifiedCounter = ProgressThrottle()
            let verifyPoller = Task { @MainActor [weak self] in
                var wasStalled = false
                while !Task.isCancelled {
                    guard let self, let j = self.job else { break }
                    if j.state != .paused {
                        j.recordVerifyProgress(bytes: verifyProgress.snapshot())
                        if j.verifyStalled != wasStalled {
                            wasStalled = j.verifyStalled
                            if wasStalled {
                                self.log.log("⚠ No data read for \(Int(CloneJob.stallThreshold)) s during verification — a drive stopped responding (SSD cache folding / thermal throttling / Spotlight indexing?)", level: .warn)
                            } else {
                                self.log.log("▶ Reads resumed")
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { verifyPoller.cancel() }

            let pipelined = settings.pipelinedVerify && mode.hashes
            var verifier: PipelinedVerifier? = nil
            if pipelined {
                job.verifyStartedAt = Date()
                verifier = PipelinedVerifier(
                    engine: engine, roots: destinationRoots, algorithm: algorithm, mode: mode, control: control,
                    onBytes: { verifyProgress.add(Int($0)) },
                    onFileDone: { [weak self] outcome, seconds in
                        if outcome.allVerified { verifiedCounter.add(1) }
                        Task { @MainActor [weak self] in
                            guard let self, let j = self.job else { return }
                            for (dp, root) in zip(j.destinationProgress, destinationRoots) {
                                guard let ok = outcome.verified[root] else { continue }
                                dp.verifiedBytes += outcome.size
                                if ok && (outcome.byteCompareOK[root] ?? true) { dp.verifiedCount += 1 } else { dp.failed = true }
                            }
                            let perDrive = seconds > 0 ? Double(outcome.size) / seconds / 1_000_000 : 0
                            if outcome.allVerified {
                                self.log.log("✓ \(outcome.relativePath)  verified \(VolumeInfo.format(outcome.size)) in \(CloneJob.formatDuration(seconds)) (\(String(format: "%.0f", perDrive)) MB/s per drive)")
                            } else {
                                self.log.log("✗ FAILED \(outcome.relativePath): \(Self.failureReason(outcome))", level: .error)
                            }
                        }
                    })
                // Resumed / already-present files are verified first.
                for c in copied { verifier?.submit(c) }
                log.log("Pipelined verification on: each file is read back while the next one copies.")
            }

            // Slow-file hints: compare each file's copy speed with the running median.
            var speedSamples: [Double] = []

            for file in files where !skip.contains(file.relativePath) {
                if control.isCancelled { throw CloneEngineError.cancelled }
                job.currentFile = file.relativePath

                var result: CopiedFile? = nil

                // Skip-identical: every destination already has this file with the
                // same size and either an MHL hash or (fallback) a freshly computed
                // hash of the copy that matches the source's hash.
                if settings.skipIdentical, mode.hashes {
                    let rel = file.relativePath
                    let size = file.size
                    let sourceURL = file.url
                    let knownSnapshot = known
                    let existsEverywhere = destinationRoots.allSatisfy { root in
                        let f = root.appendingPathComponent(rel)
                        let onDisk = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
                        return onDisk == size
                    }
                    if existsEverywhere {
                        // Hash the source once; take each copy's hash from its MHL or compute it.
                        let srcHash = try await Task.detached(priority: .userInitiated) {
                            try ChecksumService.hash(fileAt: sourceURL, algorithm: algorithm)
                        }.value
                        var destHashes: [URL: String] = [:]
                        for root in destinationRoots {
                            if let k = knownSnapshot[root]?[rel], k.0 == nil || k.0 == size {
                                destHashes[root] = k.1
                            } else {
                                let f = root.appendingPathComponent(rel)
                                destHashes[root] = (try? await Task.detached(priority: .userInitiated) {
                                    try ChecksumService.hash(fileAt: f, algorithm: algorithm)
                                }.value) ?? ""
                            }
                        }
                        if destinationRoots.allSatisfy({ destHashes[$0] == srcHash }) {
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
                                            algorithm: algorithm, mode: mode, control: control,
                                            onChunk: { progress.add($0) })
                    }.value
                    result = r
                    var line = "→ \(file.relativePath)  \(VolumeInfo.format(file.size)) in \(CloneJob.formatDuration(r.seconds)) (\(String(format: "%.0f", r.mbps)) MB/s)  [\(r.sourceHash)]"
                    var slow = false
                    if file.size >= 256 * 1024 * 1024, r.mbps > 0 {
                        if speedSamples.count >= 3 {
                            let median = speedSamples.sorted()[speedSamples.count / 2]
                            if r.mbps < 0.4 * median {
                                slow = true
                                line += "  ⚠ slow: \(String(format: "%.0f", 100 * r.mbps / median))% of the job's typical \(String(format: "%.0f", median)) MB/s — drive cache exhausted or throttling?"
                            }
                        }
                        speedSamples.append(r.mbps)
                    }
                    log.log(line, level: slow ? .warn : .info)
                }
                guard let done = result else { continue }
                copied.append(done)
                verifier?.submit(done)

                for dp in job.destinationProgress { dp.filesCompleted += 1; dp.bytesCompleted += file.size }

                sessionState.completed.append(SessionRecord(relativePath: file.relativePath, size: file.size,
                                                            modificationDate: file.modificationDate,
                                                            sourceHash: done.sourceHash))
                sessionState.updatedAt = Date()
                SessionStore.save(sessionState, destinationRoots: destinationRoots)
                journal.copiedFiles += 1; journal.currentFile = file.relativePath; journal.updatedAt = Date()
                ActiveRunStore.write(journal)
            }

            poller.cancel()
            job.bytesProcessed = job.totalBytes
            job.overallProgress = 1.0
            job.etaSeconds = 0
            if let start = job.copyStartedAt { job.elapsedSeconds = Date().timeIntervalSince(start) }
            log.log("Copy complete in \(job.elapsedText)"
                    + (job.skippedFileCount > 0 ? " (\(job.skippedFileCount) identical files skipped)" : "")
                    + (pipelined ? ". Finishing verification of the remaining files…" : ". Verifying all destinations in parallel…"))

            // 4. VERIFY
            job.state = .verifying
            job.currentFile = ""
            if job.verifyStartedAt == nil { job.verifyStartedAt = Date() }
            journal.phase = "verifying"; journal.updatedAt = Date(); ActiveRunStore.write(journal)
            let outcomes: [FileCloneOutcome]
            if let v = verifier {
                outcomes = await v.drain()
            } else {
                let copiedSnapshot = copied
                outcomes = await Task.detached(priority: .userInitiated) {
                    engine.verify(copied: copiedSnapshot, destinationRoots: destinationRoots,
                                  algorithm: algorithm, mode: mode, control: control,
                                  onFileVerified: { _, _, ok in if ok { verifiedCounter.add(1) } },
                                  onBytes: { verifyProgress.add(Int($0)) })
                }.value
            }
            journal.verifiedFiles = Int(verifiedCounter.snapshot()); journal.phase = "reporting"; ActiveRunStore.write(journal)
            verifyPoller.cancel()
            job.finishVerifyProgress()
            if control.isCancelled { throw CloneEngineError.cancelled }

            for outcome in outcomes {
                var fr = FileResult(relativePath: outcome.relativePath, size: outcome.size)
                fr.sourceHash = outcome.sourceHash
                fr.destinationHashes = outcome.destinationHashes
                fr.verified = outcome.verified
                fr.fullyVerified = outcome.allVerified
                job.fileResults.append(fr)
                if !pipelined {
                    for (dp, root) in zip(job.destinationProgress, destinationRoots) {
                        if let ok = outcome.verified[root] {
                            dp.verifiedBytes += outcome.size
                            if ok { dp.verifiedCount += 1 } else { dp.failed = true }
                        }
                    }
                    if !outcome.allVerified && mode.hashes {
                        log.log("✗ FAILED \(outcome.relativePath): \(Self.failureReason(outcome))", level: .error)
                    }
                }
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
                                              sourceFolder: spec.sourceFolder, mode: mode)
            let csv = CSVReportWriter.make(outcomes: outcomes, metadata: clips, algorithm: algorithm)
            var locations: [URL] = []
            let okForReports = mode.hashes && job.allDestinationsVerified
            let jsonReport = JSONReportWriter.make(jobName: jobName, source: job.source, sourceFolder: spec.sourceFolder,
                                                   destinations: job.destinations, destinationFolders: destinationRoots,
                                                   outcomes: outcomes, metadata: clips, algorithm: algorithm, mode: mode,
                                                   startDate: startDate, finishDate: finishDate,
                                                   skipped: job.skippedFileCount, verified: okForReports)
            for root in destinationRoots {
                if mode.hashes {
                    try MHLWriter.write(destinationRoot: root, outcomes: outcomes, algorithm: algorithm,
                                        startDate: startDate, finishDate: finishDate, jobName: jobName)
                    if settings.writeASCMHL && okForReports {
                        do { try ASCMHLWriter.write(root: root, outcomes: outcomes, algorithm: algorithm,
                                                    startDate: startDate, finishDate: finishDate, jobName: jobName) }
                        catch { log.log("ASC MHL not written on \(root.lastPathComponent): \(error.localizedDescription)", level: .warn) }
                    }
                }
                let u = try LogWriter.write(report: report, to: root, jobName: jobName, finishDate: finishDate)
                try CSVReportWriter.write(csv: csv, to: root, jobName: jobName, finishDate: finishDate)
                if settings.writeJSON { try? JSONReportWriter.write(jsonReport, to: root, jobName: jobName, finishDate: finishDate) }
                if settings.writePDF {
                    do { try PDFReportWriter.writeJob(to: root, jobName: jobName, finishDate: finishDate,
                                                      source: job.source, sourceFolder: spec.sourceFolder,
                                                      destinations: job.destinations, destinationFolders: destinationRoots,
                                                      outcomes: outcomes, clips: clips, algorithm: algorithm, mode: mode,
                                                      startDate: startDate, skipped: job.skippedFileCount, verified: okForReports) }
                    catch { log.log("PDF not written on \(root.lastPathComponent): \(error.localizedDescription)", level: .warn) }
                }
                locations.append(u.deletingLastPathComponent())
            }
            log.log("Reports written to \(locations.count) destination\(locations.count == 1 ? "" : "s").")
            if settings.saveReportToSource {
                do {
                    let u = try LogWriter.write(report: report, to: job.source.url, jobName: jobName, finishDate: finishDate)
                    try CSVReportWriter.write(csv: csv, to: job.source.url, jobName: jobName, finishDate: finishDate)
                    if settings.writePDF {
                        try? PDFReportWriter.writeJob(to: job.source.url, jobName: jobName, finishDate: finishDate,
                                                      source: job.source, sourceFolder: spec.sourceFolder,
                                                      destinations: job.destinations, destinationFolders: destinationRoots,
                                                      outcomes: outcomes, clips: clips, algorithm: algorithm, mode: mode,
                                                      startDate: startDate, skipped: job.skippedFileCount, verified: okForReports)
                    }
                    locations.append(u.deletingLastPathComponent())
                } catch {
                    log.log("Could not write report to source: \(error.localizedDescription)", level: .warn)
                }
            }

            let ok = mode.hashes && job.allDestinationsVerified
            job.state = ok ? .completed : (mode.hashes ? .failed("Verification mismatch") : .completed)
            job.finalReport = report
            job.reportLocations = locations
            if ok { SessionStore.delete(jobName: jobName, destinationRoots: destinationRoots) }
            if !mode.hashes {
                log.log("⚠️ \(jobName): copied in Quick mode — NOT VERIFIED, do not wipe the source on this alone", level: .warn)
            } else {
                log.log(ok ? "✅ \(jobName): ALL DESTINATIONS VERIFIED (\(mode.rawValue)) — SAFE TO WIPE SOURCE"
                           : "❌ \(jobName): VERIFICATION FAILED — DO NOT WIPE SOURCE", level: ok ? .ok : .error)
            }

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
                if settings.writePDF { _ = try? PDFReportWriter.writeDay(for: finishDate, to: dest.url, project: settings.project) }
            }
            showSummary = true
            if settings.notifications {
                Notifier.post(title: ok ? "\(jobName) verified" : (mode.hashes ? "\(jobName) FAILED verification" : "\(jobName) copied (not verified)"),
                              body: "\(outcomes.count) files, \(VolumeInfo.format(job.totalBytes)) → \(job.destinations.map { $0.name }.joined(separator: ", "))"
                                    + (ok ? " — safe to wipe the card" : ""))
            }
            if ok && settings.remoteEnabled && !settings.remoteTarget.isEmpty {
                startRemoteBackup(folder: destinationRoots[0], relative: spec.relativeFolder.isEmpty ? jobName : spec.relativeFolder)
            }

            // 8. AUTO-EJECT (source only; thumbnails read from the destination)
            var ejected = false
            ActiveRunStore.clear()
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
            ActiveRunStore.clear()
            log.log("⏹ Stopped. Progress saved — start the same card again to resume.", level: .warn)
        } catch {
            job.state = .failed(error.localizedDescription)
            ActiveRunStore.clear()
            log.log("ERROR: \(error.localizedDescription)", level: .error)
        }

        finishedJobs.insert(job, at: 0)
        if finishedJobs.count > 50 { finishedJobs.removeLast() }
        isRunning = false
        if queue.isEmpty { endActivity() }
        runNextIfIdle()
    }

    // MARK: - Off-site copy

    private func startRemoteBackup(folder: URL, relative: String) {
        let target = settings.remoteTarget
        let identity = settings.remoteIdentity
        let bw = settings.remoteBandwidthKBps
        let control = CloneControl()
        remoteRunning = true
        log.log("☁️ Off-site copy → \(target)/\(relative) (rsync over SSH)…")
        Task.detached(priority: .utility) { [weak self] in
            var lastPosted = Date.distantPast
            let r = RemoteBackup.run(folder: folder, relative: relative, target: target, identity: identity,
                                     bandwidthKBps: bw, control: control) { line in
                // rsync --info=progress2 emits many lines; post one every few seconds.
                if Date().timeIntervalSince(lastPosted) > 3 || line.lowercased().contains("error") || line.contains("rsync:") {
                    lastPosted = Date()
                    Task { @MainActor in self?.log.log("   ☁️ \(line)") }
                }
            }
            await MainActor.run {
                self?.remoteRunning = false
                self?.log.log(r.ok ? "☁️ Off-site copy complete in \(CloneJob.formatDuration(r.seconds))"
                                   : "☁️ Off-site copy FAILED: \(r.lastLine)", level: r.ok ? .ok : .error)
                if self?.settings.notifications == true {
                    Notifier.post(title: r.ok ? "Off-site copy complete" : "Off-site copy failed", body: "\(relative) → \(target)", sound: false)
                }
            }
        }
    }

    func testRemote() {
        let target = settings.remoteTarget, id = settings.remoteIdentity
        log.log("Testing SSH connection to \(target)…")
        Task.detached { [weak self] in
            let (ok, msg) = RemoteBackup.test(target: target, identity: id)
            await MainActor.run {
                self?.log.log(ok ? "SSH connection OK" : "SSH connection failed: \(msg)", level: ok ? .ok : .error)
                if !ok { self?.presentError("SSH connection failed:\n\(msg)\n\nThe target must be user@host:/path and your SSH key must be accepted without a password.") }
            }
        }
    }

    // MARK: - Updates

    func checkForUpdates(manual: Bool) {
        Task { [weak self] in
            guard let self else { return }
            self.settings.lastUpdateCheck = Date()
            if let info = await UpdateChecker.check() {
                if UpdateChecker.isNewer(info) {
                    self.availableUpdate = info
                    self.showUpdatePrompt = true
                    self.log.log("Update available: \(info.version) (build \(info.build))")
                } else if manual {
                    self.log.log("You're up to date (\(AppInfo.versionString)).", level: .ok)
                    self.presentError("You're running the latest version (\(AppInfo.versionString)).")
                }
            } else if manual {
                self.presentError("Could not reach GitHub to check for updates.")
            }
        }
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
