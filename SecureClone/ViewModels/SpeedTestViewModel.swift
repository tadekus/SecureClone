//
//  SpeedTestViewModel.swift
//  SecureClone
//
//  Runs the speed test over the selected volumes and publishes results:
//  per-volume read/write, an estimated transfer matrix (min(read A, write B)),
//  and optional real transfer measurements from one source.
//

import Foundation
import Combine

@MainActor
final class SpeedTestViewModel: ObservableObject {

    enum TestSize: Int64, CaseIterable, Identifiable {
        case mb256 = 268_435_456, gb1 = 1_073_741_824, gb4 = 4_294_967_296
        var id: Int64 { rawValue }
        var label: String {
            switch self {
            case .mb256: return "256 MB"
            case .gb1:   return "1 GB"
            case .gb4:   return "4 GB"
            }
        }
    }

    @Published var selected: Set<VolumeInfo> = []
    @Published var transferSource: VolumeInfo? = nil
    @Published var size: TestSize = .gb1
    @Published var realTransfer = true

    @Published var results: [SpeedResult] = []
    @Published var transfers: [TransferResult] = []
    @Published var isRunning = false
    @Published var currentStep = ""
    @Published var stepProgress: Double = 0
    @Published var finishedAt: Date? = nil

    private var control = CloneControl()
    let log: LogStore

    init(log: LogStore) { self.log = log }

    var canRun: Bool { !selected.isEmpty && !isRunning }

    /// Estimated A→B speed: the slower of A's read and B's write.
    func estimate(from a: VolumeInfo, to b: VolumeInfo) -> Double? {
        guard let r = results.first(where: { $0.volume == a })?.readMBps,
              let w = results.first(where: { $0.volume == b })?.writeMBps else { return nil }
        return min(r, w)
    }

    func stop() { control.cancel() }

    func run() {
        guard canRun else { return }
        let volumes = selected.sorted { $0.name < $1.name }
        let bytes = size.rawValue
        var source: VolumeInfo? = nil
        if let t = transferSource, selected.contains(t) { source = t }
        else { source = volumes.first(where: { $0.isRemovable }) }
        let doTransfer = realTransfer
        control = CloneControl()
        let control = self.control
        isRunning = true
        finishedAt = nil
        results = volumes.map { SpeedResult(volume: $0, readOnly: SpeedTestService.isReadOnly($0)) }
        transfers = []
        log.log("── Speed test: \(volumes.map { $0.name }.joined(separator: ", ")) (\(size.label) each)")

        Task {
            for (i, v) in volumes.enumerated() {
                if control.isCancelled { break }
                let readOnly = results[i].readOnly
                let free = v.availableCapacity

                // WRITE
                if !readOnly {
                    if free < bytes + 64 * 1024 * 1024 {
                        results[i].error = "Not enough free space for a \(size.label) test file"
                    } else {
                        currentStep = "Writing \(size.label) to \(v.name)…"
                        let r = await Task.detached(priority: .userInitiated) { () -> Result<Double, Error> in
                            do { return .success(try SpeedTestService.testWrite(v, bytes: bytes, control: control,
                                                                                 progress: { p in Task { @MainActor in self.stepProgress = p } })) }
                            catch { return .failure(error) }
                        }.value
                        switch r {
                        case .success(let s): results[i].writeMBps = s; log.log("\(v.name) write: \(Self.fmt(s))")
                        case .failure(let e): if (e as? CloneEngineError) != nil { break }; results[i].error = e.localizedDescription
                        }
                    }
                } else {
                    results[i].note = "Read-only — write test skipped"
                }
                if control.isCancelled { break }

                // READ
                currentStep = "Reading \(size.label) from \(v.name)…"
                stepProgress = 0
                let rr = await Task.detached(priority: .userInitiated) { () -> Result<(Double, String?), Error> in
                    do {
                        if readOnly || (free < bytes + 64 * 1024 * 1024) {
                            let (s, n) = try SpeedTestService.testReadExisting(v, bytes: bytes, control: control,
                                                                               progress: { p in Task { @MainActor in self.stepProgress = p } })
                            return .success((s, n < bytes ? "read \(VolumeInfo.format(n)) of existing files" : "read existing files"))
                        } else {
                            return .success((try SpeedTestService.testReadWritable(v, bytes: bytes, control: control,
                                                                                    progress: { p in Task { @MainActor in self.stepProgress = p } }), nil))
                        }
                    } catch { return .failure(error) }
                }.value
                switch rr {
                case .success(let pair):
                    let (s, note) = pair
                    results[i].readMBps = s
                    if let n = note { results[i].note = (results[i].note.map { $0 + "; " } ?? "") + n }
                    log.log("\(v.name) read: \(Self.fmt(s))")
                case .failure(let e):
                    if (e as? CloneEngineError) == nil { results[i].error = e.localizedDescription }
                }
            }

            // REAL TRANSFER from the source to each writable other volume
            if doTransfer, !control.isCancelled, let src = source {
                for v in volumes where v != src && !SpeedTestService.isReadOnly(v) {
                    if control.isCancelled { break }
                    currentStep = "Transfer \(src.name) → \(v.name)…"
                    stepProgress = 0
                    var t = TransferResult(from: src, to: v)
                    let r = await Task.detached(priority: .userInitiated) { () -> Result<Double, Error> in
                        do { return .success(try SpeedTestService.testTransfer(from: src, to: v, bytes: bytes, control: control,
                                                                                progress: { p in Task { @MainActor in self.stepProgress = p } })) }
                        catch { return .failure(error) }
                    }.value
                    switch r {
                    case .success(let s): t.mbps = s; log.log("Transfer \(src.name) → \(v.name): \(Self.fmt(s))")
                    case .failure(let e): if (e as? CloneEngineError) == nil { t.error = e.localizedDescription }
                    }
                    transfers.append(t)
                }
            }

            currentStep = control.isCancelled ? "Stopped" : "Done"
            stepProgress = 1
            isRunning = false
            finishedAt = Date()
            log.log(control.isCancelled ? "Speed test stopped." : "Speed test finished.", level: .ok)
        }
    }

    static func fmt(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.2f GB/s", mbps / 1000) : String(format: "%.0f MB/s", mbps)
    }

    /// Plain-text summary for the clipboard / log.
    func summaryText() -> String {
        var l: [String] = ["SecureClone speed test — \(size.label) per test"]
        for r in results {
            var parts = [r.volume.name.padding(toLength: 18, withPad: " ", startingAt: 0)]
            parts.append("read " + (r.readMBps.map(Self.fmt) ?? "—"))
            parts.append("write " + (r.readOnly ? "n/a (read-only)" : (r.writeMBps.map(Self.fmt) ?? "—")))
            if let n = r.note { parts.append("(\(n))") }
            if let e = r.error { parts.append("ERROR: \(e)") }
            l.append("  " + parts.joined(separator: "   "))
        }
        if !transfers.isEmpty {
            l.append("Real transfers:")
            for t in transfers {
                l.append("  \(t.from.name) → \(t.to.name): " + (t.mbps.map(Self.fmt) ?? (t.error ?? "—")))
            }
        }
        return l.joined(separator: "\n")
    }
}
