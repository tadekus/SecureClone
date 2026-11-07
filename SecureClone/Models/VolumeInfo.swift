//
//  VolumeInfo.swift
//  SecureClone
//
//  Represents a mounted volume (a card or a destination drive).
//

import Foundation

struct VolumeInfo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isRemovable: Bool
    let totalCapacity: Int64
    let availableCapacity: Int64

    var usedCapacity: Int64 { totalCapacity - availableCapacity }

    var totalCapacityFormatted: String { Self.format(totalCapacity) }
    var availableCapacityFormatted: String { Self.format(availableCapacity) }

    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // Equatable / Hashable keyed on the mount path, not the random UUID,
    // so the same volume compares equal across refreshes.
    static func == (lhs: VolumeInfo, rhs: VolumeInfo) -> Bool {
        lhs.url == rhs.url
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
