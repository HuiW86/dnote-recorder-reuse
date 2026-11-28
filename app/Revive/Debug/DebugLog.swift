#if DEBUG
import Foundation
import Observation
import UIKit

/// Timestamped log for real-card verification (#38), mirrored to Documents/card-debug.log
/// so it can be exported into `evidence/`. Callers pass redacted text only (CLAUDE.md rule 4).
@MainActor
@Observable
final class DebugLog {
    static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("card-debug.log")

    private(set) var lines: [String] = []
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func add(_ message: String) {
        let app = UIApplication.shared
        // fg / bg / lock: background and lock-screen behaviour is what the real card run checks.
        let tag = !app.isProtectedDataAvailable ? "lock" : app.applicationState == .active ? "fg" : "bg"
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        let data = Data((line + "\n").utf8)
        do {
            if file == nil {
                if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
                    try Data().write(to: Self.fileURL)
                }
                let handle = try FileHandle(forWritingTo: Self.fileURL)
                try handle.seekToEnd()
                file = handle
            }
            try file?.write(contentsOf: data)
        } catch {
            try? file?.close()
            file = nil
        }
    }

    func clear() {
        lines = []
        try? file?.close()
        file = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }
}
#endif
