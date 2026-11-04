import Foundation

final class MountedIso {
    let mountPoint: URL
    private let imagePath: String
    private var detached = false
    private var sanitized: URL?

    init(path: String) throws {
        self.imagePath = path
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rufusmac-iso-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.mountPoint = dir

        if let failure = MountedIso.attach(path, at: dir) {
            // Una ISO híbrida (MBR/GPT/APM con una partición Apple_HFS dentro) hace que
            // DiskImages le corra un fsck automático y saque el prompt «Puede que exista
            // un problema con esta imagen de disco», o que elija el esquema APM y no
            // encuentre nada montable. Reintentar sobre una copia con la cabecera híbrida
            // borrada: así queda a la vista el ISO9660 real.
            guard let clean = MountedIso.sanitizedCopy(of: path),
                  MountedIso.attach(clean.path, at: dir) == nil else {
                try? FileManager.default.removeItem(at: dir)
                let hint = MountedIso.isCloudPlaceholder(path)
                    ? "\nla ISO está solo en la nube (Google Drive u otro File Provider): "
                      + "descárgala al disco antes de usarla"
                    : ""
                throw EngineError("no pude montar la ISO: \(failure)\(hint)")
            }
            sanitized = clean
        }
    }

    /// `nil` si montó; el mensaje de hdiutil si falló. `-noautofsck` es lo que evita el
    /// prompt de fsck en las híbridas que sí montan (p. ej. lordos).
    private static func attach(_ image: String, at dir: URL) -> String? {
        let r = Shell.run(HDIUTIL, [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-noautofsck",
            "-mountpoint", dir.path, image,
        ], timeout: 120)
        return r.ok ? nil : r.combined
    }

    /// Copia con los 16 primeros sectores a cero: quita el MBR/GPT/APM híbrido y deja
    /// el ISO9660, cuyo volumen descriptor vive en el sector 16. En APFS `cp -c` clona
    /// sin copiar bytes, y escribir 8 KB solo rompe la compartición de ese bloque.
    private static func sanitizedCopy(of path: String) -> URL? {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rufusmac-clean-\(UInt32.random(in: 0...UInt32.max)).iso")
        try? fm.removeItem(at: tmp)

        if !Shell.run("/bin/cp", ["-c", path, tmp.path], timeout: 600).ok {
            try? fm.removeItem(at: tmp)
            do { try fm.copyItem(at: URL(fileURLWithPath: path), to: tmp) }
            catch { return nil }
        }

        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            try? fm.removeItem(at: tmp); return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data(count: 16 * 512))
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: tmp); return nil
        }
        return tmp
    }

    /// Un File Provider (Google Drive, iCloud) deja el fichero «dataless»: tamaño real y
    /// cero bloques en disco. hdiutil no puede leerlo y responde «no mountable».
    static func isCloudPlaceholder(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return st.st_size > 0 && st.st_blocks == 0
    }

    func detach() {
        guard !detached else { return }
        detached = true
        _ = Shell.run(HDIUTIL, ["detach", mountPoint.path, "-force"])
        try? FileManager.default.removeItem(at: mountPoint)
        if let sanitized { try? FileManager.default.removeItem(at: sanitized) }
    }

    deinit { detach() }
}

enum IsoService {

    /// Resuelve una ruta relativa dentro de la ISO sin depender de mayúsculas: un ISO9660
    /// distingue «efi» de «EFI» y cada distro usa la suya (Debian `efi/`, Ubuntu `EFI/`).
    static func resolve(root: URL, _ rel: String) -> URL? {
        let fm = FileManager.default
        var current = root
        for part in rel.split(separator: "/") {
            let name = String(part)
            let direct = current.appendingPathComponent(name)
            if fm.fileExists(atPath: direct.path) { current = direct; continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: current.path),
                  let match = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { return nil }
            current = current.appendingPathComponent(match)
        }
        return current
    }

