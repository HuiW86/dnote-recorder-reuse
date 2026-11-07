import Foundation
import Network
import UIKit

// WiFi fast transfer over TCP 192.168.88.1:6718 (#6). Commands are plain text, from the firmware's
// recpen_file_server string table: list / list_files, get <name> (card sends the file — download),
// pull <name> (card receives a file — upload), delete <name>, quit. Replies are binary frames:
// aa | type | status | len (u16 BE) | body.

enum FastTransferError: LocalizedError {
    case closed, timeout(String), badFrame(String), status(UInt8, UInt8), notOnCard(String)
    var errorDescription: String? {
        switch self {
        case .notOnCard(let name): return "fast transfer: \(name) not on card"
        case .badFrame(let what): return "fast transfer: bad frame (\(what))"
        case .status(let type, let s): return String(format: "fast transfer: type 0x%02x failed, status 0x%02x", type, s)
        case .closed: return "fast transfer: connection closed by card"
        case .timeout(let what): return "fast transfer timeout: \(what)"
        }
    }
}

/// One TCP connection to the card. A single receive loop appends into `buffer`, so a read that
/// times out never leaves a dangling receive that would swallow the next bytes.
@MainActor
final class FastLink {
    private let conn: NWConnection
    private var buffer = Data()
    private(set) var closed = false
    private(set) var received = 0

    private init(_ conn: NWConnection) { self.conn = conn }

