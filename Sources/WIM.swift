import Foundation
import CryptoKit

// MARK: - WIM on-disk constants (see wimlib/wimlib/header.h, blob_table.c)

let WIM_MAGIC: [UInt8] = [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00] // "MSWIM\0\0\0"
let WIM_HEADER_SIZE = 208
let WIM_RESHDR_SIZE = 24
let WIM_ENTRY_SIZE = 50          // reshdr(24) + part(2) + refcnt(4) + sha1(20)
let WIM_VERSION_SOLID: UInt32 = 0x0E00

let RESHDR_METADATA: UInt8 = 0x02
let RESHDR_SOLID: UInt8 = 0x10
let HDR_FLAG_WRITE_IN_PROGRESS: UInt32 = 0x40

let FAT32_MAX_FILE: Int64 = 0xFF_FF_FF_FF
let DEFAULT_PART_SIZE: Int64 = 3_892_314_112   // 3.625 GiB

let COPY_CHUNK = 1 << 20

// MARK: - Little-endian helpers

@inline(__always) func align8(_ n: UInt64) -> UInt64 { (n + 7) & ~7 }

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}

@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

@inline(__always) func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
    return v
}

func putLE<T: FixedWidthInteger>(_ value: T, into buf: inout [UInt8], at offset: Int) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { raw in
        for i in 0..<MemoryLayout<T>.size { buf[offset + i] = raw[i] }
    }
}

// MARK: - Structures

struct ResHdr {
    var size: UInt64 = 0        // bytes as stored in the WIM (possibly compressed)
    var flags: UInt8 = 0
    var offset: UInt64 = 0
    var uncompressed: UInt64 = 0

    var isMetadata: Bool { flags & RESHDR_METADATA != 0 }
    var isSolid: Bool { flags & RESHDR_SOLID != 0 }

    static func parse(_ b: [UInt8], _ o: Int) -> ResHdr {
        var h = ResHdr()
        for i in 0..<7 { h.size |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        h.flags = b[o + 7]
        h.offset = le64(b, o + 8)
        h.uncompressed = le64(b, o + 16)
        return h
    }

    func serialized() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: WIM_RESHDR_SIZE)
        for i in 0..<7 { out[i] = UInt8((size >> (8 * UInt64(i))) & 0xFF) }
        out[7] = flags
        putLE(offset, into: &out, at: 8)
        putLE(uncompressed, into: &out, at: 16)
        return out
    }
}

struct WimEntry {
    var res: ResHdr
    var part: UInt16
    var refcnt: UInt32
    var sha1: Data
    var isMetadata: Bool { res.isMetadata }
}

// MARK: - Reader

final class WimFile {
    let url: URL
    private let fh: FileHandle

    private(set) var version: UInt32 = 0
    private(set) var flags: UInt32 = 0
    private(set) var chunkSize: UInt32 = 0
    private(set) var guid = [UInt8](repeating: 0, count: 16)
    private(set) var part: UInt16 = 1
    private(set) var total: UInt16 = 1
    private(set) var imageCount: UInt32 = 0
    private(set) var table = ResHdr()
    private(set) var xml = ResHdr()
    private(set) var bootMeta = ResHdr()
    private(set) var bootIdx: UInt32 = 0
    private(set) var entries: [WimEntry] = []

    init(url: URL) throws {
        self.url = url
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw EngineError("no puedo abrir \(url.lastPathComponent)")
        }
        self.fh = h

        let header = try read(at: 0, count: WIM_HEADER_SIZE)
        let bytes = [UInt8](header)
        guard Array(bytes[0..<8]) == WIM_MAGIC else {
            throw EngineError("\(url.lastPathComponent): no es un WIM válido")
        }

        version = le32(bytes, 0x0C)
        flags = le32(bytes, 0x10)
        chunkSize = le32(bytes, 0x14)
        guid = Array(bytes[0x18..<0x28])
        part = le16(bytes, 0x28)
        total = le16(bytes, 0x2A)
        imageCount = le32(bytes, 0x2C)
        table = ResHdr.parse(bytes, 0x30)
        xml = ResHdr.parse(bytes, 0x48)
        bootMeta = ResHdr.parse(bytes, 0x60)
        bootIdx = le32(bytes, 0x78)

