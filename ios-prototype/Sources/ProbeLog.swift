import Foundation
import UIKit

/// Timestamped log, mirrored to Documents/probe.log so evidence can be pulled with devicectl.
@MainActor
final class ProbeLog: ObservableObject {
    static let shared = ProbeLog()
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let fileURL = documents.appendingPathComponent("probe.log")

    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func add(_ message: String) {
        let app = UIApplication.shared
        let tag = !app.isProtectedDataAvailable ? "lock" : app.applicationState == .active ? "fg" : "bg"
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        print(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Self.fileURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: Self.fileURL)
        }
    }
}
