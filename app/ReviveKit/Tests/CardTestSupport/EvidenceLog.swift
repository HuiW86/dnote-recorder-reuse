import Foundation

/// Reads notifications from real-card logs under `evidence/` for replay (test-spec.md §2).
///
/// Handles both log formats in the repo: `{"event":"notify","hex":...}` (v1-live) and
/// `{"kind":"notify","hex":...}` (v34-device-check). Order is preserved; timing is not.
public enum EvidenceLog {
    public static func notifications(at url: URL) throws -> [Data] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Data? in
                guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      (obj["event"] ?? obj["kind"]) as? String == "notify",
                      let hex = obj["hex"] as? String else { return nil }
                return Data(hex: hex)
            }
    }

    /// Repository root, found from this source file's location.
    public static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("evidence").path) { return url }
        }
        fatalError("evidence/ not found above \(#filePath)")
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
