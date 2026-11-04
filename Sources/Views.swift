import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Small controls specific to this window

struct RufusTextField: View {
    @Binding var text: String
    var monospaced = false
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(R.text)
            .padding(.horizontal, 7)
            .frame(height: R.fieldH)
            .background(R.field)
            .overlay(RoundedRectangle(cornerRadius: R.radius).strokeBorder(R.border, lineWidth: 1))
    }
}

/// The SELECT | ▾ split button from Rufus.
struct SplitSelect: View {
    let onSelect: () -> Void
    @Binding var mode: String
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                Text("SELECT")
                    .font(.system(size: 12))
                    .foregroundStyle(enabled ? R.accent : R.textOff)
                    .frame(width: 74, height: R.fieldH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(R.accent.opacity(enabled ? 1 : 0.4)).frame(width: 1)

            Menu {
                Button("Modo ISO (extraer archivos)") { mode = "ISO" }
                Button("Modo DD (escribir la imagen)") { mode = "DD" }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(enabled ? R.accent : R.textOff)
                    .frame(width: 22, height: R.fieldH)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .frame(height: R.fieldH)
        .background(R.field)
        .overlay(RoundedRectangle(cornerRadius: R.radius).strokeBorder(R.accent.opacity(enabled ? 1 : 0.4), lineWidth: 1))
        .disabled(!enabled)
        .help("Elegir imagen y modo de escritura")
    }
}

/// A combo whose whole label opens a menu, drawn like the Windows control.
struct BootCombo: View {
    let current: String
    let items: [String]
    let onPick: (String) -> Void
    let onBrowse: () -> Void
    var enabled: Bool = true

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { path in
                Button((path as NSString).lastPathComponent) { onPick(path) }
            }
            if items.isEmpty { Text("Sin imágenes recientes") }
            Divider()
            Button("Elegir ISO…") { onBrowse() }
        } label: {
            HStack(spacing: 0) {
                Text(current)
                    .font(.system(size: 12))
                    .foregroundStyle(enabled ? R.text : R.textOff)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(R.border).frame(width: 1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(R.label)
                    .frame(width: 21)
            }
            .frame(height: R.fieldH)
            .background(R.field)
            .overlay(RoundedRectangle(cornerRadius: R.radius).strokeBorder(R.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!enabled)
    }
}

// MARK: - Window

struct ContentView: View {
    @StateObject private var model = RufusModel()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    RufusHeader(text: "Propiedades del dispositivo")
                    deviceField
                    bootField
                    if model.iso != nil { imageFormatField }
                    HStack(alignment: .top, spacing: 18) {
                        RufusField(label: "Esquema de partición") {
                            RufusCombo(title: "", selection: schemeBinding,
                                       items: ["MBR", "GPT"], label: { $0 },
                                       enabled: !model.running,
                                       fixedWidth: 300) { EmptyView() }
                        }
                        .frame(width: 300, alignment: .leading)
                        RufusField(label: "Sistema destino") {
                            RufusCombo(title: "", selection: $model.targetSystem,
                                       items: ["BIOS o UEFI", "Solo UEFI", "Solo BIOS"], label: { $0 },
                                       enabled: !model.running,
                                       fixedWidth: 300) { EmptyView() }
                        }
                        .frame(width: 300, alignment: .leading)
                    }
                    advancedDrive

                    RufusHeader(text: "Opciones de formato").padding(.top, 7)
                    RufusField(label: "Etiqueta del volumen") {
                        RufusTextField(text: $model.label, monospaced: true)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        RufusField(label: "Sistema de archivos") {
                            RufusCombo(title: "", selection: $model.fileSystem,
                                       items: ["FAT (predeterminado)",
                                               "FAT32 (predeterminado)",
                                               "exFAT",
                                               "NTFS — no soportado",
                                               "UDF — no soportado"],
                                       label: { $0 },
                                       enabled: !model.running,
                                       fixedWidth: 300) { EmptyView() }
                        }
                        .frame(width: 300, alignment: .leading)
                        RufusField(label: "Tamaño de clúster") {
                            RufusCombo(title: "", selection: $model.clusterSize,
                                       items: ["2048 bytes (predeterminado)",
                                               "4096 bytes (predeterminado)",
                                               "8192 bytes", "16 KB", "32 KB", "64 KB"],
                                       label: { $0 }, enabled: false,
                                       fixedWidth: 300) { EmptyView() }
                                .help("macOS elige el tamaño de clúster automáticamente al formatear.")
                        }
                        .frame(width: 300, alignment: .leading)
                    }
                    advancedFormat
                    warnings
                }
                .padding(.horizontal, R.pad)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }

