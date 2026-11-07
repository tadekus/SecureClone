//
//  DestinationPickerView.swift
//  SecureClone
//

import SwiftUI

struct DestinationPickerView: View {
    @EnvironmentObject var vm: CloneViewModel
    let volumes: [VolumeInfo]

    /// Don't allow the source to also be a destination.
    private var candidates: [VolumeInfo] {
        volumes.filter { $0 != vm.selectedSource }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Destinations (\(vm.selectedDestinations.count))", systemImage: "externaldrive.badge.plus")
                .font(.headline)

            if candidates.isEmpty {
                Text("No destination drives available.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ForEach(candidates) { vol in
                    row(vol)
                }
            }
        }
    }

    private func row(_ vol: VolumeInfo) -> DriveRow {
        let selected = vm.selectedDestinations.contains(vol)
        let base = vm.destinationBases[vol.url]
        var subtitle: String? = nil
        if let b = base {
            let rel = b.path.replacingOccurrences(of: vol.url.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            subtitle = "→ \(rel)"
        }
        var clearAction: (() -> Void)? = nil
        if base != nil { clearAction = { vm.clearDestinationFolder(for: vol) } }
        var ejectAction: (() -> Void)? = nil
        if vol.isRemovable { ejectAction = { vm.eject(vol) } }
        return DriveRow(volume: vol, isSelected: selected, accent: .green, showCheckbox: true,
                        subtitle: subtitle,
                        onSelect: {
                            if selected { vm.selectedDestinations.remove(vol) }
                            else { vm.selectedDestinations.insert(vol) }
                        },
                        onFolder: { vm.chooseDestinationFolder(for: vol) },
                        onClearFolder: clearAction, onEject: ejectAction)
    }
}
