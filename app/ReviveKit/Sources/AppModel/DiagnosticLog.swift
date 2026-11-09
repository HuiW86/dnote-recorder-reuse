import CardProtocol
import Foundation

/// Local diagnostic log the user exports from P09 (product-spec.md §8, §4.2): state changes,
/// error codes, commands and durations. Stays on the phone until the user shares it (hard
/// rule 3). Callers pass redacted text only: serials through `Redactor.serialTag`, no
/// `btaddr`, no `bondId`, no audio (hard rule 4).
@MainActor
public final class DiagnosticLog {
    public let fileURL: URL
    /// Past this size the oldest half is dropped.
    private let maxBytes: Int
    private let now: () -> Date
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return f
    }()

    public init(fileURL: URL, maxBytes: Int = 1_000_000, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.now = now
    }

    public func add(_ category: String, _ message: String) {
        let data = Data("\(formatter.string(from: now())) [\(category)] \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return }
            try? handle.write(contentsOf: data)
            if Int(size) + data.count > maxBytes { trim() }
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// The log as it is now, for the share sheet; nil when nothing has been written yet.
    public func contents() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Keeps the newest half, cut at a line start.
    private func trim() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: fileURL, options: .atomic)
    }
}

extension DiagnosticLog {
    /// A card's `0x80` without what identifies it: serial as its tag, no Bluetooth name.
    static func describe(_ info: DeviceInfo) -> String {
        "sn \(Redactor.serialTag(info.serial)) fw \(info.firmware) rec \(info.recordingState) "
            + "battery \(info.battery.map(String.init) ?? "?") free \(info.freeSpace.map(String.init) ?? "?")"
            + "/\(info.totalSpace.map(String.init) ?? "?")"
    }
}
