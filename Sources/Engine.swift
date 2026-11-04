import Foundation

enum Engine {
    typealias Progress = (Double, String) -> Void

    // MARK: - Entry points

    static func execute(job: Job, progress: @escaping Progress) throws {
        switch job.mode {
        case "dd": try writeDD(job: job, progress: progress)
        case "none": try formatOnly(job: job, progress: progress)
        case "loader": try writeLoader(job: job, progress: progress)
        case "macos": try writeMacOS(job: job, progress: progress)
        case "iso": try writeISO(job: job, progress: progress)
        case "reactos": try writeReactOS(job: job, progress: progress)
        default: try writeWindows(job: job, progress: progress)
        }
    }

    // MARK: - Embedded boot loader mode (MS-DOS, FreeDOS, Grub 2…)

    private static func writeLoader(job: Job, progress: @escaping Progress) throws {
        guard let entry = job.loader else {
            throw EngineError("no se indicó qué cargador instalar")
        }
        progress(0.02, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        let fs = job.fs ?? "FAT32"
        progress(0.08, "Formateando \(job.disk) como \(fs)")
        _ = try DiskService.erase(job.disk, label: job.label, scheme: job.scheme, fs: fs)
        guard let mountPath = DiskService.mountPoint(of: job.disk) else {
            throw EngineError("el volumen no se montó después de formatear")
        }
        let dest = URL(fileURLWithPath: mountPath)

        try Loaders.copyFiles(entry: entry, mount: dest,
                              progress: { f, m in progress(0.10 + 0.70 * f, m) })

        if job.extendedLabel ?? false { writeExtendedLabel(dest, label: job.label) }
        cleanJunk(dest)

        try Loaders.writeBootRecord(entry: entry, disk: job.disk, fat32: fs != "FAT",
                                    progress: { f, m in progress(0.82 + 0.08 * f, m) })
        try verifyIfNeeded(job: job, progress: progress, from: 0.90, to: 0.97)

        progress(0.99, "Expulsando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - "Non bootable" mode (format only)

    private static func formatOnly(job: Job, progress: @escaping Progress) throws {
        progress(0.03, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        progress(0.12, "Formateando \(job.disk) como \(job.fs ?? "FAT32")")
        _ = try DiskService.erase(job.disk, label: job.label, scheme: job.scheme, fs: job.fs ?? "FAT32")
        guard let mountPath = DiskService.mountPoint(of: job.disk) else {
            throw EngineError("el volumen no se montó después de formatear")
        }
        let dest = URL(fileURLWithPath: mountPath)
        if job.extendedLabel ?? false { writeExtendedLabel(dest, label: job.label) }
        cleanJunk(dest)

        try verifyIfNeeded(job: job, progress: progress, from: 0.30, to: 0.97)

        progress(0.99, "Expulsando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - Bad block check (read-back passes)

    private static func verifyIfNeeded(job: Job, progress: @escaping Progress,
                                       from: Double, to: Double) throws {
        let passes = job.verifyPasses ?? 0
        guard passes > 0 else { return }
        try DiskService.unmount(job.disk)

        let total = DiskService.size(of: job.disk)
        guard total > 0 else { return }
        let span = to - from

        for pass in 1...passes {
            let fd = open("/dev/r\(job.disk)", O_RDONLY)
            guard fd >= 0 else { throw EngineError("no puedo abrir /dev/r\(job.disk) para comprobar") }
            var offset: off_t = 0
            var bad: Int64 = 0
            var lastEmit: off_t = -1
            let chunk = 1 << 20
            let emitEvery: off_t = 64 << 20   // the UI polls the log; don't spam it
            var buf = [UInt8](repeating: 0, count: chunk)
            while offset < total {
                let want = Int(min(Int64(chunk), total - offset))
                let n = pread(fd, &buf, want, offset)
                if n != want { bad += Int64(want - max(n, 0)) }
                offset += off_t(want)
                if offset - lastEmit >= emitEvery || offset >= total {
                    lastEmit = offset
                    let f = Double(offset) / Double(total)
                    progress(from + span * ((Double(pass - 1) + f) / Double(passes)),
                             "Comprobando bloques (\(pass)/\(passes)) \(Fmt.pct(f))")
                }
            }
            close(fd)
            if bad > 0 {
                throw EngineError("se encontraron \(bad) bytes ilegibles: el dispositivo parece defectuoso")
            }
        }
    }

    // MARK: - Extended label and icon files

    /// Rufus writes autorun.inf + a small icon so the stick keeps its name and
    /// picture in Windows Explorer.
    static func writeExtendedLabel(_ dest: URL, label: String) {
        let ini = """
        [autorun]
        label=\(label)
        icon=autorun.ico

        """
        try? Data(ini.utf8).write(to: dest.appendingPathComponent("autorun.inf"))
        try? icoData().write(to: dest.appendingPathComponent("autorun.ico"))
    }

    /// Minimal 16x16 32-bpp ICO, drawn in code so nothing ships as a resource.
    static func icoData() -> Data {
        let w = 16, h = 16
        var out = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func i32(_ v: Int32)  { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        let pixels = w * h * 4
        let mask = ((w + 31) / 32) * 4 * h
        let imageSize = 40 + pixels + mask

        // ICONDIR
        u16(0); u16(1); u16(1)
        // ICONDIRENTRY
        out.append(UInt8(w)); out.append(UInt8(h))
        out.append(0); out.append(0)
        u16(1); u16(32)
        u32(UInt32(imageSize)); u32(22)
        // BITMAPINFOHEADER (height is doubled: XOR mask + AND mask)
        u32(40); i32(Int32(w)); i32(Int32(h * 2))
        u16(1); u16(32); u32(0); u32(UInt32(pixels)); i32(0); i32(0); u32(0); u32(0)
        // BGRA, bottom-up: a blue square with a white "R"-ish notch
        for y in (0..<h).reversed() {
            for x in 0..<w {
                let border = x == 0 || y == 0 || x == w - 1 || y == h - 1
                let stem = x >= 5 && x <= 7 && y >= 4 && y <= 11
                let bowl = (x >= 8 && x <= 10 && (y == 5 || y == 6 || y == 8 || y == 9))
                    && x <= 10
                let white = stem || bowl
                out.append(white ? 255 : UInt8(border ? 40 : 190))   // B
                out.append(white ? 255 : UInt8(border ? 60 : 120))   // G
                out.append(white ? 255 : UInt8(border ? 110 : 20))   // R
                out.append(255)                                       // A
            }
        }
        out.append(contentsOf: [UInt8](repeating: 0, count: mask))
        return out
    }

    // MARK: - Raw image mode

    private static func writeDD(job: Job, progress: @escaping Progress) throws {
        // Un .dmg comprimido no es una imagen cruda: hdiutil lo expande a UDRW, que sí lo
        // es, y es eso lo que se escribe byte a byte.
        var source = job.iso
        var temp: String?
        defer { if let temp { try? FileManager.default.removeItem(atPath: temp) } }

        if IsoService.extensionOf(source) == "dmg" {
            progress(0.01, "Expandiendo el .dmg a imagen cruda")
            let out = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("rufusmac-\(UInt32.random(in: 0...UInt32.max)).dmg")
            let r = Shell.run(HDIUTIL, ["convert", source, "-format", "UDRW", "-o", out], timeout: 3600)
            guard r.ok, FileManager.default.fileExists(atPath: out) else {
                throw EngineError("no pude convertir el .dmg: \(r.combined)")
            }
            source = out
            temp = out
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: source)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let diskSize = DiskService.size(of: job.disk)
        if diskSize > 0 && total > diskSize {
            throw EngineError("la imagen (\(Fmt.bytes(total))) no cabe en \(job.disk)")
        }

        progress(0.02, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        progress(0.05, "Escribiendo en /dev/r\(job.disk)")
        let fd = open("/dev/r\(job.disk)", O_WRONLY)
        guard fd >= 0 else { throw EngineError("no puedo abrir /dev/r\(job.disk) para escritura") }
        defer { close(fd) }

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        var written: Int64 = 0
        while true {
            guard let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw EngineError("error de escritura en el dispositivo") }
            written += Int64(n)
            progress(0.05 + 0.93 * (Double(written) / Double(max(total, 1))),
                     "Escribiendo \(Fmt.bytes(written)) de \(Fmt.bytes(total))")
        }
        fsync(fd)
        progress(0.99, "Sincronizando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - ISO image mode (extraer el árbol, como el «ISO Image mode» de Rufus)

    /// Formatea en FAT32 y copia los archivos de la ISO. El arranque lo dan los propios
    /// ficheros de la ISO: el firmware UEFI carga `/EFI/BOOT/BOOTX64.EFI` del volumen, que
    /// ya está copiado, y desde ahí la ISO se arranca sola. Para BIOS antiguo el camino es
    /// el modo DD (la ISO híbrida trae su propio MBR).
    private static func writeISO(job: Job, progress: @escaping Progress) throws {
        progress(0.01, "Montando \(URL(fileURLWithPath: job.iso).lastPathComponent)")
        let iso = try MountedIso(path: job.iso)
        defer { iso.detach() }

        let info = IsoService.inspect(root: iso.mountPoint, path: job.iso,
                                      size: IsoService.fileSize(job.iso))
        guard info.hasEFI else {
            throw EngineError("esta ISO no trae arranque EFI (no hay carpeta efi/): en modo "
                              + "ISO el USB no arrancaría. Escribe en modo DD.")
        }

        let diskSize = DiskService.size(of: job.disk)
        if diskSize > 0 && info.treeSize > Int64(Double(diskSize) * 0.98) {
            throw EngineError("no cabe: la ISO ocupa \(Fmt.bytes(info.treeSize)) y el disco tiene \(Fmt.bytes(diskSize))")
        }
        let oversize = try findOversize(root: iso.mountPoint)
        guard oversize.isEmpty else {
            throw EngineError("FAT32 no admite archivos de más de 4 GiB: "
                              + oversize.map { $0.lastPathComponent }.joined(separator: ", ")
                              + ". Escribe esta ISO en modo DD.")
        }

        progress(0.04, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        progress(0.06, "Formateando /dev/\(job.disk) como FAT32")
        _ = try DiskService.erase(job.disk, label: job.label, scheme: job.scheme, fs: "FAT32")
        guard let mountPath = DiskService.mountPoint(of: job.disk) else {
            throw EngineError("el volumen no se montó después de formatear")
        }
        let dest = URL(fileURLWithPath: mountPath)
        let free = DiskService.freeBytes(of: mountPath)
        guard free >= info.treeSize else {
            throw EngineError("no cabe: hay \(Fmt.bytes(free)) libres y la ISO ocupa \(Fmt.bytes(info.treeSize))")
        }

        progress(0.10, "Copiando archivos")
        let toCopy = try totalToCopy(root: iso.mountPoint, skip: [])
        var copied: Int64 = 0
        try copyTree(from: iso.mountPoint, to: dest, skip: []) { bytes in
            copied += Int64(bytes)
            let f = Double(copied) / Double(max(toCopy, 1))
            progress(0.10 + 0.80 * min(f, 1.0),
                     "Copiando \(Fmt.bytes(copied)) de \(Fmt.bytes(toCopy))")
        }

        cleanJunk(dest)
        if job.extendedLabel ?? false {
            progress(0.92, "Escribiendo etiqueta extendida e icono")
            writeExtendedLabel(dest, label: job.label)
        }

        try verifyIfNeeded(job: job, progress: progress, from: 0.94, to: 0.98)
        progress(0.99, "Expulsando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - ReactOS / LiberNT en el EFI de Apple

    /// Un ReactOS/LiberNT no arranca en un Mac escrito tal cual (el EFI de Apple no lee
    /// una ISO híbrida El Torito). Aquí se monta la disposición que sí arranca: GPT con
    /// ESP + FAT32, el árbol completo copiado y rEFInd como cargador de reserva, que
    /// encadena el gestor de arranque que ya trae el propio ReactOS.
    private static func writeReactOS(job: Job, progress: @escaping Progress) throws {
        progress(0.01, "Montando \(URL(fileURLWithPath: job.iso).lastPathComponent)")
        let iso = try MountedIso(path: job.iso)
        defer { iso.detach() }

        let info = IsoService.inspect(root: iso.mountPoint, path: job.iso,
                                      size: IsoService.fileSize(job.iso))
        guard info.isReactOS else {
            throw EngineError("esta imagen no parece ReactOS: no trae freeldr.ini, "
                              + "loader/freeldr.sys ni una carpeta reactos/")
        }

        let diskSize = DiskService.size(of: job.disk)
        if diskSize > 0 && info.treeSize > Int64(Double(diskSize) * 0.96) {
            throw EngineError("no cabe: la imagen ocupa \(Fmt.bytes(info.treeSize)) y el disco tiene \(Fmt.bytes(diskSize))")
        }
        let oversize = try findOversize(root: iso.mountPoint)
        guard oversize.isEmpty else {
            throw EngineError("FAT32 no admite archivos de más de 4 GiB: "
                              + oversize.map { $0.lastPathComponent }.joined(separator: ", "))
        }

        progress(0.04, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        // GPT: diskutil crea siempre la ESP (EF00, ~200 MB) y deja el resto para el
        // volumen de datos, que es lo que el EFI de Apple necesita para mirar aquí.
        progress(0.06, "Creando GPT con ESP + FAT32 en /dev/\(job.disk)")
        _ = try DiskService.erase(job.disk, label: job.label, scheme: "GPT", fs: "FAT32")
        guard let mountPath = DiskService.dataMountPoint(of: job.disk) else {
            throw EngineError("el volumen de datos no se montó después de formatear")
        }
        let dest = URL(fileURLWithPath: mountPath)

        progress(0.10, "Copiando el árbol de \(info.fileName)")
        let toCopy = try totalToCopy(root: iso.mountPoint, skip: [])
        var copied: Int64 = 0
        try copyTree(from: iso.mountPoint, to: dest, skip: []) { bytes in
            copied += Int64(bytes)
            let f = Double(copied) / Double(max(toCopy, 1))
            progress(0.10 + 0.58 * min(f, 1.0),
                     "Copiando \(Fmt.bytes(copied)) de \(Fmt.bytes(toCopy))")
        }

        progress(0.70, "Preparando el cargador de ReactOS")
        var loaderRel = info.reactosLoader ?? "EFI/BOOT/BOOTX64.EFI"
        loaderRel = try ReactOSLayout.relocateFallbackLoader(volume: dest, loaderRel: loaderRel)

        progress(0.76, "Instalando rEFInd")
        try ReactOSLayout.installRefind(on: dest, label: job.label, loaderRel: loaderRel) { f, m in
            progress(0.76 + 0.16 * f, m)
        }
        progress(0.93, "Copiando rEFInd a la partición EFI")
        _ = ReactOSLayout.installRefindOnESP(disk: job.disk, label: job.label, loaderRel: loaderRel)

        cleanJunk(dest)
        if job.extendedLabel ?? false { writeExtendedLabel(dest, label: job.label) }

        try verifyIfNeeded(job: job, progress: progress, from: 0.95, to: 0.98)
        progress(0.99, "Expulsando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - macOS installer mode (createinstallmedia)

    private static func writeMacOS(job: Job, progress: @escaping Progress) throws {
        let installer = (job.installer?.isEmpty == false ? job.installer! : job.iso)
        let cim = IsoService.createInstallMedia(in: installer)
        guard FileManager.default.isExecutableFile(atPath: cim) else {
            throw EngineError("\(URL(fileURLWithPath: installer).lastPathComponent) "
                              + "no trae Contents/Resources/createinstallmedia")
        }

        progress(0.02, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        let label = String((job.label.isEmpty ? "OSXINSTALL" : job.label).uppercased().prefix(11))
        progress(0.06, "Formateando /dev/\(job.disk) como HFS+ (GUID)")
        let erase = Shell.run(DISKUTIL, ["eraseDisk", "JHFS+", label.isEmpty ? "OSXINSTALL" : label,
                                         "GPT", "/dev/\(job.disk)"])
        guard erase.ok else {
            throw EngineError("no pude formatear /dev/\(job.disk): \(erase.combined)")
        }
        guard let mount = DiskService.mountPoint(of: job.disk) else {
            throw EngineError("el volumen no se montó después de formatear")
        }

        progress(0.10, "createinstallmedia → \(mount)")
        let start = Date()
        let r = Shell.stream(cim, ["--volume", mount, "--nointeraction"], timeout: 7200) { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            // createinstallmedia no da porcentaje: se avanza por tiempo hasta el 95 %.
            let t = min(1.0, Date().timeIntervalSince(start) / 600.0)
            progress(0.10 + 0.85 * t, text)
        }
        guard r.ok else {
            let tail = r.combined.split(separator: "\n").suffix(3).joined(separator: " · ")
            throw EngineError("createinstallmedia falló: \(tail)")
        }

        progress(0.99, "Expulsando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - Windows mode

    private static func writeWindows(job: Job, progress: @escaping Progress) throws {
        progress(0.01, "Montando \(URL(fileURLWithPath: job.iso).lastPathComponent)")
        let iso = try MountedIso(path: job.iso)
        defer { iso.detach() }

        let attrs = try FileManager.default.attributesOfItem(atPath: job.iso)
        let isoSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let info = IsoService.inspect(root: iso.mountPoint, path: job.iso, size: isoSize)

        guard info.isWindows else {
            throw EngineError("esta ISO no parece de Windows (no hay bootmgr ni install.wim)")
        }
        guard info.payloadName != nil else {
            throw EngineError("la ISO no contiene sources/install.wim ni install.esd")
        }

        progress(0.04, "Analizando contenido")
        let diskSize = DiskService.size(of: job.disk)
        if diskSize > 0 && info.treeSize > Int64(Double(diskSize) * 0.98) {
            throw EngineError("no cabe: la ISO ocupa \(Fmt.bytes(info.treeSize)) y el disco tiene \(Fmt.bytes(diskSize))")
        }

        let oversize = try findOversize(root: iso.mountPoint)
        let wimPath = iso.mountPoint.appendingPathComponent("sources/install.wim")
        var splitNeeded = false
        if !oversize.isEmpty {
            let blocking = oversize.filter { $0.path != wimPath.path }
            guard blocking.isEmpty else {
                throw EngineError("hay archivos de más de 4 GiB que no se pueden partir: "
                                  + blocking.map { $0.lastPathComponent }.joined(separator: ", "))
            }
            splitNeeded = true
        }

        progress(0.06, "Desmontando /dev/\(job.disk)")
        try DiskService.unmount(job.disk)

        progress(0.08, "Formateando \(job.disk) como \(job.fs ?? "FAT32")")
        _ = try DiskService.erase(job.disk, label: job.label, scheme: job.scheme, fs: job.fs ?? "FAT32")
        guard let mountPath = DiskService.mountPoint(of: job.disk) else {
            throw EngineError("el volumen no se montó después de formatear")
        }
        let dest = URL(fileURLWithPath: mountPath)

        // --- copy ---
        progress(0.10, "Copiando archivos")
        let skipRel: Set<String> = splitNeeded ? ["sources/install.wim"] : []
        let toCopy = try totalToCopy(root: iso.mountPoint, skip: skipRel)
        var copied: Int64 = 0
        let copyStart = 0.10, copyEnd = 0.72
        try copyTree(from: iso.mountPoint, to: dest, skip: skipRel) { bytes in
            copied += Int64(bytes)
            let f = Double(copied) / Double(max(toCopy, 1))
            progress(copyStart + (copyEnd - copyStart) * min(f, 1.0),
                     "Copiando \(Fmt.bytes(copied)) de \(Fmt.bytes(toCopy))")
        }

        // --- split install.wim ---
        if splitNeeded {
            progress(copyEnd, "Partiendo install.wim")
            let wim = try WimFile(url: wimPath)
            let total = Int64(wim.entries.reduce(0) { $0 + Int($1.res.size) })
            var done: Int64 = 0
            _ = try WimSplitter.split(wim: wim,
                                      into: dest.appendingPathComponent("sources"),
                                      progress: { n in
                                          done += Int64(n)
                                          let f = Double(done) / Double(max(total, 1))
                                          progress(copyEnd + 0.21 * min(f, 1.0),
                                                   "Partiendo install.wim (\(Fmt.pct(min(f, 1.0))))")
                                      },
                                      log: { _ in })
            progress(0.93, "install.wim partido en \(info.partCount) trozos")
        }

        // --- bypass ---
        if job.bypass {
            progress(0.95, "Escribiendo autounattend.xml")
            // Data.write, not String.write: the latter sets com.apple.TextEncoding,
            // which FAT32 materialises as a stray "._autounattend.xml" AppleDouble file
            let xml = Data(autoUnattend(arch: info.arch).utf8)
            try xml.write(to: dest.appendingPathComponent("autounattend.xml"))
        }

        cleanJunk(dest)

        if job.extendedLabel ?? false {
            progress(0.96, "Escribiendo etiqueta extendida e icono")
            writeExtendedLabel(dest, label: job.label)
        }

        if job.legacy {
            progress(0.97, "Aplicando arranque BIOS legacy")
            try applyLegacyBoot(disk: job.disk, isoRoot: iso.mountPoint)
        }

        try verifyIfNeeded(job: job, progress: progress, from: 0.97, to: 0.99)

        progress(0.99, "Expulsando")
        DiskService.eject(job.disk)
        progress(1.0, "Listo")
    }

    // MARK: - Helpers

    static func findOversize(root: URL) throws -> [URL] {
        var bad: [URL] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in en {
                if let s = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   Int64(s) > FAT32_MAX_FILE {
                    bad.append(url)
                }
            }
        }
        return bad
    }

    static func totalToCopy(root: URL, skip: Set<String>) throws -> Int64 {
        var total: Int64 = 0
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let url as URL in en {
            let rel = relative(url, to: root)
            if skip.contains(rel) { continue }
            if let s = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    static func relative(_ url: URL, to root: URL) -> String {
        // /var is a symlink to /private/var: comparing raw paths silently breaks
        // and every file ends up flat at the root of the stick.
        let rootComps = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComps = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComps.count > rootComps.count,
              Array(urlComps.prefix(rootComps.count)) == rootComps else {
            return url.lastPathComponent
        }
        return urlComps.dropFirst(rootComps.count).joined(separator: "/")
    }

    /// Copia el contenido del fichero a mano, sin `copyItem`: ese arrastra los xattrs del
    /// origen (FinderInfo), que en FAT32 se materializan como ficheros "._", y falla con
    /// ficheros de 0 bytes con atributos como el `.disk/*.uuid` de las ISOs live.
    static func copyFileData(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)

        let fd = open(dst.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw EngineError("no pude crear \(dst.lastPathComponent): "
                              + String(cString: strerror(errno)))
        }
        defer { close(fd) }

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }

        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            var off = 0
            while off < chunk.count {
                let n = chunk.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                    write(fd, p.baseAddress!.advanced(by: off), chunk.count - off)
                }
                if n <= 0 {
                    throw EngineError("no pude escribir \(dst.lastPathComponent): "
                                      + String(cString: strerror(errno)))
                }
                off += n
            }
        }
    }

    static func copyTree(from root: URL, to dest: URL, skip: Set<String>, onBytes: (Int) -> Void) throws {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            throw EngineError("no puedo leer el contenido de la ISO")
        }
        for case let url as URL in en {
            let rel = relative(url, to: root)
            if skip.contains(rel) { continue }
            // Basura de macOS: no se copia, así ni se traduce a "._" en FAT32.
            let name = url.lastPathComponent
            if name.hasPrefix("._") { continue }
            if [".DS_Store", ".fseventsd", ".Spotlight-V100",
                ".Trashes", ".TemporaryItems"].contains(name) { continue }
            let target = dest.appendingPathComponent(rel)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                do { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                catch {
                    throw EngineError("no pude crear la carpeta \(rel): \(error.localizedDescription)")
                }
            } else {
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                } catch {
                    throw EngineError("no pude crear la carpeta \(rel): \(error.localizedDescription)")
                }
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                do {
                    try copyFileData(from: url, to: target)
                } catch {
                    throw EngineError("no pude copiar \(rel) (origen \(url.path)): \(error.localizedDescription)")
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                onBytes(size)
            }
        }
    }

    static func cleanJunk(_ mount: URL) {
        for name in [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"] {
            try? FileManager.default.removeItem(at: mount.appendingPathComponent(name))
        }
        // AppleDouble ("._foo") y basura de macOS: aparecen al copiar xattrs a FAT32. El
        // enumerador de Foundation se salta los ficheros ocultos, así que se barre con find
        // (y dot_clean de propina, que es lo que usa macOS para esto).
        _ = Shell.run("/usr/sbin/dot_clean", ["-m", mount.path])
        _ = Shell.run("/usr/bin/find", [
            mount.path,
            "(", "-name", "._*", "-o", "-name", ".DS_Store",
            "-o", "-name", ".fseventsd", "-o", "-name", ".Spotlight-V100",
            "-o", "-name", ".Trashes", "-o", "-name", ".TemporaryItems", ")",
            "-exec", "rm", "-rf", "{}", "+",
        ])
    }

    // MARK: - Windows 11 bypass

    static func autoUnattend(arch: String) -> String {
        let keys = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"]
        let commands = keys.enumerated().map { i, key in
            """
                        <RunSynchronousCommand wcm:action="add">
                            <Order>\(i + 1)</Order>
                            <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(key) /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup"
                           processorArchitecture="\(arch)"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS"
                           xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                    <RunSynchronous>
        \(commands)
                    </RunSynchronous>
                </component>
            </settings>
        </unattend>
        """
    }

    // MARK: - Legacy BIOS boot

    /// Writes boot/etfsboot.com as the VBR while keeping the FAT32 BPB, then marks
    /// the partition active. Without preserving 0x03..0x59 the filesystem dies.
    static func applyLegacyBoot(disk: String, isoRoot: URL) throws {
        let etfsURL = isoRoot.appendingPathComponent("boot/etfsboot.com")
        guard let etfs = try? Data(contentsOf: etfsURL), etfs.count >= 512 else {
            throw EngineError("la ISO no trae un boot/etfsboot.com utilizable")
        }
        guard let partID = DiskService.partitionID(of: disk) else {
            throw EngineError("no encontré la partición de \(disk)")
        }

        try DiskService.unmount(disk)

        var lastError: Error?
        for _ in 0..<8 {
            do {
                let original = try readBytes("/dev/r\(partID)", count: 512, at: 0)
                var merged = [UInt8](etfs.prefix(2048))
                while merged.count < 2048 { merged.append(0) }
                for i in 0x03..<0x5A { merged[i] = original[i] }
                merged[510] = 0x55
                merged[511] = 0xAA
                try writeBytes("/dev/r\(partID)", bytes: merged, at: 0)

                var mbr = try readBytes("/dev/r\(disk)", count: 512, at: 0)
                guard mbr[510] == 0x55, mbr[511] == 0xAA else {
                    throw EngineError("el MBR no tiene la firma esperada")
                }
                mbr[0x1BE] = 0x80
                try writeBytes("/dev/r\(disk)", bytes: mbr, at: 0)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        throw EngineError("no pude escribir el sector de arranque: \(lastError?.localizedDescription ?? "?")")
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
        guard fd >= 0 else { throw EngineError("no puedo abrir \(path) para escritura") }
        defer { close(fd) }
        let n = pwrite(fd, bytes, bytes.count, offset)
        guard n == bytes.count else { throw EngineError("escritura corta en \(path)") }
        fsync(fd)
    }
}