            statusSection
            bottomBar
            statusBar
        }
        .background(R.bg)
        .preferredColorScheme(.light)
        .frame(minWidth: 660, idealWidth: 680, maxWidth: .infinity,
               minHeight: 560, idealHeight: 726)
        .onAppear {
            model.refreshDisks()
            if let iso = CommandLine.arguments.dropFirst()
                .first(where: { $0.hasSuffix(".iso") || $0.hasSuffix(".img") }) {
                model.loadISO(url: URL(fileURLWithPath: iso))
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: IsoService.imageExtensions.compactMap {
                          UTType(filenameExtension: $0)
                      } + [.application, .folder],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.loadISO(url: url)
            }
        }
        .sheet(isPresented: $model.showLog) { logSheet }
        .sheet(isPresented: $model.showAbout) { aboutSheet }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Cerrar", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("ISO híbrida detectada", isPresented: $model.showHybridAlert) {
            Button("Modo ISO (recomendado)") { model.chooseHybridMode(isoMode: true) }
            Button("Modo DD") { model.chooseHybridMode(isoMode: false) }
            Button("Cancelar", role: .cancel) { model.showHybridAlert = false }
        } message: {
            Text("«\(model.hybridName)» es una imagen «ISOHybrid»: se puede escribir en "
                 + "modo ISO (copiar sus archivos) o en modo DD (escribirla tal cual).\n\n"
                 + "Modo DD: arranca siempre, pero después el USB queda de solo lectura.\n"
                 + "Modo ISO: el USB queda escribible y arranca por UEFI con los archivos "
                 + "de la ISO; para un equipo antiguo que solo arranque por BIOS, usa DD.")
        }
    }

    private var schemeBinding: Binding<String> {
        Binding(
            get: { model.scheme },
            set: { newValue in
                if newValue == "GPT" {
                    model.targetSystem = "Solo UEFI"
                } else if model.targetSystem == "Solo UEFI" {
                    model.targetSystem = "BIOS o UEFI"
                }
            }
        )
    }

    // MARK: Device

    private var deviceField: some View {
        RufusField(label: "Dispositivo") {
            HStack(spacing: 6) {
                let ids: [String?] = model.writableDisks.isEmpty
                    ? [nil] : model.writableDisks.map { Optional($0.id) }
                RufusCombo(title: "Dispositivo", selection: $model.selectedDisk,
                           items: ids,
                           label: { id in
                               guard let id, let d = model.disks.first(where: { $0.id == id }) else {
                                   return "No hay dispositivos externos"
                               }
                               // Rufus shows "LABEL (F:) [130 MB]"
                               let name = d.volumes.first ?? d.displayName
                               return "\(name) (\(d.id)) [\(d.sizeText)]"
                           },
                           enabled: !model.running && !model.writableDisks.isEmpty,
                           leadingSymbol: "externaldrive",
                           fixedWidth: 610) { EmptyView() }

                RufusIconButton(symbol: "square.and.arrow.down", help: "Guardar la selección de dispositivo") {
                    model.refreshDisks()
                }
            }
        }
        .onChange(of: model.selectedDisk) { _ in model.diskSelectionChanged() }
    }

    // MARK: Image format (only shown once an image is loaded, like Rufus)

    private var imageFormatField: some View {
        RufusField(label: "Formato de imagen") {
            RufusCombo(title: "", selection: $model.bootMode,
                       items: model.iso?.isReactOS == true ? ["DD"] : ["ISO", "DD"],
                       label: { $0 == "DD" ? "Imagen DD (escribir tal cual)"
                                            : "Imagen ISO (copiar archivos, UEFI)" },
                       enabled: !model.running,
                       fixedWidth: 610) { EmptyView() }
        }
    }

    // MARK: Boot selection

    private var bootField: some View {
        RufusField(label: "Selección de arranque") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    RufusCombo(title: "Selección de arranque",
                               selection: $model.bootEntry,
                               items: RufusModel.bootEntries,
                               label: { entry in
                                   if entry.hasPrefix("Imagen de disco"), let iso = model.iso {
                                       return iso.fileName
                                   }
                                   return entry
                               },
                               enabled: !model.running,
                               fixedWidth: 470) { EmptyView() }

                    Group {
                        if model.isoLoading {
                            ProgressView().controlSize(.small)
                        } else if model.iso != nil || model.loaderSupported {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(R.accent)
                        } else {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(R.textOff)
                        }
                    }
                    .frame(width: 20)
                    .help(model.iso != nil ? "Imagen válida: \(model.iso?.fileName ?? "")"
                                           : (model.loaderSupported ? "Se descargará el cargador y se instalará"
                                                                    : "Ninguna imagen seleccionada"))

                    Spacer(minLength: 0)

                    Button("SELECT") { model.showImporter = true }
                        .buttonStyle(RufusButtonStyle(width: 84))
                        .disabled(model.running)
                        .help("Elegir una imagen (ISO, IMG, DMG, RAW, BIN, VHD, WIC) "
                              + "o un instalador de macOS «Install macOS …app»")
                }

                if let iso = model.iso, model.wantsISO {
                    Text(detailLine(iso))
                        .font(.system(size: 10.5))
                        .foregroundStyle(R.textOff)
                        .lineLimit(1)
                }
            }
        }
        .onChange(of: model.bootEntry) { newValue in
            model.chooseBootEntry(newValue)
        }
    }

    private func detailLine(_ iso: IsoInfo) -> String {
        var parts = ["\(iso.kindText)", iso.arch, Fmt.bytes(iso.size)]
        if let payload = iso.payloadName { parts.append("\(payload) \(Fmt.bytes(iso.payloadSize))") }
        if iso.needsSplit { parts.append("se partirá en \(iso.partCount) .swm") }
        if !iso.isWindows { parts.append(model.bootMode == "DD" ? "escritura directa" : "extraer archivos") }
        return parts.joined(separator: " · ")
    }

    // MARK: Persistent partition

    private var persistenceField: some View {
        RufusField(label: "Tamaño de partición persistente") {
            HStack(spacing: 10) {
                Slider(value: $model.persistentGB, in: 0...32)
                    .tint(R.accent)
                    .controlSize(.small)
                    .frame(width: 292)
                    .disabled(model.running)
                RufusTextField(text: Binding(
                    get: { String(Int(model.persistentGB)) },
                    set: { model.persistentGB = Double(Int($0) ?? 0) }
                ))
                .frame(width: 70)
                RufusCombo(title: "", selection: .constant("GB"), items: ["GB"],
                           label: { $0 }, enabled: false,
                           fixedWidth: 72) { EmptyView() }
            }
        }
    }

    // MARK: Advanced drive properties

    private var advancedDrive: some View {
        RufusDisclosure(title: model.showAdvancedDrive ? "Ocultar propiedades avanzadas"
                                                       : "Mostrar propiedades avanzadas",
                        expanded: $model.showAdvancedDrive) {
            VStack(alignment: .leading, spacing: 9) {
                persistenceField
                Toggle("Listar discos USB", isOn: $model.listUSBHardDrives)
                    .toggleStyle(RufusCheckboxStyle())
                    .onChange(of: model.listUSBHardDrives) { _ in model.refreshDisks() }
                Toggle("Añadir correcciones para BIOS antiguos (partición extra, alineación, etc.)",
                       isOn: $model.fixOldBIOS)
                    .toggleStyle(RufusCheckboxStyle())
                    .disabled(model.running)
                HStack(spacing: 12) {
                    Toggle("Usar Rufus MBR con ID de BIOS", isOn: $model.useRufusMBR)
                        .toggleStyle(RufusCheckboxStyle())
                        .disabled(true)
                        .help("El MBR de Rufus es ensamblador 16-bit; macOS no puede generarlo. Se usa el MBR del sistema con el ID elegido.")
                    RufusCombo(title: "", selection: $model.biosID,
                               items: ["0x80 (predeterminado)", "0x00 (no arrancable)"],
                               label: { $0 }, enabled: false,
                               fixedWidth: 190) { EmptyView() }
                }
            }
            .padding(.leading, 15)
        }
    }

    // MARK: Advanced format options

    private var advancedFormat: some View {
        RufusDisclosure(title: model.showAdvancedFormat ? "Ocultar opciones de formato avanzadas"
                                                        : "Mostrar opciones de formato avanzadas",
                        expanded: $model.showAdvancedFormat) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("Formateo rápido", isOn: $model.quickFormat)
                    .toggleStyle(RufusCheckboxStyle())
                    .disabled(model.running)
                Toggle("Crear etiqueta extendida y archivos de icono", isOn: $model.createExtendedLabel)
                    .toggleStyle(RufusCheckboxStyle())
                    .disabled(model.running)
                    .help("Escribe autorun.inf y autorun.ico en la raíz del volumen.")
                HStack(spacing: 12) {
                    Toggle("Comprobar bloques defectuosos", isOn: $model.checkBadBlocks)
                        .toggleStyle(RufusCheckboxStyle())
                        .disabled(model.running)
                        .help("Lee todo el dispositivo tras escribir y cuenta los sectores ilegibles.")
                    RufusCombo(title: "", selection: $model.badBlocksPasses,
                               items: ["1 pasada", "2 pasadas", "4 pasadas"],
                               label: { $0 },
                               enabled: !model.running && model.checkBadBlocks,
                               fixedWidth: 110) { EmptyView() }
                }
            }
            .padding(.leading, 15)
        }
    }

    // MARK: Warnings

    @ViewBuilder
    private var warnings: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let note = model.loaderNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(R.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let w = model.fsWarning {
                Text(w).font(.system(size: 10.5)).foregroundStyle(Color(red: 0.7, green: 0.1, blue: 0.1))
            }
            if let w = model.imageWarning {
                Text(w)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(red: 0.7, green: 0.45, blue: 0))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let w = model.persistenceWarning {
                Text(w).font(.system(size: 10.5)).foregroundStyle(Color(red: 0.7, green: 0.45, blue: 0))
            }
            if let io = model.iso, io.isReactOS, model.wantsISO {
                Text("ReactOS se escribe tal cual (DD): su cargador va en el MBR del USB. "
                     + "El modo ISO (copiar archivos) no arranca.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(red: 0.7, green: 0.45, blue: 0))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.isoError {
                Text(err).font(.system(size: 10.5)).foregroundStyle(Color(red: 0.7, green: 0.1, blue: 0.1))
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            RufusHeader(text: "Estado")
            RufusStatusBox(text: model.status, progress: model.progress, running: model.running)
        }
        .padding(.horizontal, R.pad)
        .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                RufusIconButton(symbol: "globe", help: "Sitio oficial de Rufus (rufus.ie)") {
                    if let url = URL(string: "https://rufus.ie") { NSWorkspace.shared.open(url) }
                }
                RufusIconButton(symbol: "info.circle", help: "Acerca de Rufus para macOS") {
                    model.showAbout = true
                }
                RufusIconButton(symbol: "slider.horizontal.3",
                                help: model.showAdvancedFormat ? "Ocultar las opciones de formato avanzadas"
                                                               : "Mostrar las opciones de formato avanzadas") {
                    withAnimation(.easeOut(duration: 0.12)) { model.showAdvancedFormat.toggle() }
                }
                RufusIconButton(symbol: "list.bullet.rectangle", help: "Mostrar el registro") {
                    model.showLog = true
                }
                RufusProgressBar(progress: model.progress, running: model.running)
            }

            HStack(spacing: 8) {
                Spacer()

                Button {
                    model.requestStart()
                } label: {
                    Text(model.running ? "TRABAJANDO…" : "START")
                }
                .buttonStyle(RufusButtonStyle(width: 104))
                .disabled(!model.canStart)
                .keyboardShortcut(.defaultAction)
                .alert("¿Formatear \(model.selectedDisk ?? "")?",
                       isPresented: $model.confirmPending) {
                    Button("Formatear", role: .destructive) { model.start() }
                    Button("Cancelar", role: .cancel) { }
                } message: {
                    Text("Se borrará todo el contenido de \(model.selectedDiskInfo?.displayName ?? "el dispositivo") (\(model.selectedDiskInfo?.sizeText ?? "")). No se puede deshacer.")
                }

                Button("CLOSE") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(RufusButtonStyle(width: 104))
                    .disabled(model.running)
            }
        }
        .padding(.horizontal, R.pad)
        .padding(.bottom, 8)
    }

    private var statusBar: some View {
        HStack {
            Text(model.deviceCountText)
            Spacer()
            Text(model.running ? model.elapsedText : "00:00:00")
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(R.label)
        .padding(.horizontal, R.pad)
        .padding(.vertical, 5)
        .background(R.bar)
        .overlay(Rectangle().fill(R.borderSoft).frame(height: 1), alignment: .top)
    }

    // MARK: Sheets

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Registro").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cerrar") { model.showLog = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.log.isEmpty {
                        Text("Sin actividad todavía.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 340)
    }

    private var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rufus para macOS").font(.system(size: 15, weight: .semibold))
            Text("Reimplementación nativa en Swift/SwiftUI de Rufus (GPLv3).")
                .font(.system(size: 11.5))
            Text("FAT32 y exFAT · split de install.wim · bypass de requisitos de Windows 11 · arranque UEFI y BIOS legacy.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Divider()
            Text("El motor se ejecuta con permisos de administrador mediante un único prompt del sistema.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cerrar") { model.showAbout = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 430)
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            }
            guard let url else { return }
            DispatchQueue.main.async { model.loadISO(url: url) }
        }
        return true
    }
}
