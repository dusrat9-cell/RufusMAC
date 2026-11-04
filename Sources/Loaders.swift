import Foundation

/// Boot loaders that Rufus ships inside its own binary. Nothing is bundled here:
/// the exact same assets are fetched from the Rufus source repository (GPLv3,
/// the project this is a port of) and cached in Application Support.
enum Loaders {

    static let rawBase = "https://raw.githubusercontent.com/pbatard/rufus/master"

    // MARK: - Entries

    enum Kind {
        case dos            // MS-DOS / FreeDOS: files + FAT boot record
        case grub2          // boot.img as MBR, core.img as PBR, grub.cfg
        case needsInstaller(String)
    }

    struct Spec {
        let kind: Kind
        /// Paths relative to the Rufus repo, e.g. "res/freedos/KERNEL.SYS".
        let files: [String]
        /// Where each file lands on the stick ("" = not copied, used as a blob).
        let dest: (String) -> String
    }

    /// The FreeDOS file set Rufus extracts from FD14 and writes for both the
    /// "MS-DOS" and "FreeDOS" entries (see rufus/src/format.c, ExtractDOS).
    static let dosFiles = [
        "COMMAND.COM", "KERNEL.SYS", "DISPLAY.EXE", "KEYB.EXE", "MODE.COM",
        "KEYBOARD.SYS", "KEYBRD2.SYS", "KEYBRD3.SYS", "KEYBRD4.SYS",
        "EGA.CPX", "EGA2.CPX", "EGA3.CPX", "EGA4.CPX", "EGA5.CPX", "EGA6.CPX",
        "EGA7.CPX", "EGA8.CPX", "EGA9.CPX", "EGA10.CPX", "EGA11.CPX", "EGA12.CPX",
        "EGA13.CPX", "EGA14.CPX", "EGA15.CPX", "EGA16.CPX", "EGA17.CPX", "EGA18.CPX"
    ]

    static func spec(for entry: String) -> Spec? {
        switch entry {
        case "MS-DOS", "FreeDOS":
            return Spec(kind: .dos,
                        files: dosFiles.map { "res/freedos/\($0)" },
                        dest: { ($0 as NSString).lastPathComponent })
        case "Grub 2.04":
            return Spec(kind: .grub2,
                        files: ["res/grub2/boot.img", "res/grub2/core.img"],
                        dest: { ($0 as NSString).lastPathComponent })
        case "Syslinux 4.07", "Syslinux 6.04":
            return Spec(kind: .needsInstaller(
                "Syslinux necesita su propio instalador: parchea el mapa de sectores dentro de ldlinux.sys y en el sector de arranque, y Rufus lo consigue portando ese instalador (src/syslinux.c + libfat). Copiar los dos ficheros no arranca. Todavía no está portado."),
                files: [], dest: { _ in "" })
        case "Grub4DOS 0.4.6a":
            return Spec(kind: .needsInstaller(
                "Grub4DOS necesita además el fichero grldr, que Rufus no incluye en su repositorio (solo el MBR). Se puede añadir cuando descarguemos grldr del proyecto grub4dos."),
                files: [], dest: { _ in "" })
        case "UEFI:NTFS":
            return Spec(kind: .needsInstaller(
                "UEFI:NTFS añade una segunda partición FAT con el driver de NTFS para poder arrancar por UEFI desde un USB NTFS o exFAT. Requiere crear dos particiones, que es un cambio aparte."),
                files: [], dest: { _ in "" })
        case "ReactOS":
            // No es un cargador incrustado: es una ISO (como "Imagen de disco o ISO").
            // Se monta la disposición de arranque para el EFI de Apple en el motor.
            return nil
        default:
            return nil
        }
    }

    // MARK: - Cache

