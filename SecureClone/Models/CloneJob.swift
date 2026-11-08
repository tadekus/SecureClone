//
//  CloneJob.swift
//  SecureClone
//
//  Models for a cloning operation: the job itself, per-file results,
//  and per-destination verification status.
//

import Foundation

enum JobState: Equatable {
    case idle
    case scanning
    case copying
    case paused
    case verifying
    case completed
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .idle:       return "Ready"
        case .scanning:   return "Scanning source…"
        case .copying:    return "Copying…"
        case .paused:     return "Paused"
        case .verifying:  return "Verifying…"
        case .completed:  return "Completed"
        case .stopped:    return "Stopped — can be resumed"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    var isActive: Bool {
        switch self {
        case .scanning, .copying, .paused, .verifying: return true
        default: return false
        }
    }
}

/// One source file fanned out to N destinations.
struct FileResult: Identifiable {
    let id = UUID()
    let relativePath: String
    let size: Int64
    var sourceHash: String = ""
    /// destination mount URL -> computed hash
    var destinationHashes: [URL: String] = [:]
    /// destination mount URL -> verified (hash matches source)
    var verified: [URL: Bool] = [:]
    /// Full verdict for the mode (includes re-read and byte compare when required).
    var fullyVerified: Bool? = nil

    var allVerified: Bool {
        fullyVerified ?? (!verified.isEmpty && verified.values.allSatisfy { $0 })
    }
}

/// Per-destination running totals, for the UI.
final class DestinationProgress: Identifiable, ObservableObject {
    let id = UUID()
    let volume: VolumeInfo
    @Published var filesCompleted: Int = 0
    @Published var bytesCompleted: Int64 = 0
    @Published var verifiedCount: Int = 0
    @Published var verifiedBytes: Int64 = 0
    @Published var failed: Bool = false

    init(volume: VolumeInfo) { self.volume = volume }
}

enum JobKind { case offload, verifyOnly }

final class CloneJob: ObservableObject, Identifiable {
    let id = UUID()
    let kind: JobKind
    let source: VolumeInfo
    let destinations: [VolumeInfo]
    let algorithm: HashAlgorithm
    let startedAt: Date = Date()
    /// The spec this job was created from (offload jobs).
    var spec: JobSpec? = nil
    /// Actual folders written to, one per destination (root + naming template).
    var destinationFolders: [URL] = []
    /// Files skipped because an identical verified copy already existed.
    var skippedFileCount: Int = 0
    var skippedBytes: Int64 = 0
    /// Verify-only: the MHL being checked.
    var mhlURL: URL? = nil
    var mode: VerificationMode = .standard

    @Published var state: JobState = .idle
    @Published var overallProgress: Double = 0      // 0…1 across all bytes
    @Published var currentFile: String = ""
    @Published var fileResults: [FileResult] = []
    @Published var destinationProgress: [DestinationProgress]

    /// Final human-readable report (shown in the summary sheet on completion).
    @Published var finalReport: String? = nil
    /// Where reports were written, for "Reveal in Finder".
    @Published var reportLocations: [URL] = []
    /// Per-clip metadata + thumbnails (filled after verification).
    @Published var clips: [ClipMetadata] = []
    @Published var thumbnailsDone: Int = 0
    @Published var thumbnailsTotal: Int = 0

    /// Files skipped because a previous session had already copied them.
    var resumedFileCount: Int = 0

    // Live throughput stats (updated by the progress poller).
    @Published var bytesPerSecond: Double = 0       // smoothed source-read speed
    @Published var etaSeconds: Double? = nil        // nil until we have a stable estimate
    @Published var elapsedSeconds: Double = 0

    // Verification phase progress (bytes re-read across ALL destinations),
    // with its own speed / ETA so the stats row stays live while verifying.
    @Published var verifyBytesDone: Int64 = 0
    @Published var verifyBytesPerSecond: Double = 0
    @Published var verifyEtaSeconds: Double? = nil
    @Published var verifyElapsedSeconds: Double = 0
    var verifyTotalBytes: Int64 = 0
    var verifyStartedAt: Date? = nil
    private var verifyLastSampleTime: Date? = nil
    private var verifyLastSampleBytes: Int64 = 0

    // Stall detection: seconds since the byte counter last advanced.
    static let stallThreshold: Double = 15
    @Published var copyStalledSeconds: Double = 0
    @Published var verifyStalledSeconds: Double = 0
    private var copyLastAdvance: (Date, Int64)? = nil
    private var verifyLastAdvance: (Date, Int64)? = nil
    var copyStalled: Bool { copyStalledSeconds >= Self.stallThreshold }
    /// Verification only counts as stalled once it is the active phase; while
    /// copying, the pipelined verifier is simply waiting for the next file.
    var verifyStalled: Bool { verifyStalledSeconds >= Self.stallThreshold && state == .verifying }

