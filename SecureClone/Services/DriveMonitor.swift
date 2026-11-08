//
//  DriveMonitor.swift
//  SecureClone
//
//  Watches for volumes mounting and unmounting via DiskArbitration,
//  and publishes the current list of mounted volumes.
//

import Foundation
import AppKit
import DiskArbitration
import Combine

final class DriveMonitor: ObservableObject {
    @Published private(set) var volumes: [VolumeInfo] = []
    /// Fires with the newly mounted volume (for auto-start).
    let mounted = PassthroughSubject<VolumeInfo, Never>()
    let unmounted = PassthroughSubject<URL, Never>()

    private var session: DASession?
    private var connectionCache: [String: DriveConnection] = [:]
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeIsBrowsableKey,
        .volumeIsLocalKey
    ]

    func start() {
        session = DASessionCreate(kCFAllocatorDefault)
        if let session {
            DASessionScheduleWithRunLoop(session,
                                         CFRunLoopGetMain(),
                                         CFRunLoopMode.defaultMode.rawValue)
        }

        // NSWorkspace gives simple, reliable mount/unmount notifications.
        let nc = NSWorkspace.shared.notificationCenter
        mountObserver = nc.addObserver(forName: NSWorkspace.didMountNotification,
                                       object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.refresh()
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
               let v = self.volumes.first(where: { $0.url == url }) {
                self.mounted.send(v)
            }
        }
        unmountObserver = nc.addObserver(forName: NSWorkspace.didUnmountNotification,
                                         object: nil, queue: .main) { [weak self] note in
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                self?.connectionCache[url.path] = nil
            }
            self?.refresh()
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                self?.unmounted.send(url)
            }
        }

        refresh()
    }

    func stop() {
        if let session {
            DASessionUnscheduleFromRunLoop(session,
                                           CFRunLoopGetMain(),
                                           CFRunLoopMode.defaultMode.rawValue)
        }
        session = nil
        let nc = NSWorkspace.shared.notificationCenter
        if let m = mountObserver   { nc.removeObserver(m) }
        if let u = unmountObserver { nc.removeObserver(u) }
    }

    func refresh() {
        let keySet = Set(Self.resourceKeys)
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.resourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []

        volumes = urls.compactMap { url -> VolumeInfo? in
            guard let vals = try? url.resourceValues(forKeys: keySet) else { return nil }
            // Only browsable, local volumes (skip network shares, system snapshots).
            guard vals.volumeIsBrowsable == true else { return nil }
            guard vals.volumeIsLocal == true else { return nil }

            let removable = (vals.volumeIsRemovable ?? false) || (vals.volumeIsEjectable ?? false)

            var v = VolumeInfo(
                url: url,
                name: vals.volumeName ?? url.lastPathComponent,
                isRemovable: removable,
                totalCapacity: Int64(vals.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(vals.volumeAvailableCapacity ?? 0)
            )
            if let c = connectionCache[url.path] { v.connection = c }
            else {
                let c = DriveConnectionInfo.connection(for: url)
                connectionCache[url.path] = c
                v.connection = c
            }
            return v
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Removable volumes only — likely camera cards.
    var removableVolumes: [VolumeInfo] { volumes.filter { $0.isRemovable } }

    /// Unmount and eject a volume (e.g. the card after a verified offload).
    static func eject(_ url: URL) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }
}