    static func cacheRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("RufusMac/loaders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads whatever is missing and returns `file name -> local URL`.
    static func ensure(_ spec: Spec,
                       progress: (Double, String) -> Void) throws -> [String: URL] {
        let root = cacheRoot()
        var out: [String: URL] = [:]
        let total = max(spec.files.count, 1)

        for (i, path) in spec.files.enumerated() {
            let name = (path as NSString).lastPathComponent
            let local = root.appendingPathComponent(name)
            let frac = Double(i) / Double(total)

            if FileManager.default.fileExists(atPath: local.path),
               (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 {
                out[name] = local
                continue
            }

            progress(frac, "Descargando \(name)")
            guard let url = URL(string: "\(rawBase)/\(path)") else {
                throw EngineError("URL inválida para \(path)")
            }
            let r = Shell.run("/usr/bin/curl",
                              ["-fsSL", "--retry", "3", "--max-time", "120",
                               "-o", local.path, url.absoluteString],
                              timeout: 180)
            guard r.ok else {
                try? FileManager.default.removeItem(at: local)
                throw EngineError("no pude descargar \(name): \(r.combined.isEmpty ? "sin conexión" : r.combined)")
            }
            let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
            guard size > 0 else {
                try? FileManager.default.removeItem(at: local)
                throw EngineError("\(name) llegó vacío")
            }
            out[name] = local
        }
        return out
    }

    // MARK: - Install

    /// Copies the loader's files onto an already formatted volume.
    /// The boot record is written separately, after the volume is unmounted.
    @discardableResult
    static func copyFiles(entry: String,
                          mount: URL,
                          progress: (Double, String) -> Void) throws -> Bool {
        guard let spec = spec(for: entry) else {
            throw EngineError("«\(entry)» no es una entrada de arranque conocida")
        }
        switch spec.kind {
        case .needsInstaller(let why):
            throw EngineError(why)
        case .dos:
            let files = try ensure(spec, progress: { f, m in progress(0.10 + 0.80 * f, m) })
            progress(0.92, "Copiando FreeDOS")
            for (name, src) in files {
                let dst = mount.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
            }
            return true
        case .grub2:
            let files = try ensure(spec, progress: { f, m in progress(0.10 + 0.70 * f, m) })
            guard let coreImg = files["core.img"] else {
                throw EngineError("falta core.img")
            }
            progress(0.86, "Creando grub.cfg")
            let grubDir = mount.appendingPathComponent("boot/grub", isDirectory: true)
            try? FileManager.default.createDirectory(at: grubDir, withIntermediateDirectories: true)
            let cfg = """
            set timeout=10
            set default=0

            menuentry "Arrancar desde el disco duro" {
                set root=(hd0,1)
                chainloader +1
            }
            """
            try? Data(cfg.utf8).write(to: grubDir.appendingPathComponent("grub.cfg"))
            _ = coreImg
            return true
        }
    }

    /// Writes the boot record / MBR. Unmounts the volume first: macOS returns
    /// EBUSY on a raw write while any partition is mounted.
    static func writeBootRecord(entry: String,
                                disk: String,
                                fat32: Bool,
                                progress: (Double, String) -> Void) throws {
        guard let spec = spec(for: entry) else {
            throw EngineError("«\(entry)» no es una entrada de arranque conocida")
        }
        try DiskService.unmount(disk)
        switch spec.kind {
        case .dos:
            progress(0.95, "Escribiendo el sector de arranque de DOS")
            try writeDosBootRecord(disk: disk, fat32: fat32)
        case .grub2:
            let files = try ensure(spec, progress: { _, _ in })
            guard let bootImg = files["boot.img"], let coreImg = files["core.img"] else {
                throw EngineError("faltan boot.img o core.img")
            }
            progress(0.95, "Escribiendo Grub 2")
            try writeGrub2(disk: disk, bootImg: bootImg, coreImg: coreImg)
        case .needsInstaller(let why):
            throw EngineError(why)
        }
    }

    // MARK: - DOS boot record

    /// Same bytes Rufus writes: ms-sys' FreeDOS FAT16/FAT32 boot records, patched
    /// over the BPB that diskutil just created so the geometry stays intact.
    static func writeDosBootRecord(disk: String, fat32: Bool) throws {
        guard let partID = DiskService.partitionID(of: disk) else {
            throw EngineError("no encontré la partición de \(disk)")
        }
        let dev = "/dev/r\(partID)"
        let span = fat32 ? 1536 : 512

        var lastError: Error?
        for _ in 0..<8 {
            do {
                var sector = [UInt8](try readBytes(dev, count: span, at: 0))
                for patch in DosBoot.patches(fat32: fat32) {
                    let bytes = [UInt8](patch.bytes)
                    guard patch.offset + bytes.count <= sector.count else { continue }
                    for (i, b) in bytes.enumerated() { sector[patch.offset + i] = b }
                }
                // keep the signature
                if sector.count >= 512 {
                    sector[510] = 0x55
                    sector[511] = 0xAA
                }
                try writeBytes(dev, bytes: sector, at: 0)
                try markActive(disk: disk)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        throw EngineError("no pude escribir el sector de arranque de DOS: "
                          + (lastError?.localizedDescription ?? "?"))
    }

    // MARK: - Grub 2

    static func writeGrub2(disk: String, bootImg: URL, coreImg: URL) throws {
        guard let partID = DiskService.partitionID(of: disk) else {
            throw EngineError("no encontré la partición de \(disk)")
        }
        let boot = [UInt8](try Data(contentsOf: bootImg))
        var core = [UInt8](try Data(contentsOf: coreImg))
        guard boot.count >= 440, core.count > 512 else {
            throw EngineError("boot.img o core.img tienen un tamaño inesperado")
        }
        // raw devices reject writes that are not sector-aligned
        while core.count % 512 != 0 { core.append(0) }

        // core.img lives in the reserved area right after the PBR, so it has to
        // fit there or it would overwrite the FAT. Refuse instead of corrupting.
        let bpb = try readBytes("/dev/r\(partID)", count: 512, at: 0)
        let reserved = Int(bpb[0x0E]) | (Int(bpb[0x0F]) << 8)
        let needed = core.count / 512 + 1
        guard needed <= reserved else {
            throw EngineError("core.img ocupa \(needed) sectores y este volumen solo reserva \(reserved) antes de la FAT: Grub 2 necesita que se formatee con más sectores reservados (Rufus usa su propio formateador). Prueba con «FAT (predeterminado)» en un USB pequeño o usa otra entrada.")
        }

        var lastError: Error?
        for _ in 0..<8 {
            do {
                // core.img goes right after the PBR, exactly like Rufus (offset br_size)
                try writeBytes("/dev/r\(partID)", bytes: core, at: 512)
                // boot.img replaces the MBR code but not the partition table
                var mbr = try readBytes("/dev/r\(disk)", count: 512, at: 0)
                for i in 0..<440 { mbr[i] = boot[i] }
                try writeBytes("/dev/r\(disk)", bytes: mbr, at: 0)
                try markActive(disk: disk)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        throw EngineError("no pude escribir Grub 2: \(lastError?.localizedDescription ?? "?")")
    }

    // MARK: - Helpers

    static func markActive(disk: String) throws {
        var mbr = try readBytes("/dev/r\(disk)", count: 512, at: 0)
        guard mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw EngineError("el MBR no tiene la firma esperada")
        }
        mbr[0x1BE] = 0x80
        try writeBytes("/dev/r\(disk)", bytes: mbr, at: 0)
    }

    static func readBytes(_ path: String, count: Int, at offset: off_t) throws -> [UInt8] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw EngineError("no puedo abrir \(path)") }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: count)
        let n = pread(fd, &buf, count, offset)
        guard n == count else { throw EngineError("lectura corta en \(path)") }
        return buf
    }

    static func writeBytes(_ path: String, bytes: [UInt8], at offset: off_t) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else {
            throw EngineError("no puedo abrir \(path) para escritura: "
                              + String(cString: strerror(errno)))
        }
        defer { close(fd) }
        let n = pwrite(fd, bytes, bytes.count, offset)
        guard n == bytes.count else { throw EngineError("escritura corta en \(path)") }
        fsync(fd)
    }
}