        try loadTable()
    }

    deinit { try? fh.close() }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try fh.seek(toOffset: offset)
        guard let d = try fh.read(upToCount: count), d.count == count else {
            throw EngineError("lectura incompleta en \(url.lastPathComponent) (offset \(offset))")
        }
        return d
    }

    private func loadTable() throws {
        guard table.size % UInt64(WIM_ENTRY_SIZE) == 0 else {
            throw EngineError("blob table con tamaño inválido (\(table.size))")
        }
        guard table.size > 0 else { return }
        let raw = [UInt8](try read(at: table.offset, count: Int(table.size)))
        var out: [WimEntry] = []
        out.reserveCapacity(raw.count / WIM_ENTRY_SIZE)
        var o = 0
        while o + WIM_ENTRY_SIZE <= raw.count {
            let res = ResHdr.parse(raw, o)
            let p = le16(raw, o + WIM_RESHDR_SIZE)
            let rc = le32(raw, o + WIM_RESHDR_SIZE + 2)
            let sha = Data(raw[(o + WIM_RESHDR_SIZE + 6)..<(o + WIM_ENTRY_SIZE)])
            out.append(WimEntry(res: res, part: p, refcnt: rc, sha1: sha))
            o += WIM_ENTRY_SIZE
        }
        entries = out
    }

    var isSolid: Bool {
        version == WIM_VERSION_SOLID || entries.contains { $0.res.isSolid }
    }

    var isSplit: Bool { total > 1 }

    func readXML() throws -> Data {
        try read(at: xml.offset, count: Int(xml.size))
    }

    func copyResource(_ res: ResHdr, to out: FileHandle, progress: ((Int) -> Void)? = nil) throws {
        try fh.seek(toOffset: res.offset)
        var remaining = Int64(res.size)
        while remaining > 0 {
            let n = Int(min(Int64(COPY_CHUNK), remaining))
            guard let d = try fh.read(upToCount: n), !d.isEmpty else {
                throw EngineError("fin de archivo inesperado al copiar un blob")
            }
            try out.write(contentsOf: d)
            remaining -= Int64(d.count)
            progress?(d.count)
        }
    }

    /// Read a stored blob and return its SHA-1 (used by the self test).
    func hashOfBlob(_ res: ResHdr) throws -> Data {
        try fh.seek(toOffset: res.offset)
        var hasher = Insecure.SHA1()
        var remaining = Int64(res.size)
        while remaining > 0 {
            let n = Int(min(Int64(COPY_CHUNK), remaining))
            guard let d = try fh.read(upToCount: n), !d.isEmpty else {
                throw EngineError("fin de archivo inesperado al hashear")
            }
            hasher.update(data: d)
            remaining -= Int64(d.count)
        }
        return Data(hasher.finalize())
    }
}

// MARK: - Splitter (port of wimlib's split.c)

enum WimSplitter {

    /// Metadata goes to part 1 and never forces a new part; everything else is
    /// packed in sequential order until the part would reach `maxPartSize`.
    static func planParts(_ wim: WimFile, maxPartSize: Int64) throws -> [[WimEntry]] {
        let metadata = wim.entries.filter { $0.isMetadata }
        let data = wim.entries.filter { !$0.isMetadata }
            .sorted { $0.res.offset < $1.res.offset }

        var parts: [[WimEntry]] = [[]]
        var sizes: [Int64] = [0]

        for e in metadata {
            parts[0].append(e)
            sizes[0] += Int64(e.res.size)
        }
        for e in data {
            if Int64(e.res.size) > FAT32_MAX_FILE {
                throw EngineError("un blob de \(Fmt.bytes(Int64(e.res.size))) no cabe en FAT32 ni puede partirse")
            }
            if sizes[sizes.count - 1] + Int64(e.res.size) >= maxPartSize && sizes[sizes.count - 1] > 0 {
                parts.append([])
                sizes.append(0)
            }
            parts[parts.count - 1].append(e)
            sizes[sizes.count - 1] += Int64(e.res.size)
        }
        return parts
    }

    static func split(wim: WimFile,
                      into dir: URL,
                      maxPartSize: Int64 = DEFAULT_PART_SIZE,
                      basename: String = "install",
                      progress: ((Int) -> Void)? = nil,
                      log: (String) -> Void = { _ in }) throws -> [URL] {
        guard !wim.isSplit else { throw EngineError("el WIM ya está partido") }
        guard !wim.isSolid else {
            throw EngineError("el WIM usa recursos 'solid' (ESD/LZMS): no se puede partir")
        }

        let parts = try planParts(wim, maxPartSize: maxPartSize)
        var guid = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { guid[i] = UInt8.random(in: 0...255) }

        var urls: [URL] = []
        for (i, entries) in parts.enumerated() {
            let n = i + 1
            let name = n == 1 ? "\(basename).swm" : "\(basename)\(n).swm"
            let url = dir.appendingPathComponent(name)
            let dataBytes = entries.reduce(Int64(0)) { $0 + Int64($1.res.size) }
            log("parte \(n)/\(parts.count): \(name) (\(Fmt.bytes(dataBytes)), \(entries.count) blobs)")
            _ = try writePart(wim: wim, entries: entries, to: url,
                              partNumber: UInt16(n), totalParts: UInt16(parts.count),
                              guid: guid, progress: progress)
            try verifyPart(url: url, against: entries, partNumber: n, totalParts: parts.count)
            urls.append(url)
        }
        return urls
    }

