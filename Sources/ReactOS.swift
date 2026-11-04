import Foundation

/// Disposición de arranque de ReactOS/LiberNT para el EFI de Apple.
///
/// Un `bootcd.iso` de ReactOS es una ISO híbrida con un MBR propio (tipo 0x96) y su
/// cargador El Torito: escrita tal cual arranca en un PC BIOS, pero el EFI de un Mac no
/// la lee así — no entiende El Torito sobre un disco USB y solo mira particiones GPT con
/// un `\EFI\BOOT\BOOTX64.EFI`. Lo que sí arranca en un Mac es: GPT + ESP + una partición
/// FAT32 con el árbol completo del ISO + rEFInd como cargador de reserva, que encadena el
/// gestor de arranque que trae el propio ReactOS.
///
/// Esto reproduce paso a paso lo que se hizo a mano con el MacBook Pro 5,3 y LiberNT.
enum ReactOSLayout {

    static let refindVersion = "0.14.2"
    static let refindURL =
        "https://sourceforge.net/projects/refind/files/\(refindVersion)/refind-bin-\(refindVersion).zip/download"

    // MARK: - rEFInd: obtener y cachear

    /// Deja rEFInd en la caché de cargadores y devuelve el directorio con
    /// `refind_x64.efi` + `icons/`. Si ya está, no descarga nada.
    static func ensureRefind(progress: (Double, String) -> Void) throws -> URL {
        let fm = FileManager.default
        let root = Loaders.cacheRoot().appendingPathComponent("refind-\(refindVersion)", isDirectory: true)
        let binary = root.appendingPathComponent("refind_x64.efi")
        if fm.fileExists(atPath: binary.path) { return root }

        let zip = fm.temporaryDirectory.appendingPathComponent("rufusmac-refind-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zip) }

        progress(0.02, "Descargando rEFInd \(refindVersion)")
        let dl = Shell.run("/usr/bin/curl",
                           ["-fsSL", "--retry", "3", "--max-time", "180", "-o", zip.path, refindURL],
                           timeout: 300)
        guard dl.ok else {
            throw EngineError("no pude descargar rEFInd: "
                              + (dl.combined.isEmpty ? "sin conexión" : dl.combined))
        }

        let ext = fm.temporaryDirectory.appendingPathComponent("rufusmac-refind-\(UUID().uuidString)")
        try? fm.removeItem(at: ext)
        try fm.createDirectory(at: ext, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ext) }

        progress(0.05, "Descomprimiendo rEFInd")
        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, ext.path], timeout: 300)
        guard unzip.ok, let src = findFile(named: "refind_x64.efi", under: ext) else {
            throw EngineError("el paquete de rEFInd no trae refind_x64.efi")
        }
        let pkg = src.deletingLastPathComponent()

        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: binary)
        for sub in ["icons"] where fm.fileExists(atPath: pkg.appendingPathComponent(sub).path) {
            try copyDirNoMetadata(pkg.appendingPathComponent(sub), root.appendingPathComponent(sub))
        }
        return root
    }

    // MARK: - Instalación en un volumen

    /// Instala rEFInd en `volume`: `EFI/refind/` (binario + iconos + configuración) y el
    /// cargador de reserva `EFI/BOOT/BOOTX64.EFI`, que es el único camino que el firmware
    /// busca por sí solo. `loaderRel` es el cargador de ReactOS que rEFInd encadenará.
    static func installRefind(on volume: URL, label: String, loaderRel: String,
                              progress: (Double, String) -> Void) throws {
        let fm = FileManager.default
        let pkg = try ensureRefind(progress: progress)

        progress(0.60, "Copiando rEFInd al USB")
        let refindDir = volume.appendingPathComponent("EFI/refind", isDirectory: true)
        try fm.createDirectory(at: refindDir, withIntermediateDirectories: true)

        let binary = refindDir.appendingPathComponent("refind_x64.efi")
        try? fm.removeItem(at: binary)
        try fm.copyItem(at: pkg.appendingPathComponent("refind_x64.efi"), to: binary)

        let iconsSrc = pkg.appendingPathComponent("icons")
        if fm.fileExists(atPath: iconsSrc.path) {
            try copyDirNoMetadata(iconsSrc, refindDir.appendingPathComponent("icons"))
        }

        // Cargador de reserva: el firmware solo encuentra \EFI\BOOT\BOOTX64.EFI.
        let bootDir = volume.appendingPathComponent("EFI/BOOT", isDirectory: true)
        try fm.createDirectory(at: bootDir, withIntermediateDirectories: true)
        let fallback = bootDir.appendingPathComponent("BOOTX64.EFI")
        try? fm.removeItem(at: fallback)
        try fm.copyItem(at: pkg.appendingPathComponent("refind_x64.efi"), to: fallback)

        progress(0.90, "Escribiendo refind.conf")
        try Data(config(label: label, loaderRel: loaderRel).utf8)
            .write(to: refindDir.appendingPathComponent("refind.conf"))
    }

    /// Copia de seguridad en la ESP (EF00). El motor corre como root, así que la ESP
    /// monta; si el montaje falla, no es fatal: el cargador de reserva ya está en la
    /// partición de datos. No lanza error.
    @discardableResult
    static func installRefindOnESP(disk: String, label: String, loaderRel: String) -> Bool {
        let fm = FileManager.default
        guard let esp = DiskService.partitionIDs(of: disk).first else { return false }
        _ = Shell.run(DISKUTIL, ["mount", "/dev/\(esp)"])
        guard let mp = DiskService.mountPoint(ofPartition: esp),
              !mp.isEmpty,
              let pkg = try? ensureRefind(progress: { _, _ in }),
              let binary = try? Data(contentsOf: pkg.appendingPathComponent("refind_x64.efi"))
        else {
            _ = Shell.run(DISKUTIL, ["unmount", "/dev/\(esp)"])
            return false
        }
        defer { _ = Shell.run(DISKUTIL, ["unmount", "/dev/\(esp)"]) }

        let vol = URL(fileURLWithPath: mp)
        let refindDir = vol.appendingPathComponent("EFI/refind", isDirectory: true)
        let bootDir = vol.appendingPathComponent("EFI/BOOT", isDirectory: true)
        do {
            try fm.createDirectory(at: refindDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: bootDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: refindDir.appendingPathComponent("refind_x64.efi"))
            try binary.write(to: refindDir.appendingPathComponent("refind_x64.efi"))
            try? fm.removeItem(at: bootDir.appendingPathComponent("BOOTX64.EFI"))
            try binary.write(to: bootDir.appendingPathComponent("BOOTX64.EFI"))
            try Data(config(label: label, loaderRel: loaderRel).utf8)
                .write(to: refindDir.appendingPathComponent("refind.conf"))
            return true
        } catch {
            return false
        }
    }

    // MARK: - El cargador de reserva original

    /// Si el cargador de ReactOS vive en `EFI/BOOT` (el sitio que rEFInd necesita),
    /// se mueve el contenido entero a `EFI/ReactOS/Boot/` —con su BCD al lado, que el
    /// gestor de arranque busca junto a sí mismo— y se devuelve la ruta nueva. Si el
    /// cargador ya estaba en su propia carpeta, se devuelve sin tocar nada.
    static func relocateFallbackLoader(volume: URL, loaderRel: String) throws -> String {
        let fm = FileManager.default
        guard loaderRel.lowercased() == "efi/boot/bootx64.efi" else { return loaderRel }
        guard let bootDir = IsoService.resolve(root: volume, "EFI/BOOT") else { return loaderRel }

        let dest = volume.appendingPathComponent("EFI/ReactOS/Boot", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let entries = (try? fm.contentsOfDirectory(at: bootDir, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let isBootx64 = entry.lastPathComponent.caseInsensitiveCompare("BOOTX64.EFI") == .orderedSame
            let target = dest.appendingPathComponent(isBootx64 ? "bootmgfw.efi" : entry.lastPathComponent)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: entry, to: target)
        }
        return "EFI/ReactOS/Boot/bootmgfw.efi"
    }

    // MARK: - Configuración

    static func config(label: String, loaderRel: String) -> String {
        let name = label.isEmpty ? "REACTOS" : label
        let quoted = "\"\(name.replacingOccurrences(of: "\"", with: ""))\""
        let loader = loaderRel.hasPrefix("/") ? loaderRel : "/" + loaderRel
        return """
        # Generado por RufusMac — arranque de ReactOS/LiberNT en el EFI de un Mac.
        # rEFInd vive en EFI/refind y como cargador de reserva en EFI/BOOT/BOOTX64.EFI;
        # encadena el gestor de arranque que trae el propio ReactOS.
        timeout 20
        default_selection \(quoted)
        scanfor manual,internal,external,optical
        use_nvram false

        menuentry \(quoted) {
            volume \(quoted)
            ostype Windows
            icon EFI/refind/icons/os_win8.png
            loader \(loader)
        }
        """
    }

    // MARK: - Ayudantes

    static func findFile(named name: String, under root: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == name { return url }
        return nil
    }

    /// Copia recursiva sin metadatos: `copyItem` arrastra FinderInfo, que en FAT32 se
    /// materializa como ficheros "._" al lado de cada uno.
    static func copyDirNoMetadata(_ src: URL, _ dst: URL) throws {
        try? FileManager.default.removeItem(at: dst)
        let r = Shell.run("/usr/bin/ditto", ["--norsrc", "--noextattr", src.path, dst.path], timeout: 120)
        guard r.ok else { throw EngineError("no pude copiar \(src.lastPathComponent): \(r.combined)") }
    }
}
