//
//  DriveConnectionInfo.swift
//  SecureClone
//
//  Walks the IOKit registry from a volume's BSD device up to the bus it
//  hangs off: USB (with link speed), Thunderbolt/PCIe, SATA, or internal.
//  Lets the UI warn when a "fast" SSD is actually on a USB 2 link, and the
//  safety validator refuse two backups that share one physical disk.
//

import Foundation
import IOKit
import DiskArbitration

struct DriveConnection: Equatable {
    enum Bus: String { case usb = "USB", thunderbolt = "Thunderbolt", pcie = "PCIe", sata = "SATA", internalDrive = "Internal", network = "Network", unknown = "—" }
    let bus: Bus
    /// USB link speed in Mb/s (480 = USB 2.0, 5000 = USB 3 Gen 1, 10000 = Gen 2, 20000 = Gen 2x2).
    let usbMbps: Int?

    var label: String {
        switch bus {
        case .usb:
            guard let m = usbMbps else { return "USB" }
            if m >= 20000 { return "USB 20 Gb/s" }
            if m >= 10000 { return "USB 10 Gb/s" }
            if m >= 5000  { return "USB 5 Gb/s" }
            if m >= 480   { return "USB 2.0 (480 Mb/s)" }
            return "USB \(m) Mb/s"
        default: return bus.rawValue
        }
    }
    /// True when the link itself caps a modern SSD (USB 2 or slower).
    var isSlowLink: Bool { bus == .usb && (usbMbps ?? 5000) < 5000 }
    /// Rough expected ceiling in MB/s for the link, for the speed test / warnings.
    var linkCeilingMBps: Int? {
        guard bus == .usb, let m = usbMbps else { return nil }
        return m / 10   // ~bits→bytes with protocol overhead
    }
}

enum DriveConnectionInfo {

    /// BSD device name for a mounted volume, e.g. "disk4s2".
    static func bsdName(for volume: URL) -> String? {
        var fs = statfs()
        guard statfs(volume.path, &fs) == 0 else { return nil }
        let dev = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return dev.hasPrefix("/dev/") ? String(dev.dropFirst(5)) : nil
    }

    /// Whole-disk BSD name ("disk4") for a volume, via DiskArbitration.
    static func wholeDisk(for volume: URL) -> String? {
        guard let bsd = bsdName(for: volume),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
              let whole = DADiskCopyWholeDisk(disk),
              let name = DADiskGetBSDName(whole) else { return nil }
        return String(cString: name)
    }

    /// Physical disks behind a volume. For an APFS container (a synthesized
    /// "diskN") this resolves the physical store(s); otherwise the whole disk.
    static func physicalDisks(for volume: URL) -> Set<String> {
        guard let whole = wholeDisk(for: volume) else { return [] }
        var out: Set<String> = []
        if let stores = apfsPhysicalStores(of: whole), !stores.isEmpty {
            for s in stores { out.insert(wholeDiskName(of: s)) }
        } else {
            out.insert(whole)
        }
        return out
    }

    private static func wholeDiskName(of bsd: String) -> String {
        // "disk0s2" -> "disk0"
        if let r = bsd.range(of: #"^disk\d+"#, options: .regularExpression) { return String(bsd[r]) }
        return bsd
    }

    /// `diskutil info -plist diskN` → APFSPhysicalStores → DeviceIdentifier.
    private static func apfsPhysicalStores(of whole: String) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", whole]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let stores = plist["APFSPhysicalStores"] as? [[String: Any]] else { return nil }
        return stores.compactMap { $0["DeviceIdentifier"] as? String }
    }

    // MARK: - Bus / link speed

    static func connection(for volume: URL) -> DriveConnection {
        guard let bsd = bsdName(for: volume) else { return DriveConnection(bus: .unknown, usbMbps: nil) }
        // Resolve APFS synthesized disks to their physical store for the bus walk.
        let disks = physicalDisks(for: volume)
        let target = disks.first ?? bsd
        return connection(forBSD: target)
    }

    private static func connection(forBSD bsd: String) -> DriveConnection {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else {
            return DriveConnection(bus: .unknown, usbMbps: nil)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return DriveConnection(bus: .unknown, usbMbps: nil) }
        defer { IOObjectRelease(service) }

        var entry: io_registry_entry_t = service
        IOObjectRetain(entry)
        var depth = 0
        var sawPCI = false, sawThunderbolt = false, sawSATA = false, sawNVMe = false
        while depth < 40 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                let speed = property(entry, "USBSpeed") as? Int ?? property(entry, "Device Speed") as? Int
                let mbps = usbSpeedMbps(speed)
                IOObjectRelease(entry)
                return DriveConnection(bus: .usb, usbMbps: mbps)
            }
            if IOObjectConformsTo(entry, "IOThunderboltPort") != 0 || IOObjectConformsTo(entry, "IOThunderboltController") != 0 { sawThunderbolt = true }
            if IOObjectConformsTo(entry, "IOPCIDevice") != 0 { sawPCI = true }
            if IOObjectConformsTo(entry, "IOAHCIDevice") != 0 { sawSATA = true }
            if IOObjectConformsTo(entry, "IONVMeController") != 0 { sawNVMe = true }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS, parent != 0 else { break }
            entry = parent
            depth += 1
        }
        if depth >= 40 { IOObjectRelease(entry) }
        if sawThunderbolt { return DriveConnection(bus: .thunderbolt, usbMbps: nil) }
        if sawSATA { return DriveConnection(bus: .sata, usbMbps: nil) }
        if sawNVMe || sawPCI { return DriveConnection(bus: .internalDrive, usbMbps: nil) }
        return DriveConnection(bus: .unknown, usbMbps: nil)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// IOUSBHost speed enum: 0 low, 1 full, 2 high (480), 3 super (5 G), 4 super+ (10 G), 5 super+ x2 (20 G).
    /// Older IOUSBFamily enum: 1 low, 2 full, 3 high, 4 super, 5 super+ … — the two
    /// disagree by one; we read "USBSpeed" (IOUSBHost) first and treat ≥3 as USB 3.
    private static func usbSpeedMbps(_ v: Int?) -> Int? {
        guard let v else { return nil }
        switch v {
        case 0: return 2
        case 1: return 12
        case 2: return 480
        case 3: return 5000
        case 4: return 10000
        case 5: return 20000
        default: return v > 5 ? 20000 : nil
        }
    }
}