    static func inspect(root: URL, path: String, size: Int64) -> IsoInfo {
        let fm = FileManager.default
        func resolve(_ rel: String) -> URL? { IsoService.resolve(root: root, rel) }
        func exists(_ rel: String) -> Bool { resolve(rel) != nil }
        func fileSize(_ rel: String) -> Int64 {
            guard let url = resolve(rel) else { return 0 }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        let wim = resolve("sources/install.wim")
        let esd = resolve("sources/install.esd")
        let payload = wim ?? esd
        let payloadSize = payload.map { fileSize("sources/" + $0.lastPathComponent) } ?? 0

        var arch = "amd64"
        for (name, a) in [("bootx64.efi", "amd64"), ("bootia32.efi", "x86"), ("bootaa64.efi", "arm64")]
        where exists("efi/boot/\(name)") {
            arch = a
            break
        }

        var needsSplit = false
        var partCount = 0
        if let wim, payloadSize > FAT32_MAX_FILE {
            if let w = try? WimFile(url: wim),
               let parts = try? WimSplitter.planParts(w, maxPartSize: DEFAULT_PART_SIZE) {
                needsSplit = true
                partCount = parts.count
            }
        }

        var tree: Int64 = 0
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in en {
                if let s = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    tree += Int64(s)
                }
            }
        }

        let reactos = exists("loader/freeldr.sys") || exists("freeldr.ini")
            || exists("loader/isoboot.bin") || exists("reactos")
            || (exists("setup.exe") && exists("Windows/system32/ntoskrnl.exe"))