    @discardableResult
    static func writePart(wim: WimFile,
                          entries: [WimEntry],
                          to url: URL,
                          partNumber: UInt16,
                          totalParts: UInt16,
                          guid: [UInt8],
                          progress: ((Int) -> Void)? = nil) throws -> Int64 {

        let xmlData = try wim.readXML()

        var pos: UInt64 = UInt64(WIM_HEADER_SIZE)
        var placed: [(entry: WimEntry, offset: UInt64)] = []
        for e in entries {
            pos = align8(pos)
            placed.append((e, pos))
            pos += e.res.size
        }
        let xmlOff = align8(pos)
        pos = xmlOff + UInt64(xmlData.count)
        let tableOff = align8(pos)
        pos = tableOff + UInt64(WIM_ENTRY_SIZE * entries.count)
        let partSize = Int64(pos)

        guard partSize <= FAT32_MAX_FILE else {
            throw EngineError("la parte \(partNumber) ocuparía \(Fmt.bytes(partSize)), más que el límite FAT32")
        }

        // --- header ---
        var hdr = [UInt8](repeating: 0, count: WIM_HEADER_SIZE)
        for i in 0..<8 { hdr[i] = WIM_MAGIC[i] }
        putLE(UInt32(WIM_HEADER_SIZE), into: &hdr, at: 0x08)
        putLE(wim.version, into: &hdr, at: 0x0C)
        putLE(wim.flags & ~HDR_FLAG_WRITE_IN_PROGRESS, into: &hdr, at: 0x10)
        putLE(wim.chunkSize, into: &hdr, at: 0x14)
        for i in 0..<16 { hdr[0x18 + i] = guid[i] }
        putLE(partNumber, into: &hdr, at: 0x28)
        putLE(totalParts, into: &hdr, at: 0x2A)
        putLE(wim.imageCount, into: &hdr, at: 0x2C)

        var tableHdr = ResHdr()
        tableHdr.size = UInt64(WIM_ENTRY_SIZE * entries.count)
        tableHdr.flags = RESHDR_METADATA
        tableHdr.offset = tableOff
        tableHdr.uncompressed = tableHdr.size
        hdr.replaceSubrange(0x30..<0x48, with: tableHdr.serialized())

        var xmlHdr = ResHdr()
        xmlHdr.size = UInt64(xmlData.count)
        xmlHdr.flags = wim.xml.flags
        xmlHdr.offset = xmlOff
        xmlHdr.uncompressed = xmlHdr.size
        hdr.replaceSubrange(0x48..<0x60, with: xmlHdr.serialized())

        // only part 1 carries metadata, so only it can point at boot metadata
        var bootIdx: UInt32 = 0
        if partNumber == 1 && wim.bootIdx != 0 {
            if let match = placed.first(where: {
                $0.entry.res.offset == wim.bootMeta.offset && $0.entry.res.size == wim.bootMeta.size
            }) {
                var bm = match.entry.res
                bm.offset = match.offset
                hdr.replaceSubrange(0x60..<0x78, with: bm.serialized())
                bootIdx = wim.bootIdx
            }
        }
        putLE(bootIdx, into: &hdr, at: 0x78)
        // integrity table intentionally dropped: each part would need its own

        // --- write ---
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }

        try out.write(contentsOf: Data(hdr))
        for item in placed {
            try out.seek(toOffset: item.offset)
            try wim.copyResource(item.entry.res, to: out, progress: progress)
        }
        try out.seek(toOffset: xmlOff)
        try out.write(contentsOf: xmlData)

        try out.seek(toOffset: tableOff)
        for e in entries.sorted(by: { $0.sha1.lexicographicallyPrecedes($1.sha1) }) {
            let offset = placed.first { $0.entry.sha1 == e.sha1 && $0.entry.res.size == e.res.size }?.offset ?? 0
            var r = e.res
            r.offset = offset
            try out.write(contentsOf: Data(r.serialized()))
            var meta = [UInt8](repeating: 0, count: 6)
            putLE(partNumber, into: &meta, at: 0)
            putLE(e.refcnt, into: &meta, at: 2)
            try out.write(contentsOf: Data(meta))
            try out.write(contentsOf: e.sha1)
        }
        return partSize
    }

    /// Re-open a part we just wrote and make sure it is internally consistent.
    static func verifyPart(url: URL, against expected: [WimEntry], partNumber: Int, totalParts: Int) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let part = try WimFile(url: url)

        guard Int(part.part) == partNumber, Int(part.total) == totalParts else {
            throw EngineError("\(url.lastPathComponent): numeración de partes incorrecta")
        }
        guard part.entries.count == expected.count else {
            throw EngineError("\(url.lastPathComponent): \(part.entries.count) entradas, esperaba \(expected.count)")
        }
        guard Int64(part.table.offset + part.table.size) <= size,
              Int64(part.xml.offset + part.xml.size) <= size else {
            throw EngineError("\(url.lastPathComponent): tabla o XML fuera del archivo")
        }
        for e in part.entries where Int64(e.res.offset + e.res.size) > size {
            throw EngineError("\(url.lastPathComponent): blob fuera de rango")
        }

        func fingerprint(_ list: [WimEntry]) -> [String] {
            list.map { $0.sha1.base64EncodedString() + ":" + String($0.res.size) }.sorted()
        }
        guard fingerprint(part.entries) == fingerprint(expected) else {
            throw EngineError("\(url.lastPathComponent): los blobs no coinciden con el WIM original")
        }
    }
}