    static func connect(timeout: Double = 5) async throws -> FastLink {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        let conn = NWConnection(host: .init(FastTransfer.host), port: .init(rawValue: FastTransfer.port)!, using: params)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; c.resume() }
                case .failed(let e), .waiting(let e): if !done { done = true; conn.cancel(); c.resume(throwing: e) }
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !done { done = true; conn.cancel(); c.resume(throwing: FastTransferError.timeout("tcp connect")) }
            }
        }
        let link = FastLink(conn)
        link.pump()
        return link
    }

    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.buffer.append(data); self.received += data.count }
                if isComplete || error != nil { self.closed = true } else { self.pump() }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    func send(_ text: String) async throws { try await send(Data(text.utf8)) }

    /// Wait for data, then keep reading until nothing new arrives for `idle` seconds, the peer
    /// closes, or `limit` seconds pass. Returns what arrived (possibly empty) and clears it.
    func read(idle: Double, limit: Double = 30) async -> Data {
        let start = Date()
        var lastSize = buffer.count
        var lastChange = Date()
        while !closed, Date().timeIntervalSince(start) < limit {
            try? await Task.sleep(for: .milliseconds(50))
            if buffer.count != lastSize { lastSize = buffer.count; lastChange = Date() }
            if Date().timeIntervalSince(lastChange) >= idle { break }
        }
        return take(buffer.count)
    }

    /// Bytes currently buffered, without waiting.
    var available: Int { buffer.count }

    func take(_ n: Int) -> Data {
        let out = buffer.prefix(n)
        buffer.removeFirst(out.count)
        return Data(out)
    }

    /// Next complete frame. Throws if the card closes or sends nothing for `stall` seconds.
    func frame(stall: Double = 20) async throws -> FTFrame {
        var last = Date()
        var seen = buffer.count
        while true {
            if let f = try FTFrame.parse(&buffer) { return f }
            if closed { throw FastTransferError.closed }
            if buffer.count != seen { seen = buffer.count; last = Date() }
            if Date().timeIntervalSince(last) > stall { throw FastTransferError.timeout("no data for \(Int(stall)) s") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() { conn.cancel(); closed = true }
}

/// One reply frame: aa | type | status | len (u16 BE) | body.
struct FTFrame: Equatable {
    static let magic: UInt8 = 0xaa
    static let headerSize = 5
    let type: UInt8
    let status: UInt8
    let body: Data

    enum Kind: UInt8 { case list = 0x00, get = 0x01, pull = 0x04, unknown = 0x05 }

    /// Split one frame off the front of `buf`. nil = need more bytes; throws on a bad magic.
    static func parse(_ buf: inout Data) throws -> FTFrame? {
        guard buf.count >= headerSize else { return nil }
        let h = [UInt8](buf.prefix(headerSize))
        guard h[0] == magic else { throw FastTransferError.badFrame("magic \(Data(h).hex)") }
        let len = Int(h[3]) << 8 | Int(h[4])
        guard buf.count >= headerSize + len else { return nil }
        let body = Data(buf.dropFirst(headerSize).prefix(len))
        buf = Data(buf.dropFirst(headerSize + len))
        return FTFrame(type: h[1], status: h[2], body: body)
    }
}

extension Data {
    /// Little-endian u32 at `offset` from the start (index-safe for slices).
    func u32le(_ offset: Int) -> Int {
        let b = [UInt8](dropFirst(offset).prefix(4))
        return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    }
}

/// List frame body: index u32 | total u32 | size u32 | name (NUL-terminated).
/// The listing ends with a sentinel entry named "0" with size 0.
struct FTListEntry: Equatable {
    let index: Int, total: Int, size: Int, name: String
    var isEnd: Bool { size == 0 && name == "0" }

    init?(_ body: Data) {
        guard body.count >= 13 else { return nil }
        index = body.u32le(0); total = body.u32le(4); size = body.u32le(8)
        name = String(decoding: body.dropFirst(12).prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Get frame body: total u32 | offset u32 | chunk u32 | 2 bytes (meaning unknown) | data[chunk].
struct FTChunk: Equatable {
    static let headerSize = 14
    let total: Int, offset: Int, tag: Data, data: Data
    var isLast: Bool { offset + data.count >= total }

    init(_ body: Data) throws {
        guard body.count >= Self.headerSize else { throw FastTransferError.badFrame("get body \(body.count)B") }
        total = body.u32le(0); offset = body.u32le(4)
        let chunk = body.u32le(8)
        tag = Data(body.dropFirst(12).prefix(2))
        data = Data(body.dropFirst(Self.headerSize))
        guard data.count == chunk else { throw FastTransferError.badFrame("chunk says \(chunk)B, carries \(data.count)B") }
    }
}

extension Data {
    /// Printable preview: UTF-8 with control bytes escaped, truncated.
    func preview(_ max: Int = 300) -> String {
        let head = prefix(max)
        let text = head.map { b -> String in
            switch b {
            case 0x0a: return "\\n"
            case 0x0d: return "\\r"
            case 0x20..<0x7f: return String(UnicodeScalar(b))
            default: return String(format: "\\x%02x", b)
            }
        }.joined()
        return count > max ? text + "…(+\(count - max)B)" : text
    }
}

extension Probe {
    /// #6 phase A: find the wire format. Sends only list_files and get variants (plus one
    /// nonsense word to see the "unknown" reply) — never delete or pull, which write to the card. Every reply is
    /// logged and saved raw to Documents/ft-probe/ for offline analysis.
    func fastTransferProbe() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        // Pick the smallest recording over BLE so a pull in the probe stays short.
        try await listFiles()
        let sample = files.filter { $0.size > 0 }.min { $0.size < $1.size }
        log.add("ft-probe: BLE list \(files.count) files; pull sample=\(sample.map { "\($0.name)(\($0.size))" } ?? "none")")

        let dir = ProbeLog.documents.appendingPathComponent("ft-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var steps: [(label: String, payload: String)] = [
            ("unknown", "hello"),
            ("list", "list_files"),
            ("list-lf", "list_files\n"),
            ("list-crlf", "list_files\r\n"),
        ]
        if let s = sample {
            steps += [("get-space", "get \(s.name)"), ("get-space-lf", "get \(s.name)\n")]
        }
        steps.append(("list-after", "list_files"))

        let outcome = try await withHotspot { first in
            var link = first
            // A reconnected link is not the one withHotspot closes, so close whichever is current.
            defer { link.close() }
            let banner = await link.read(idle: 3)
            log.add("ft-probe: banner \(banner.count)B \(banner.preview())")
            var getDone = false
            for (n, step) in steps.enumerated() where !(getDone && step.label.hasPrefix("get")) {
                if link.closed {
                    log.add("ft-probe: link closed, reconnecting")
                    link = try await FastLink.connect()
                }
                let isGet = step.label.hasPrefix("get")
                let t0 = Date()
                try await link.send(step.payload)
                let reply = await link.read(idle: isGet ? 3 : 1.5, limit: isGet ? 120 : 6)
                let dt = Date().timeIntervalSince(t0)
                let file = dir.appendingPathComponent(String(format: "%02d-%@.bin", n, step.label))
                try reply.write(to: file)
                log.add(String(format: "ft-probe: [%@] sent %@ -> %dB in %.2fs closed=%@", step.label,
                               Data(step.payload.utf8).preview(), reply.count, dt, "\(link.closed)"))
                log.add("ft-probe: [\(step.label)] head \(reply.prefix(48).hex)")
                log.add("ft-probe: [\(step.label)] text \(reply.preview())")
                if reply.count > 300 {
                    log.add("ft-probe: [\(step.label)] tail \(reply.suffix(200).preview(200))")
                }
                // Once one get variant returns the file, skip the other variant.
                if isGet, reply.count > 1024 { getDone = true }
            }
        }
        log.add("ft-probe: done, hotspot outcome \(outcome.rawValue)")
    }
}

extension Probe {
    /// list_files over TCP. Returns the entries before the end sentinel.
    func fastTransferList(_ link: FastLink) async throws -> [FTListEntry] {
        try await link.send("list_files")
        var entries: [FTListEntry] = []
        while true {
            let f = try await link.frame(stall: 6)
            guard f.type == FTFrame.Kind.list.rawValue else { throw FastTransferError.badFrame(String(format: "type 0x%02x in list", f.type)) }
            guard f.status == 0 else { throw FastTransferError.status(f.type, f.status) }
            guard let e = FTListEntry(f.body) else { throw FastTransferError.badFrame("list body \(f.body.count)B") }
            if e.isEnd { break }
            entries.append(e)
        }
        log.add("ft-list: \(entries.count) files " + entries.map { "\($0.name)(\($0.size))" }.joined(separator: " "))
        return entries
    }

    /// get <name> over TCP: reassemble the chunks, check offsets are contiguous and the total
    /// matches, save to Documents/downloads/<name>.ft.raw. Returns (bytes, seconds).
    @discardableResult
    func fastTransferGet(_ link: FastLink, name: String, expectedSize: Int) async throws -> (Data, Double) {
        let t0 = Date()
        try await link.send("get \(name)")
        var data = Data()
        data.reserveCapacity(expectedSize)
        var chunks = 0
        var tags: [Data: Int] = [:]
        var sizes: [Int: Int] = [:]
        var nextLog = 1 << 20
        while true {
            let f = try await link.frame()
            guard f.type == FTFrame.Kind.get.rawValue else { throw FastTransferError.badFrame(String(format: "type 0x%02x in get", f.type)) }
            guard f.status == 0 else { throw FastTransferError.status(f.type, f.status) }
            let c = try FTChunk(f.body)
            guard c.offset == data.count else { throw FastTransferError.badFrame("offset \(c.offset), have \(data.count)") }
            guard c.total == expectedSize else { throw FastTransferError.badFrame("total \(c.total), listed \(expectedSize)") }
            data.append(c.data)
            chunks += 1
            tags[c.tag, default: 0] += 1
            sizes[c.data.count, default: 0] += 1
            if data.count >= nextLog {
                nextLog += 1 << 20
                log.add(String(format: "ft-get: %@ %d/%d B %.1fs", name, data.count, expectedSize, Date().timeIntervalSince(t0)))
            }
            if c.isLast { break }
        }
        let dt = Date().timeIntervalSince(t0)
        let dir = ProbeLog.documents.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name + ".ft.raw"))
        let topSizes = sizes.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)B×\($0.value)" }.joined(separator: " ")
        let topTags = tags.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key.hex)×\($0.value)" }.joined(separator: " ")
        log.add(String(format: "ft-get: done %@ %dB in %.2fs = %.2f KB/s, %d chunks [%@], tags [%@] (%d distinct)",
                       name, data.count, dt, Double(data.count) / 1024 / dt, chunks, topSizes, topTags, tags.count))
        log.add("ft-get: sha256 raw=\(data.sha256)")
        return (data, dt)
    }

    /// #6 measurement: one hotspot session, list over TCP, then `runs` sequential downloads of
    /// `name`. Each result is compared with the BLE copy in Documents/downloads, if one exists.
    func fastTransferRuns(name: String, runs: Int) async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let bleURL = ProbeLog.documents.appendingPathComponent("downloads/\(name).raw")
        let bleSha = (try? Data(contentsOf: bleURL))?.sha256
        log.add("ft-runs: \(name) x\(runs); BLE copy sha256=\(bleSha ?? "none")")

        let outcome = try await withHotspot { link in
            let entries = try await fastTransferList(link)
            guard let entry = entries.first(where: { $0.name == name }) else {
                log.add("ft-runs: \(name) not on card [FAIL]")
                throw FastTransferError.notOnCard(name)
            }
            var rates: [Double] = []
            for run in 1...runs {
                log.add("=== ft run \(run)/\(runs) ===")
                let (data, dt) = try await fastTransferGet(link, name: name, expectedSize: entry.size)
                rates.append(Double(data.count) / 1024 / dt)
                let verdict = bleSha.map { $0 == data.sha256 ? "matches BLE [PASS]" : "DIFFERS from BLE [FAIL]" } ?? "no BLE copy"
                log.add("ft-runs: run \(run) size \(data.count == entry.size ? "OK" : "MISMATCH") sha \(verdict)")
            }
            let mean = rates.reduce(0, +) / Double(rates.count)
            log.add(String(format: "ft-runs: [SUMMARY] %d runs, KB/s %@, mean %.2f, min %.2f, max %.2f", runs,
                           rates.map { String(format: "%.2f", $0) }.joined(separator: " / "),
                           mean, rates.min() ?? 0, rates.max() ?? 0))
        }
        log.add("ft-runs: hotspot outcome \(outcome.rawValue)")
    }
}
