//
//  SourcePickerView.swift
//  SecureClone
//

import SwiftUI

struct SourcePickerView: View {
    @EnvironmentObject var vm: CloneViewModel
    let volumes: [VolumeInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Source card", systemImage: "sdcard").font(.headline)
                if vm.detecting { ProgressView().controlSize(.mini) }
                Spacer()
                if let r = vm.detectedReel {
                    Text("\(r.system) · \(r.reel)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if volumes.isEmpty {
                Text("No volumes detected. Plug in a card reader.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ForEach(volumes) { vol in
                    row(vol)
                }
            }
        }
    }
}

extension SourcePickerView {
    fileprivate func row(_ vol: VolumeInfo) -> DriveRow {
        let isSel = vm.selectedSource == vol
        var subtitle: String? = nil
        if isSel, let f = vm.sourceFolder { subtitle = "Folder: \(f.lastPathComponent)" }
        var folderAction: (() -> Void)? = nil
        if isSel { folderAction = { vm.chooseSourceFolder() } }
        var clearAction: (() -> Void)? = nil
        if isSel && vm.sourceFolder != nil { clearAction = { vm.clearSourceFolder() } }
        var ejectAction: (() -> Void)? = nil
        if vol.isRemovable { ejectAction = { vm.eject(vol) } }
        return DriveRow(volume: vol, isSelected: isSel, accent: .orange, subtitle: subtitle,
                        onSelect: { vm.selectSource(isSel ? nil : vol) },
                        onFolder: folderAction, onClearFolder: clearAction, onEject: ejectAction)
    }
}

/// One volume row with optional accessory buttons: choose folder, clear
/// folder, eject. Used for both source and destination lists.
struct DriveRow: View {
    let volume: VolumeInfo
    let isSelected: Bool
    var accent: Color = .accentColor
    var showCheckbox: Bool = false
    var subtitle: String? = nil
    let onSelect: () -> Void
    var onFolder: (() -> Void)? = nil
    var onClearFolder: (() -> Void)? = nil
    var onEject: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: volume.isRemovable ? "sdcard.fill" : "externaldrive.fill")
                        .foregroundStyle(isSelected ? accent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(volume.name).bold()
                            if let c = volume.connection, c.bus != .unknown {
                                Text(c.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4)
                                        .fill(c.isSlowLink ? Color.orange.opacity(0.25) : Color.gray.opacity(0.15)))
                                    .foregroundStyle(c.isSlowLink ? .orange : .secondary)
                            }
                        }
                        Text(subtitle ?? "\(volume.availableCapacityFormatted) free of \(volume.totalCapacityFormatted)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: showCheckbox ? "checkmark.square.fill" : "checkmark.circle.fill")
                            .foregroundStyle(accent)
                    } else if showCheckbox {
                        Image(systemName: "square").foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? accent.opacity(0.12) : Color.gray.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? accent.opacity(0.5) : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if let onFolder {
                Button(action: onFolder) { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Choose a folder on this volume")
            }
            if let onClearFolder {
                Button(action: onClearFolder) { Image(systemName: "folder.badge.minus") }
                    .buttonStyle(.borderless).help("Use the whole volume")
            }
            if let onEject {
                Button(action: onEject) { Image(systemName: "eject") }
                    .buttonStyle(.borderless).help("Eject \(volume.name)")
            }
        }
    }
}
