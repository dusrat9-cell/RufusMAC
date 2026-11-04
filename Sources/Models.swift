import Foundation

struct DiskInfo: Identifiable, Hashable {
    let id: String            // "disk4"
    let size: Int64
    let name: String
    let bus: String
    let isInternal: Bool
    let isRemovable: Bool
    let isSystem: Bool
    let volumes: [String]

    var sizeText: String { Fmt.bytes(size) }
    var displayName: String { name.isEmpty ? "Desconocido" : name }
    var subtitle: String {
        var parts = [sizeText, bus]
        if !volumes.isEmpty { parts.append(volumes.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
    var isWritable: Bool { !isInternal && !isSystem && id != "disk0" && size >= 512 * 1024 * 1024 }
}

struct IsoInfo {
    var path: String
    var size: Int64
    var isWindows: Bool
    var arch: String
    var payloadName: String?
    var payloadSize: Int64
    var needsSplit: Bool
    var partCount: Int
    var treeSize: Int64
    var hasBootmgr: Bool
    var hasEFI: Bool
    /// La imagen trae MBR/GPT/DDM propios: escrita tal cual sí arranca por USB.
    var isHybrid: Bool
    /// Tamaño real del contenido (para un .dmg comprimido, el de la imagen cruda).
    var rawSize: Int64
    /// img / raw / bin / vhd / dmg: se escriben byte a byte, no se extraen archivos.
    var writesRaw: Bool
    /// Un "Install macOS …app": se escribe con createinstallmedia, no extrayendo.
    var isMacInstaller: Bool
    /// Un bootcd.iso de ReactOS: instala su propio cargador en el MBR. Solo funciona en DD.
    var isReactOS: Bool
    /// Ruta (relativa al volumen, con su grafía real) del gestor de arranque EFI que
    /// trae el ReactOS: lo que rEFInd encadenará. `nil` si no se encontró ninguno.
    var reactosLoader: String?

    var fileName: String { (path as NSString).lastPathComponent }
    var kindText: String {
        if isMacInstaller { return "Instalador de macOS" }
        if isWindows { return "Windows" }
        return writesRaw ? "Imagen cruda (Linux / otra)" : "Linux / otra"
    }
}

struct Job: Codable {
    var mode: String        // "windows" | "dd" | "none" | "loader" | "macos"
    var iso: String
    var disk: String
    var label: String
    var scheme: String
    var bypass: Bool
    var legacy: Bool
    var fs: String?          // "FAT" | "FAT32" | "exFAT"
    var extendedLabel: Bool? // write autorun.inf + icon, like Rufus
    var verifyPasses: Int?   // read-back passes for "check device for bad blocks"
    var loader: String?      // boot entry name when mode == "loader"
    var installer: String?   // "Install macOS …app" when mode == "macos"
}

struct ProgressLine {
    var value: Double
    var text: String
}
