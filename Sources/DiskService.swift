import Foundation

enum DiskService {

    static func plist(_ args: [String]) -> [String: Any] {
        // diskutil wants -plist before the device argument
        var full = args
        if full.count >= 1 { full.insert("-plist", at: 1) }
        let r = Shell.run(DISKUTIL, full)
        guard let data = r.out.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict
    }

    static func systemDiskID() -> String? {
        plist(["info", "/"]).string("ParentWholeDisk")
    }

    /// Tamaño real del medio. `TotalSize` a veces lo toma del sistema de archivos que hay
    /// encima: tras escribir una ISO en crudo, un USB de 16 GB reportaba 489 MB por ahí y
    /// la app lo descartaba por pequeño. `IOKitSize`/`Size` son del dispositivo.
    static func mediaSize(_ info: [String: Any]) -> Int64 {
        for key in ["IOKitSize", "Size", "TotalSize"] {
            if let n = info[key] as? NSNumber, n.int64Value > 0 { return n.int64Value }
        }
        return 0
    }

    static func list() -> [DiskInfo] {
        let root = plist(["list"])
        guard let all = root["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        let sys = systemDiskID()
        var disks: [DiskInfo] = []

        for entry in all {
            guard let ident = entry["DeviceIdentifier"] as? String else { continue }
            let info = plist(["info", ident])
            let bus = info.string("BusProtocol") ?? ""
            // mounted .dmg volumes are not USB sticks; keep the list honest
            // (the env override exists only so the UI can be exercised in tests)
            let showImages = UserDefaults.standard.bool(forKey: "showDiskImages")
            if bus == "Disk Image" && !showImages { continue }
            let volumes = (entry["Partitions"] as? [[String: Any]] ?? [])
                .compactMap { $0["VolumeName"] as? String }
                .filter { !$0.isEmpty }

            disks.append(DiskInfo(
                id: ident,
                size: mediaSize(info),
                name: info.string("MediaName") ?? info.string("IORegistryEntryName") ?? "",
                bus: bus,
                isInternal: (info["Internal"] as? Bool) ?? false,
                isRemovable: (info["RemovableMedia"] as? Bool) ?? true,
                isSystem: ident == sys,
                volumes: volumes
            ))
        }
        return disks.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func unmount(_ disk: String) throws {
        if Shell.run(DISKUTIL, ["unmountDisk", "/dev/\(disk)"]).ok { return }
        if Shell.run(DISKUTIL, ["unmountDisk", "force", "/dev/\(disk)"]).ok { return }
        throw EngineError("no pude desmontar /dev/\(disk)")
    }

    static func erase(_ disk: String, label: String, scheme: String, fs: String = "FAT32") throws -> String {
        let clean = String(label.uppercased().prefix(11)).isEmpty ? "RUFUS" : String(label.uppercased().prefix(11))
        let format: String
        switch fs {
        case "exFAT": format = "ExFAT"
        case "FAT":
            // "FAT (Default)" means FAT16; diskutil needs it spelled out
            let size = DiskService.size(of: disk)
            format = size > 0 && size < 2 * 1024 * 1024 * 1024 ? "MS-DOS FAT16" : "MS-DOS"
        case "FAT32":
            // plain "MS-DOS" silently becomes FAT16 on small volumes
            format = "MS-DOS FAT32"
        default: format = "MS-DOS"
        }
        let r = Shell.run(DISKUTIL, ["eraseDisk", format, clean, scheme, "/dev/\(disk)"])
        guard r.ok else {
            throw EngineError("no pude formatear /dev/\(disk): \(r.combined)")
        }
        return "/Volumes/\(clean)"
    }

    static func eject(_ disk: String) {
        _ = Shell.run(DISKUTIL, ["eject", "/dev/\(disk)"])
    }

    static func partitionID(of disk: String) -> String? {
        partitionIDs(of: disk).first
    }

    /// Todas las particiones del disco, en orden. En un GPT creado por `eraseDisk`
    /// la primera es la ESP (EF00) y la última el volumen de datos.
    static func partitionIDs(of disk: String) -> [String] {
        let root = plist(["list", disk])
        guard let all = root["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        for entry in all where entry["DeviceIdentifier"] as? String == disk {
            return (entry["Partitions"] as? [[String: Any]] ?? [])
                .compactMap { $0["DeviceIdentifier"] as? String }
        }
        return []
    }

    /// Partición de datos: la última del disco.
    static func dataPartitionID(of disk: String) -> String? {
        partitionIDs(of: disk).last
    }

    static func mountPoint(ofPartition part: String) -> String? {
        plist(["info", part]).string("MountPoint")
    }

    static func dataMountPoint(of disk: String) -> String? {
        guard let part = dataPartitionID(of: disk) else { return nil }
        return mountPoint(ofPartition: part)
    }

    static func isBusy(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Bytes libres en el volumen montado.
    static func freeBytes(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        return Int64((try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity ?? 0)
    }

    static func size(of disk: String) -> Int64 {
        mediaSize(plist(["info", disk]))
    }

    static func mountPoint(of disk: String) -> String? {
        guard let part = partitionID(of: disk) else { return nil }
        return plist(["info", part]).string("MountPoint")
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
}
