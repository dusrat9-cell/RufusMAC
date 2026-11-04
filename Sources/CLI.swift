import Foundation
import CryptoKit

enum CLI {

    // MARK: - Progress sink

    final class LogSink {
        private let handle: FileHandle?
        private var last = Date.distantPast
        private var lastText = ""

        init(path: String) {
            FileManager.default.createFile(atPath: path, contents: nil,
                                           attributes: [.posixPermissions: 0o644])
            handle = FileHandle(forWritingAtPath: path)
        }

        func emit(_ value: Double, _ text: String, force: Bool = false) {
            let now = Date()
            guard force || text != lastText || now.timeIntervalSince(last) > 0.05 else { return }
            last = now
            lastText = text
            let line = String(format: "%.4f\t%@\n", value, text)
            handle?.write(line.data(using: .utf8) ?? Data())
        }

        func close() { try? handle?.close() }
    }

    // MARK: - --engine <job.json> <log.txt>

    static func runEngine(_ args: [String]) -> Int32 {
        guard args.count >= 2 else {
            FileHandle.standardError.write("uso: --engine <job.json> <log.txt>\n".data(using: .utf8)!)
            return 2
        }
        let jobURL = URL(fileURLWithPath: args[0])
        let sink = LogSink(path: args[1])
        defer { sink.close() }

        do {
            let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: jobURL))
            try Engine.execute(job: job) { value, text in sink.emit(value, text) }
            sink.emit(1.0, "Listo", force: true)
            return 0
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            sink.emit(-1, "ERROR: \(msg)", force: true)
            return 1
        }
    }

    // MARK: - --list

    static func listDisks() {
        for d in DiskService.list() {
            var flags = [d.isInternal ? "interno" : "externo"]
            if d.isSystem { flags.append("SISTEMA") }
            let pad = String(repeating: " ", count: max(0, 8 - d.id.count))
            print("/dev/\(d.id)\(pad)  \(d.sizeText.padding(toLength: 10, withPad: " ", startingAt: 0))  "
                  + "\(d.displayName.padding(toLength: 24, withPad: " ", startingAt: 0))  "
                  + "\(d.bus.padding(toLength: 10, withPad: " ", startingAt: 0))  "
                  + "[\(flags.joined(separator: ","))]  \(d.volumes.joined(separator: ","))")
        }
    }

    // MARK: - --info <iso>

    static func info(_ path: String) -> Int32 {
        do {
            let iso = try IsoService.analyze(path: path)
            print("archivo      : \(iso.fileName) (\(Fmt.bytes(iso.size)))")
            print("tipo         : \(iso.kindText)")
            print("arquitectura : \(iso.arch)")
            print("payload      : \(iso.payloadName ?? "-") (\(Fmt.bytes(iso.payloadSize)))")
            print("split        : \(iso.needsSplit ? "sí, \(iso.partCount) partes" : "no")")
            print("contenido    : \(Fmt.bytes(iso.treeSize))")
            let hybrid = iso.isHybrid ? "sí (arranca escrita tal cual)" : "no (escrita tal cual no arranca)"
            let modo: String
            if iso.isMacInstaller { modo = "macos (createinstallmedia)" }
            else if iso.writesRaw { modo = "dd (imagen cruda)" }
            else { modo = "archivos" }
            print("híbrida      : \(hybrid)")
            print("arranque EFI : \(iso.hasEFI ? "sí" : "no")")
            print("reactos      : \(iso.isReactOS ? "sí (se escribirá en DD)" : "no")")
            print("modo         : \(modo)")
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - --model-test <iso>

    /// Exercises the exact async path the SwiftUI window uses (RufusModel.loadISO)
    /// without opening a window, so the UI plumbing can be verified headlessly.
    final class Box { var done = false; var text = "" }

    static func modelTest(iso path: String) -> Int32 {
        let box = Box()
        Task { @MainActor in
            let model = RufusModel()
            model.loadISO(url: URL(fileURLWithPath: path))
            let deadline = Date().addingTimeInterval(30)
            while model.iso == nil && model.isoError == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let i = model.iso {
                let payload = i.payloadName ?? "-"
                box.text = "OK \(i.fileName) · \(i.kindText) · \(i.arch) · \(payload) · split=\(i.needsSplit) · mode=\(model.jobMode)"
            } else {
                box.text = "FALLO: " + (model.isoError ?? "timeout esperando el análisis")
            }
            box.done = true
        }
        let limit = Date().addingTimeInterval(40)
        while !box.done && Date() < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print(box.text.isEmpty ? "FALLO: timeout" : box.text)
        return box.text.hasPrefix("OK") ? 0 : 1
    }

    // MARK: - --selftest

    /// Builds a synthetic WIM, splits it in Swift and checks every blob still
    /// hashes to its SHA-1. This is the port's equivalent of the Python test.
    static func selfTest() -> Int32 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rufusmac-selftest-\(UInt32.random(in: 0...UInt32.max))")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let src = tmp.appendingPathComponent("install.wim")
            var blobs: [(Data, Bool)] = []
            for _ in 0..<2 { blobs.append((randomData(400 * 1024), true)) }
            for _ in 0..<6 { blobs.append((randomData(900 * 1024), false)) }
            let xml = Data("<WIM><TOTALBYTES>1</TOTALBYTES></WIM>".utf8)
            try buildSyntheticWim(at: src, blobs: blobs, xml: xml)
            print("WIM sintético: \((try! FileManager.default.attributesOfItem(atPath: src.path)[.size] as! NSNumber).intValue) bytes, \(blobs.count) blobs")

            let outDir = tmp.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let wim = try WimFile(url: src)
            let expected = wim.entries.map { $0.sha1.base64EncodedString() + ":" + String($0.res.size) }.sorted()
            let urls = try WimSplitter.split(wim: wim, into: outDir, maxPartSize: 3 * 1024 * 1024,
                                             log: { print("  " + $0) })
            guard urls.count >= 2 else {
                print("FALLO: esperaba varias partes, salieron \(urls.count)")
                return 1
            }

            var got: [String] = []
            for (i, url) in urls.enumerated() {
                let part = try WimFile(url: url)
                guard Int(part.part) == i + 1, Int(part.total) == urls.count else {
                    print("FALLO: numeración incorrecta en \(url.lastPathComponent)")
                    return 1
                }
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= FAT32_MAX_FILE else {
                    print("FALLO: \(url.lastPathComponent) excede FAT32")
                    return 1
                }
                for e in part.entries {
                    let digest = try part.hashOfBlob(e.res)
                    guard digest == e.sha1 else {
                        print("FALLO: blob corrupto en \(url.lastPathComponent) @\(e.res.offset)")
                        return 1
                    }
                    got.append(e.sha1.base64EncodedString() + ":" + String(e.res.size))
                }
                if i > 0 && part.entries.contains(where: { $0.isMetadata }) {
                    print("FALLO: la parte \(i + 1) no debe llevar metadatos")
                    return 1
                }
            }

            guard got.sorted() == expected else {
                print("FALLO: los blobs de las partes no coinciden con el original")
                return 1
            }
            print("\nOK: split, offsets, SHA-1 y metadatos verificados.")
            return 0
        } catch {
            print("FALLO: \(error.localizedDescription)")
            return 1
        }
    }

    static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    static func buildSyntheticWim(at url: URL, blobs: [(Data, Bool)], xml: Data) throws {
        var pos = UInt64(WIM_HEADER_SIZE)
        var placed: [(Data, Bool, UInt64)] = []
        for (data, meta) in blobs {
            pos = align8(pos)
            placed.append((data, meta, pos))
            pos += UInt64(data.count)
        }
        let xmlOff = align8(pos)
        pos = xmlOff + UInt64(xml.count)
        let tableOff = align8(pos)

        var hdr = [UInt8](repeating: 0, count: WIM_HEADER_SIZE)
        for i in 0..<8 { hdr[i] = WIM_MAGIC[i] }
        putLE(UInt32(WIM_HEADER_SIZE), into: &hdr, at: 0x08)
        putLE(UInt32(0x10D00), into: &hdr, at: 0x0C)
        putLE(UInt32(2), into: &hdr, at: 0x10)
        putLE(UInt32(32768), into: &hdr, at: 0x14)
        for i in 0..<16 { hdr[0x18 + i] = UInt8.random(in: 0...255) }
        putLE(UInt16(1), into: &hdr, at: 0x28)
        putLE(UInt16(1), into: &hdr, at: 0x2A)
        putLE(UInt32(2), into: &hdr, at: 0x2C)

        var t = ResHdr()
        t.size = UInt64(WIM_ENTRY_SIZE * blobs.count)
        t.flags = RESHDR_METADATA
        t.offset = tableOff
        t.uncompressed = t.size
        hdr.replaceSubrange(0x30..<0x48, with: t.serialized())

        var x = ResHdr()
        x.size = UInt64(xml.count)
        x.flags = RESHDR_METADATA
        x.offset = xmlOff
        x.uncompressed = x.size
        hdr.replaceSubrange(0x48..<0x60, with: x.serialized())

        if let boot = placed.first(where: { $0.1 }) {
            var bm = ResHdr()
            bm.size = UInt64(boot.0.count)
            bm.flags = RESHDR_METADATA
            bm.offset = boot.2
            bm.uncompressed = bm.size
            hdr.replaceSubrange(0x60..<0x78, with: bm.serialized())
            putLE(UInt32(1), into: &hdr, at: 0x78)
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.write(contentsOf: Data(hdr))
        for (data, _, off) in placed {
            try fh.seek(toOffset: off)
            try fh.write(contentsOf: data)
        }
        try fh.seek(toOffset: xmlOff)
        try fh.write(contentsOf: xml)
        try fh.seek(toOffset: tableOff)
        for (data, meta, off) in placed.sorted(by: { Insecure.SHA1.hash(data: $0.0).lexicographicallyPrecedes(Insecure.SHA1.hash(data: $1.0)) }) {
            var r = ResHdr()
            r.size = UInt64(data.count)
            r.flags = meta ? RESHDR_METADATA : 0x04
            r.offset = off
            r.uncompressed = r.size
            try fh.write(contentsOf: Data(r.serialized()))
            var metaBytes = [UInt8](repeating: 0, count: 6)
            putLE(UInt16(1), into: &metaBytes, at: 0)
            putLE(UInt32(1), into: &metaBytes, at: 2)
            try fh.write(contentsOf: Data(metaBytes))
            try fh.write(contentsOf: Data(Insecure.SHA1.hash(data: data)))
        }
    }
}