        return IsoInfo(
            path: path,
            size: size,
            isWindows: exists("bootmgr") || wim != nil || esd != nil,
            arch: arch,
            payloadName: payload?.lastPathComponent,
            payloadSize: payloadSize,
            needsSplit: needsSplit,
            partCount: partCount,
            treeSize: tree,
            hasBootmgr: exists("bootmgr"),
            hasEFI: exists("efi"),
            isHybrid: isHybrid(path: path),
            rawSize: rawSize(path: path),
            writesRaw: (path as NSString).pathExtension.lowercased() == "dmg",
            isMacInstaller: false,
            isReactOS: reactos,
            reactosLoader: reactos ? reactosEFILoader(root: root) : nil
        )
    }

    /// El gestor de arranque EFI que rEFInd debe encadenar. Se prefiere el que ReactOS/
    /// LiberNT instala con su propia marca (`efi/<nombre>/Boot/bootmgfw.efi`, con su BCD
    /// al lado); si no, el genérico `efi/BOOT/BOOTX64.EFI`. La grafía devuelta es la real
    /// del ISO9660, que distingue mayúsculas.
    static func reactosEFILoader(root: URL) -> String? {
        let fm = FileManager.default
        if let efi = resolve(root: root, "EFI"),
           let entries = try? fm.contentsOfDirectory(atPath: efi.path) {
            for name in entries where name.caseInsensitiveCompare("BOOT") != .orderedSame {
                guard let boot = resolve(root: root, "EFI/\(name)/Boot"),
                      let files = try? fm.contentsOfDirectory(atPath: boot.path) else { continue }
                if let m = files.first(where: { $0.caseInsensitiveCompare("bootmgfw.efi") == .orderedSame }) {
                    return "EFI/\(name)/Boot/\(m)"
                }
            }
            if let boot = resolve(root: root, "EFI/BOOT"),
               let files = try? fm.contentsOfDirectory(atPath: boot.path),
               let m = files.first(where: { $0.lowercased().hasSuffix("bootx64.efi") }) {
                return "EFI/BOOT/\(m)"
            }
        }
        return nil
    }

    // MARK: - Tipos de imagen

    /// Extensiones que se escriben byte a byte en vez de extraer su árbol.
    static let rawExtensions: Set<String> = ["img", "raw", "bin", "vhd", "wic"]
    /// Todo lo que el selector de archivos deja elegir además de `.iso`.
    static let imageExtensions = ["iso", "img", "dmg", "raw", "bin", "vhd", "wic"]

    static func extensionOf(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func createInstallMedia(in app: String) -> String {
        (app as NSString).appendingPathComponent("Contents/Resources/createinstallmedia")
    }

    /// Un "Install macOS …app" (cualquier .app con createinstallmedia dentro).
    static func isMacInstaller(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: createInstallMedia(in: path))
    }

    /// ¿La imagen trae MBR/GPT/DDM propios? Eso es lo que hace que un USB escrito tal
    /// cual arranque. Una ISO9660 "pelada" escrita en crudo no arranca: no tiene sector
    /// de arranque. La lectura es solo de los primeros 17 KB.
    static func isHybrid(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 34 * 512), data.count >= 512 else { return false }
        let b = [UInt8](data)
        if b[0] == 0x45, b[1] == 0x52 { return true }        // DDM "ER" (híbrida de Apple)
        if b[510] == 0x55, b[511] == 0xAA { return true }    // firma de MBR
        if data.count >= 520, data[512..<520].elementsEqual("EFI PART".utf8) { return true }  // GPT
        return false
    }

    /// Tamaño ya expandido: un .dmg comprimido ocupa bastante más al escribirlo.
    static func rawSize(path: String) -> Int64 {
        guard extensionOf(path) == "dmg" else { return fileSize(path) }
        let r = Shell.run(HDIUTIL, ["imageinfo", path], timeout: 180)
        for line in r.out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Total Bytes:") else { continue }
            let digits = t.dropFirst("Total Bytes:".count).trimmingCharacters(in: .whitespaces)
            if let v = Int64(digits) { return v }
        }
        return fileSize(path)
    }

    /// Un instalador de macOS se escribe con createinstallmedia, no extrayendo archivos.
    static func macInstallerInfo(path: String) -> IsoInfo {
        IsoInfo(path: path, size: fileSize(path), isWindows: false, arch: "—",
                payloadName: nil, payloadSize: 0, needsSplit: false, partCount: 0,
                treeSize: fileSize(path), hasBootmgr: false, hasEFI: false,
                isHybrid: false, rawSize: fileSize(path), writesRaw: false,
                isMacInstaller: true, isReactOS: false, reactosLoader: nil)
    }

    /// Imagen que no es ISO9660 (img/raw/bin/vhd): se escribe tal cual.
    static func rawImageInfo(path: String) -> IsoInfo {
        IsoInfo(path: path, size: fileSize(path), isWindows: false, arch: "—",
                payloadName: nil, payloadSize: 0, needsSplit: false, partCount: 0,
                treeSize: fileSize(path), hasBootmgr: false, hasEFI: false,
                isHybrid: isHybrid(path: path), rawSize: rawSize(path: path),
                writesRaw: true, isMacInstaller: false, isReactOS: false, reactosLoader: nil)
    }

    /// Monta, inspecciona, desmonta. Decide según el tipo de imagen.
    static func analyze(path: String) throws -> IsoInfo {
        let size = fileSize(path)

        if isMacInstaller(path) { return macInstallerInfo(path: path) }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw EngineError("esa carpeta no es un instalador de macOS: no encuentro "
                              + "Contents/Resources/createinstallmedia dentro")
        }

        if rawExtensions.contains(extensionOf(path)) { return rawImageInfo(path: path) }

        // .iso y .dmg: montables, así que se inspecciona el árbol de verdad. Un .dmg se
        // clasifica pero se escribirá en crudo, así que si no monta se trata como imagen.
        do {
            let iso = try MountedIso(path: path)
            defer { iso.detach() }
            return inspect(root: iso.mountPoint, path: path, size: size)
        } catch {
            if extensionOf(path) == "dmg" { return rawImageInfo(path: path) }
            throw error
        }
    }
}