    var verifyProgress: Double {
        verifyTotalBytes > 0 ? min(1, Double(verifyBytesDone) / Double(verifyTotalBytes)) : 0
    }
    var verifyPercentText: String { String(format: "%.1f%%", verifyProgress * 100) }
    var verifySpeedText: String {
        if verifyStalled { return "stalled \(Int(verifyStalledSeconds)) s" }
        guard verifyBytesPerSecond > 0 else { return "—" }
        return VolumeInfo.format(Int64(verifyBytesPerSecond)) + "/s"
    }
    var verifyEtaText: String {
        if verifyStalled { return "drive not responding" }
        guard let e = verifyEtaSeconds, verifyBytesPerSecond >= 1_000_000 || e < 36_000 else { return "calculating…" }
        return Self.formatDuration(e)
    }
    var verifyElapsedText: String { Self.formatDuration(verifyElapsedSeconds) }

    func recordVerifyProgress(bytes: Int64, at now: Date = Date()) {
        verifyBytesDone = bytes
        if verifyStartedAt == nil { verifyStartedAt = now }
        verifyElapsedSeconds = now.timeIntervalSince(verifyStartedAt!)
        if let last = verifyLastAdvance, last.1 == bytes {
            verifyStalledSeconds = now.timeIntervalSince(last.0)
        } else {
            verifyLastAdvance = (now, bytes); verifyStalledSeconds = 0
        }
        guard let lastT = verifyLastSampleTime else {
            verifyLastSampleTime = now; verifyLastSampleBytes = bytes; return
        }
        let dt = now.timeIntervalSince(lastT)
        guard dt >= 0.5 else { return }
        let instant = Double(bytes - verifyLastSampleBytes) / dt
        verifyBytesPerSecond = verifyBytesPerSecond == 0 ? instant : (0.7 * verifyBytesPerSecond + 0.3 * instant)
        verifyLastSampleTime = now
        verifyLastSampleBytes = bytes
        let remaining = Double(verifyTotalBytes - bytes)
        verifyEtaSeconds = (verifyBytesPerSecond > 1 && remaining > 0) ? remaining / verifyBytesPerSecond : nil
    }

    func finishVerifyProgress() {
        verifyBytesDone = verifyTotalBytes
        verifyEtaSeconds = 0
        if let s = verifyStartedAt { verifyElapsedSeconds = Date().timeIntervalSince(s) }
    }

    var totalBytes: Int64 = 0
    var bytesProcessed: Int64 = 0

    /// When the copy phase actually began (after scanning).
    var copyStartedAt: Date? = nil
    private var lastSampleTime: Date? = nil
    private var lastSampleBytes: Int64 = 0

    init(source: VolumeInfo, destinations: [VolumeInfo], algorithm: HashAlgorithm,
         kind: JobKind = .offload) {
        self.kind = kind
        self.source = source
        self.destinations = destinations
        self.algorithm = algorithm
        self.destinationProgress = destinations.map { DestinationProgress(volume: $0) }
    }

    var title: String {
        spec?.jobName ?? (kind == .verifyOnly ? "Verify \(source.name)" : source.name)
    }

    var allDestinationsVerified: Bool {
        !fileResults.isEmpty && fileResults.allSatisfy { $0.allVerified }
    }

    // MARK: - Throughput

    /// Feed a new byte count; computes speed (exponentially smoothed) and ETA.
    func recordProgress(bytes: Int64, at now: Date = Date()) {
        bytesProcessed = bytes
        if totalBytes > 0 {
            overallProgress = min(1.0, Double(bytes) / Double(totalBytes))
        }
        if let start = copyStartedAt {
            elapsedSeconds = now.timeIntervalSince(start)
        }
        if let last = copyLastAdvance, last.1 == bytes {
            copyStalledSeconds = now.timeIntervalSince(last.0)
        } else {
            copyLastAdvance = (now, bytes); copyStalledSeconds = 0
        }

        guard let lastT = lastSampleTime else {
            lastSampleTime = now
            lastSampleBytes = bytes
            return
        }
        let dt = now.timeIntervalSince(lastT)
        guard dt >= 0.5 else { return }            // sample at most ~2×/sec

        let instant = Double(bytes - lastSampleBytes) / dt
        // Exponential moving average so the number doesn't jitter.
        bytesPerSecond = bytesPerSecond == 0 ? instant : (0.7 * bytesPerSecond + 0.3 * instant)
        lastSampleTime = now
        lastSampleBytes = bytes

        let remaining = Double(totalBytes - bytes)
        etaSeconds = (bytesPerSecond > 1 && remaining > 0) ? remaining / bytesPerSecond : nil
    }

    var percentText: String {
        String(format: "%.1f%%", overallProgress * 100)
    }

    var speedText: String {
        if copyStalled { return "stalled \(Int(copyStalledSeconds)) s" }
        guard bytesPerSecond > 0 else { return "—" }
        return VolumeInfo.format(Int64(bytesPerSecond)) + "/s"
    }

    var etaText: String {
        if copyStalled { return "drive not responding" }
        guard let eta = etaSeconds, bytesPerSecond >= 1_000_000 || eta < 36_000 else { return "calculating…" }
        return Self.formatDuration(eta)
    }

    var elapsedText: String { Self.formatDuration(elapsedSeconds) }

    static func formatDuration(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
