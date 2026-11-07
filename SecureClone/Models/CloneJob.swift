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
    case verifying
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .idle:       return "Ready"
        case .scanning:   return "Scanning source…"
        case .copying:    return "Copying…"
        case .verifying:  return "Verifying…"
        case .completed:  return "Completed"
        case .failed(let m): return "Failed: \(m)"
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

    var allVerified: Bool {
        !verified.isEmpty && verified.values.allSatisfy { $0 }
    }
}

/// Per-destination running totals, for the UI.
final class DestinationProgress: Identifiable, ObservableObject {
    let id = UUID()
    let volume: VolumeInfo
    @Published var filesCompleted: Int = 0
    @Published var bytesCompleted: Int64 = 0
    @Published var verifiedCount: Int = 0
    @Published var failed: Bool = false

    init(volume: VolumeInfo) { self.volume = volume }
}

final class CloneJob: ObservableObject, Identifiable {
    let id = UUID()
    let source: VolumeInfo
    let destinations: [VolumeInfo]
    let algorithm: HashAlgorithm
    let startedAt: Date = Date()

    @Published var state: JobState = .idle
    @Published var overallProgress: Double = 0      // 0…1 across all bytes
    @Published var currentFile: String = ""
    @Published var fileResults: [FileResult] = []
    @Published var destinationProgress: [DestinationProgress]

    // Live throughput stats (updated by the progress poller).
    @Published var bytesPerSecond: Double = 0       // smoothed source-read speed
    @Published var etaSeconds: Double? = nil        // nil until we have a stable estimate
    @Published var elapsedSeconds: Double = 0

    // Verification phase progress (bytes re-read across ALL destinations).
    @Published var verifyBytesDone: Int64 = 0
    var verifyTotalBytes: Int64 = 0
    var verifyProgress: Double {
        verifyTotalBytes > 0 ? min(1, Double(verifyBytesDone) / Double(verifyTotalBytes)) : 0
    }

    var totalBytes: Int64 = 0
    var bytesProcessed: Int64 = 0

    /// When the copy phase actually began (after scanning).
    var copyStartedAt: Date? = nil
    private var lastSampleTime: Date? = nil
    private var lastSampleBytes: Int64 = 0

    init(source: VolumeInfo, destinations: [VolumeInfo], algorithm: HashAlgorithm) {
        self.source = source
        self.destinations = destinations
        self.algorithm = algorithm
        self.destinationProgress = destinations.map { DestinationProgress(volume: $0) }
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
        guard bytesPerSecond > 0 else { return "—" }
        return VolumeInfo.format(Int64(bytesPerSecond)) + "/s"
    }

    var etaText: String {
        guard let eta = etaSeconds else { return "calculating…" }
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
