import Foundation

// MARK: - Errors

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Shell

enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        var combined: String { (out + err).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 180) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do {
            try p.run()
        } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        // a wedged diskutil/hdiutil must never freeze the UI
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return Result(status: p.terminationStatus,
                      out: String(data: od, encoding: .utf8) ?? "",
                      err: String(data: ed, encoding: .utf8) ?? "")
    }

    static func must(_ path: String, _ args: [String]) throws -> String {
        let r = run(path, args)
        guard r.ok else {
            throw EngineError("\(URL(fileURLWithPath: path).lastPathComponent) \(args.first ?? "") falló: \(r.combined)")
        }
        return r.out
    }

    /// Como `run`, pero entrega cada línea según llega. Para procesos largos que
    /// informan de su propio avance (createinstallmedia, hdiutil convert…).
    @discardableResult
    static func stream(_ path: String, _ args: [String], timeout: TimeInterval = 3600,
                       onLine: @escaping (String) -> Void) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let lock = NSLock()
        var collected = ""
        var buffer = Data()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            collected += String(data: data, encoding: .utf8) ?? ""
            buffer.append(data)
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: nl)
                buffer.removeSubrange(0...nl)
                lines.append(String(data: lineData, encoding: .utf8) ?? "")
            }
            lock.unlock()
            for line in lines { onLine(line) }
        }

        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, out: "", err: error.localizedDescription)
        }

        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        p.waitUntilExit()
        watchdog.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil

        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        collected += String(data: rest, encoding: .utf8) ?? ""
        let out = collected
        lock.unlock()
        return Result(status: p.terminationStatus, out: out, err: "")
    }
}

let DISKUTIL = "/usr/sbin/diskutil"
let HDIUTIL = "/usr/bin/hdiutil"

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func pct(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }
}
