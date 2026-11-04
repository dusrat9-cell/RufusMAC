import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RufusModel: ObservableObject {

    // MARK: devices
    @Published var disks: [DiskInfo] = []
    @Published var selectedDisk: String?

    // MARK: image
    @Published var iso: IsoInfo?
    @Published var isoLoading = false
    @Published var isoError: String?
    @Published var recentISOs: [String] = []
    @Published var bootMode = "ISO"
    @Published var bootEntry = RufusModel.bootEntries[3]

    /// The exact list Rufus 3.10 shows in the "Boot selection" combo.
    static let bootEntries = [
        "No arrancable",
        "MS-DOS",
        "FreeDOS",
        "Imagen de disco o ISO (seleccionar)",
        "Syslinux 4.07",
        "Syslinux 6.04",
        "ReactOS",
        "Grub 2.04",
        "Grub4DOS 0.4.6a",
        "UEFI:NTFS"
    ]

    /// Entries whose payload ships inside the Rufus binary (x86 assembly / 16-bit).
    static let embeddedLoaders = [
        "MS-DOS", "FreeDOS", "Syslinux 4.07", "Syslinux 6.04",
        "ReactOS", "Grub 2.04", "Grub4DOS 0.4.6a", "UEFI:NTFS"
    ]

    // MARK: drive properties
    @Published var targetSystem = "BIOS o UEFI"
    @Published var listUSBHardDrives = false
    @Published var fixOldBIOS = true
    @Published var useRufusMBR = false
    @Published var biosID = "0x80 (predeterminado)"
    @Published var showAdvancedDrive = true
    @Published var persistentGB: Double = 0

    // MARK: format options
    @Published var label = "WININSTALL"
    @Published var fileSystem = "FAT32 (predeterminado)"
    @Published var clusterSize = "4096 bytes (predeterminado)"
    @Published var showAdvancedFormat = false
    @Published var quickFormat = true
    @Published var createExtendedLabel = true
    @Published var checkBadBlocks = false
    @Published var badBlocksPasses = "1 pasada"

    // MARK: run state
    @Published var running = false
    @Published var progress: Double = 0
    @Published var status = "READY"
    @Published var log: [String] = []
    @Published var errorMessage: String?
    @Published var confirmPending = false
    @Published var showImporter = false
    @Published var showLog = false
    @Published var showAbout = false
    @Published var elapsed: TimeInterval = 0

    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var logURL: URL?
    private var startedAt: Date?

    // MARK: - Derived

    var scheme: String { targetSystem == "Solo UEFI" ? "GPT" : "MBR" }

    /// Legacy BIOS boot: either the target is BIOS-only, or the old-BIOS fix is on.
    var legacyBoot: Bool { targetSystem == "Solo BIOS" || (targetSystem != "Solo UEFI" && fixOldBIOS) }

    var jobMode: String {
        if bootEntry == "No arrancable" { return "none" }
        if loaderKind != nil { return "loader" }
        guard let iso else { return "windows" }
        if iso.isMacInstaller { return "macos" }
        if iso.isReactOS { return scheme == "GPT" ? "reactos" : "dd" }
        if iso.writesRaw { return "dd" }
        if iso.isWindows { return "windows" }
        return bootMode == "DD" ? "dd" : "iso"
    }

    /// Aviso honesto: una imagen sin MBR/GPT propia, escrita tal cual, no arranca; y una
    /// sin carpeta efi/ no arranca en modo ISO.
    var imageWarning: String? {
        guard let iso, wantsISO, !iso.isWindows, !iso.isMacInstaller else { return nil }
        if jobMode == "iso", !iso.hasEFI {
            return "«\(iso.fileName)» no trae arranque EFI (no hay carpeta efi/): en modo "
                 + "ISO el USB no arrancaría. Usa el modo DD."
        }
        guard jobMode == "dd", !iso.isHybrid else { return nil }
        return "«\(iso.fileName)» no es híbrida: no trae MBR ni GPT, así que escrita tal "
             + "cual no arrancará por USB. Las ISOs híbridas (Debian, Ubuntu, Arch, Fedora…) sí."
    }

    // MARK: - Diálogo ISOHybrid

    @Published var showHybridAlert = false
    @Published var hybridName = ""

    /// Elección del cuadro «ISO híbrida detectada», como el de Rufus.
    func chooseHybridMode(isoMode: Bool) {
        bootMode = isoMode ? "ISO" : "DD"
        showHybridAlert = false
    }

    /// True when the combo is on "Disk or ISO image (Please select)" — o en la entrada
    /// «ReactOS», que es lo mismo (una ISO de ReactOS es una imagen de disco).
    var wantsISO: Bool { bootEntry.hasPrefix("Imagen de disco") || bootEntry == "ReactOS" }

    /// Aviso honesto sobre el arranque de ReactOS/LiberNT en un Mac.
    var reactosNote: String? {
        guard let iso, iso.isReactOS else { return nil }
        if scheme != "GPT" {
            return "«\(iso.fileName)» es ReactOS/LiberNT. El EFI de un Mac no arranca su "
                 + "ISO híbrida: elige «Solo UEFI» para montar GPT + ESP + rEFInd + el árbol."
        }
        return "ReactOS/LiberNT en GPT: se creará la ESP, se copiará el árbol completo en "
             + "FAT32 y se instalará rEFInd como cargador de reserva. Sin esto, un Mac no "
             + "arranca la ISO."
    }

    /// Non-nil when the entry is one of the embedded boot loaders.
    var loaderKind: Loaders.Kind? { Loaders.spec(for: bootEntry)?.kind }

    /// Loaders that Rufus builds from its own code and we can reproduce.
    var loaderSupported: Bool {
        switch loaderKind {
        case .dos?, .grub2?: return true
        default: return false
        }
    }

    /// Calm explanation for the entries we cannot reproduce yet.
    var loaderNote: String? {
        switch loaderKind {
        case .needsInstaller(let why)?: return why
        default: return nil
        }
    }

    var fsName: String {
        if fileSystem.hasPrefix("exFAT") { return "exFAT" }
        if fileSystem.hasPrefix("FAT (") { return "FAT" }
        return "FAT32"
    }

    var fsSupported: Bool {
        fileSystem.hasPrefix("FAT") || fileSystem.hasPrefix("exFAT")
    }

    var fsWarning: String? {
        if fileSystem.hasPrefix("NTFS") {
            return "NTFS necesita software de terceros en macOS; no está implementado."
        }
        if fileSystem.hasPrefix("UDF") {
            return "UDF no está implementado en esta versión."
        }
        if fileSystem.hasPrefix("exFAT"), iso?.isWindows == true {
            return "exFAT no es arrancable en UEFI: el USB no arrancará."
        }
        if fileSystem.hasPrefix("FAT ("), (selectedDiskInfo?.size ?? 0) > 2 * 1024 * 1024 * 1024 {
            return "FAT16 no admite más de 2 GiB por volumen."
        }
        return nil
    }

    var persistenceWarning: String? {
        persistentGB > 0 ? "La persistencia no está implementada: se ignorará este valor." : nil
    }

    var selectedDiskInfo: DiskInfo? { disks.first { $0.id == selectedDisk } }

    var writableDisks: [DiskInfo] {
        disks.filter { d in
            guard d.isWritable else { return false }
            return listUSBHardDrives || d.isRemovable
        }
    }

    /// Rufus picks FAT for small sticks and FAT32 above ~2 GiB.
    func defaultFileSystem(for disk: DiskInfo?) -> String {
        guard let disk else { return "FAT32 (predeterminado)" }
        return disk.size < 2 * 1024 * 1024 * 1024
            ? "FAT (predeterminado)" : "FAT32 (predeterminado)"
    }

    var passes: Int { Int(badBlocksPasses.prefix(1)) ?? 1 }

    var canStart: Bool {
        guard !running, selectedDisk != nil, !isoLoading else { return false }
        guard selectedDiskInfo?.isWritable ?? false else { return false }
        guard fsSupported else { return false }
        if loaderKind != nil { return loaderSupported }
        if wantsISO { return iso != nil }
        return true   // "Non bootable" needs no image
    }

    var elapsedText: String {
        String(format: "%02d:%02d:%02d",
               Int(elapsed) / 3600, (Int(elapsed) % 3600) / 60, Int(elapsed) % 60)
    }

    var deviceCountText: String {
        let n = writableDisks.count
        return "\(n) dispositivo\(n == 1 ? "" : "s") encontrado\(n == 1 ? "" : "s")"
    }

    // MARK: - Data

    func refreshDisks() {
        disks = DiskService.list()
        let candidates = writableDisks
        if selectedDisk == nil || !candidates.contains(where: { $0.id == selectedDisk }) {
            selectedDisk = candidates.first?.id
            fileSystem = defaultFileSystem(for: candidates.first)
        }
    }

    /// Called when the user picks another device: follow Rufus and reset the
    /// filesystem default to whatever suits that size.
    func diskSelectionChanged() {
        guard let d = selectedDiskInfo else { return }
        if fsSupported || fileSystem.hasPrefix("FAT") {
            fileSystem = defaultFileSystem(for: d)
        }
        clusterSize = d.size < 2 * 1024 * 1024 * 1024
            ? "2048 bytes (predeterminado)" : "4096 bytes (predeterminado)"
    }

    /// Rufus opens the file dialog as soon as "Disk or ISO image" is picked.
    func chooseBootEntry(_ entry: String) {
        guard !running else { return }
        if entry == "ReactOS" {
            // En un Mac, ReactOS/LiberNT solo arranca con GPT: se elige por ti y se
            // pide la ISO enseguida, como hace Rufus al elegir una entrada con imagen.
            targetSystem = "Solo UEFI"
            if iso == nil { showImporter = true }
            return
        }
        if entry.hasPrefix("Imagen de disco"), iso == nil {
            showImporter = true
        }
    }

    func loadISO(url: URL) {
        isoLoading = true
        isoError = nil
        iso = nil
        bootEntry = RufusModel.bootEntries[3]
        Task.detached(priority: .userInitiated) {
            do {
                let info = try IsoService.analyze(path: url.path)
                await MainActor.run {
                    self.iso = info
                    self.label = info.isMacInstaller ? "OSXINSTALL"
                               : info.isWindows ? "WININSTALL" : "LINUX"
                    if info.isReactOS {
                        self.label = "REACTOS"
                        self.bootMode = "DD"
                    }
                    self.bootMode = info.isWindows ? "ISO" : "DD"
                    // Como Rufus: una ISO híbrida abre el cuadro que pide el modo.
                    if !info.isWindows, info.isHybrid, !info.writesRaw, !info.isMacInstaller {
                        self.bootMode = "ISO"
                        self.hybridName = info.fileName
                        self.showHybridAlert = true
                    }
                    if !self.recentISOs.contains(info.path) {
                        self.recentISOs.insert(info.path, at: 0)
                        self.recentISOs = Array(self.recentISOs.prefix(8))
                    }
                    self.isoLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isoError = error.localizedDescription
                    self.isoLoading = false
                }
            }
        }
    }

    // MARK: - Run

    func requestStart() {
        guard canStart else { return }
        confirmPending = true
    }

    func start() {
        guard let disk = selectedDisk else { return }
        confirmPending = false

        let isoPath = wantsISO ? (iso?.path ?? "") : ""
        let job = Job(mode: jobMode,
                      iso: isoPath,
                      disk: disk,
                      label: label.isEmpty ? "RUFUS" : label,
                      scheme: scheme,
                      bypass: wantsISO && (iso?.isWindows ?? false),
                      legacy: legacyBoot && wantsISO,
                      fs: fsName,
                      extendedLabel: createExtendedLabel,
                      verifyPasses: checkBadBlocks ? passes : 0,
                      loader: loaderKind != nil ? bootEntry : nil,
                      installer: iso?.isMacInstaller == true ? iso?.path : nil)

        let tmp = FileManager.default.temporaryDirectory
        let jobURL = tmp.appendingPathComponent("rufusmac-job.json")
        let logURL = tmp.appendingPathComponent("rufusmac-log.txt")
        do {
            try JSONEncoder().encode(job).write(to: jobURL)
        } catch {
            errorMessage = "no pude preparar el trabajo: \(error.localizedDescription)"
            return
        }
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        self.logURL = logURL

        running = true
        progress = 0
        status = "PREPARANDO…"
        log = []
        errorMessage = nil
        startedAt = Date()
        elapsed = 0

        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let shell = "'\(exe)' --engine '\(jobURL.path)' '\(logURL.path)' > /dev/null 2>&1"
        let script = "do shell script \"\(Self.appleScriptEscape(shell))\" with administrator privileges"

        startPolling()
        startClock()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 3600)
            DispatchQueue.main.async { self.finish(result) }
        }
    }

    private func finish(_ result: Shell.Result) {
        pollTimer?.invalidate(); pollTimer = nil
        clockTimer?.invalidate(); clockTimer = nil
        pollOnce()
        running = false

        if result.ok {
            progress = 1
            status = "COMPLETADO"
        } else {
            // El motivo real lo escribe el motor en el log. No pisarlo con el texto de
            // osascript («comando salió con un estado distinto de cero»), que no dice nada.
            let last = log.last ?? ""
            let engineMsg = last.hasPrefix("ERROR:")
                ? String(last.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                : (errorMessage ?? "").trimmingCharacters(in: .whitespaces)

            if !engineMsg.isEmpty {
                errorMessage = engineMsg
                status = "ERROR"
            } else if result.combined.contains("User canceled") || result.combined.contains("-128") {
                errorMessage = "permiso de administrador cancelado"
                status = "CANCELADO"
            } else {
                errorMessage = result.combined.isEmpty ? "la operación falló" : result.combined
                status = "ERROR"
            }
        }
        refreshDisks()
    }

    // MARK: - Timers

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            Task { @MainActor in self.pollOnce() }
        }
    }

    private func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                if let startedAt = self.startedAt { self.elapsed = Date().timeIntervalSince(startedAt) }
            }
        }
    }

    private func pollOnce() {
        guard let logURL,
              let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let last = lines.last else { return }
        let parts = last.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2, let value = Double(parts[0]) else { return }
        let msg = parts[1]
        if value < 0 {
            status = "ERROR"
            errorMessage = msg.replacingOccurrences(of: "ERROR: ", with: "")
            if log.last != msg { log.append(msg) }
            return
        }
        progress = max(0, min(value, 1))
        status = msg.uppercased()
        if log.last != msg { log.append(msg) }
    }

    // MARK: - Helpers

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
