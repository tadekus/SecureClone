//
//  SpeedTestService.swift
//  SecureClone
//
//  Measures real drive throughput:
//    • write — a temp file of pseudo-random data, F_NOCACHE, fsync'd, deleted
//    • read  — the temp file read back (F_NOCACHE), or for a read-only volume
//              its existing files (largest first) up to the test size
//    • transfer — stream real files from a source volume into a temp file on
//              a destination (what an offload actually does)
//  Everything is blocking I/O meant to run on a background thread.
//

import Foundation
import Darwin

struct SpeedResult: Identifiable {
    let id = UUID()
    let volume: VolumeInfo
    var readOnly: Bool
    var readMBps: Double? = nil
    var writeMBps: Double? = nil
    var error: String? = nil
    var note: String? = nil
}

struct TransferResult: Identifiable {
    let id = UUID()
    let from: VolumeInfo
    let to: VolumeInfo
    var mbps: Double? = nil
    var error: String? = nil
}

enum SpeedTestService {

    static let chunk = 8 * 1024 * 1024

    /// Random-ish payload reused for every write (generated once).
    private static let payload: Data = {
        var d = Data(count: chunk)
        d.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            var x: UInt64 = 0x9E3779B97F4A7C15
            let words = raw.count / 8
            let wp = p.bindMemory(to: UInt64.self, capacity: words)
            for i in 0..<words {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                wp[i] = x
            }
        }
        return d
    }()

    static func isReadOnly(_ v: VolumeInfo) -> Bool {
        (try? v.url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }

    private static func noCache(_ h: FileHandle) {
        _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
    }

    private static func tempURL(on v: VolumeInfo) -> URL {
        v.url.appendingPathComponent(".SecureClone_speedtest_\(UUID().uuidString.prefix(8)).tmp")
    }

    // MARK: - Write

    static func testWrite(_ v: VolumeInfo, bytes: Int64, control: CloneControl,
                          progress: (Double) -> Void) throws -> Double {
        let url = tempURL(on: v)
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "SpeedTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create a file on \(v.name)"])
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        noCache(h)
        let start = Date()
        var written: Int64 = 0
        while written < bytes {
            guard control.checkpoint() else { throw CloneEngineError.cancelled }
            let n = Int(min(Int64(chunk), bytes - written))
            try h.write(contentsOf: n == chunk ? payload : payload.prefix(n))
            written += Int64(n)
            progress(Double(written) / Double(bytes))
        }
        try h.synchronize()
        let secs = Date().timeIntervalSince(start)
        return secs > 0 ? Double(written) / secs / 1_000_000 : 0
    }

    // MARK: - Read

    /// Read back a fresh temp file (writable volumes).
    static func testReadWritable(_ v: VolumeInfo, bytes: Int64, control: CloneControl,
                                 progress: (Double) -> Void) throws -> Double {
        let url = tempURL(on: v)
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "SpeedTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create a file on \(v.name)"])
        }
        do {
            let w = try FileHandle(forWritingTo: url)
            noCache(w)
            var written: Int64 = 0
            while written < bytes {
                guard control.checkpoint() else { throw CloneEngineError.cancelled }
                let n = Int(min(Int64(chunk), bytes - written))
                try w.write(contentsOf: n == chunk ? payload : payload.prefix(n))
                written += Int64(n)
            }
            try w.synchronize()
            try w.close()
        }
        return try readFiles([url], bytes: bytes, control: control, progress: progress)
    }

    /// Read existing files (read-only volumes), largest first.
    static func testReadExisting(_ v: VolumeInfo, bytes: Int64, control: CloneControl,
                                 progress: (Double) -> Void) throws -> (Double, Int64) {
        let files = (try? SourceScanner.scan(root: v.url)) ?? []
        let sorted = files.sorted { $0.size > $1.size }
        var picked: [URL] = []
        var total: Int64 = 0
        for f in sorted where total < bytes { picked.append(f.url); total += f.size }
        guard total > 0 else {
            throw NSError(domain: "SpeedTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "No files to read on \(v.name)"])
        }
        let target = min(bytes, total)
        return (try readFiles(picked, bytes: target, control: control, progress: progress), target)
    }

    private static func readFiles(_ urls: [URL], bytes: Int64, control: CloneControl,
                                  progress: (Double) -> Void) throws -> Double {
        let start = Date()
        var read: Int64 = 0
        outer: for u in urls {
            let h = try FileHandle(forReadingFrom: u)
            defer { try? h.close() }
            noCache(h)
            while read < bytes {
                guard control.checkpoint() else { throw CloneEngineError.cancelled }
                let d = try autoreleasepool { try h.read(upToCount: chunk) ?? Data() }
                if d.isEmpty { break }
                read += Int64(d.count)
                progress(Double(read) / Double(bytes))
            }
            if read >= bytes { break outer }
        }
        let secs = Date().timeIntervalSince(start)
        return secs > 0 ? Double(read) / secs / 1_000_000 : 0
    }

    // MARK: - Transfer

    /// Stream real files from `from` into a temp file on `to`: the closest
    /// thing to an actual offload, single stream.
    static func testTransfer(from: VolumeInfo, to: VolumeInfo, bytes: Int64, control: CloneControl,
                             progress: (Double) -> Void) throws -> Double {
        let files = ((try? SourceScanner.scan(root: from.url)) ?? []).sorted { $0.size > $1.size }
        var picked: [URL] = []
        var total: Int64 = 0
        for f in files where total < bytes { picked.append(f.url); total += f.size }
        guard total > 0 else {
            throw NSError(domain: "SpeedTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "No files to read on \(from.name)"])
        }
        let target = min(bytes, total)

        let url = tempURL(on: to)
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "SpeedTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create a file on \(to.name)"])
        }
        let w = try FileHandle(forWritingTo: url)
        defer { try? w.close() }
        noCache(w)

        let start = Date()
        var moved: Int64 = 0
        outer: for u in picked {
            let r = try FileHandle(forReadingFrom: u)
            defer { try? r.close() }
            noCache(r)
            while moved < target {
                guard control.checkpoint() else { throw CloneEngineError.cancelled }
                let d = try autoreleasepool { try r.read(upToCount: chunk) ?? Data() }
                if d.isEmpty { break }
                try w.write(contentsOf: d)
                moved += Int64(d.count)
                progress(Double(moved) / Double(target))
            }
            if moved >= target { break outer }
        }
        try w.synchronize()
        let secs = Date().timeIntervalSince(start)
        return secs > 0 ? Double(moved) / secs / 1_000_000 : 0
    }
}
