import Foundation

/// Audio files under the library root in Application Support (prd.md §5):
/// `audio/<recording id>.ogg`, `tmp/` for downloads in progress, `staging/` for OGG files
/// before their atomic move, `diagnostics/` for raw bytes that failed to decrypt, `decoded/`
/// for PCM copies made by the player on systems that cannot play OGG directly.
public struct AudioStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        for dir in [audioDir, tmpDir, stagingDir, diagnosticsDir, decodedDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var audioDir: URL { root.appendingPathComponent("audio", isDirectory: true) }
    var tmpDir: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var stagingDir: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public var diagnosticsDir: URL { root.appendingPathComponent("diagnostics", isDirectory: true) }
    var decodedDir: URL { root.appendingPathComponent("decoded", isDirectory: true) }

    public func url(forAudioPath path: String) -> URL { root.appendingPathComponent(path) }

    // MARK: Downloads in progress

    public func partURL(_ itemId: Int64) -> URL { tmpDir.appendingPathComponent("\(itemId).part") }

    /// Bytes already received for an item; a resumed download starts here (prd.md §4.3).
    public func partLength(_ itemId: Int64) -> Int {
        let size = try? FileManager.default.attributesOfItem(atPath: partURL(itemId).path)[.size] as? Int
        return size ?? 0
    }

    public func openPart(_ itemId: Int64) throws -> PartWriter {
        try PartWriter(url: partURL(itemId))
    }

    public func readPart(_ itemId: Int64) throws -> Data { try Data(contentsOf: partURL(itemId)) }

    public func removePart(_ itemId: Int64) { try? FileManager.default.removeItem(at: partURL(itemId)) }

    /// After a crash nothing in tmp/ or staging/ is trusted: it may not have reached the disk.
    public func clearTemporary() {
        for dir in [tmpDir, stagingDir] {
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Stored audio

    /// Writes to staging, fsyncs, then moves into `audio/` (prd.md §4.2 step 3).
    /// Returns the path relative to `root`.
    public func storeAudio(_ data: Data, id: UUID) throws -> String {
        let name = "\(id.uuidString).ogg"
        let staging = stagingDir.appendingPathComponent(name)
        let final = audioDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: staging)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: staging, to: final)
        return "audio/\(name)"
    }

    /// Moves a finished file (the phone recorder's `.m4a`, features.md X18) into `audio/` under the
    /// recording's id, keeping its extension. Returns the path relative to `root`.
    public func importAudio(from source: URL, id: UUID) throws -> String {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = "\(id.uuidString).\(ext)"
        let final = audioDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: source, to: final)
        return "audio/\(name)"
    }

    public func removeAudio(_ path: String) { try? FileManager.default.removeItem(at: url(forAudioPath: path)) }

    // MARK: Decoded copies (Player)

    /// Where the player keeps a recording's decoded PCM copy.
    public func decodedURL(for id: UUID) -> URL { decodedDir.appendingPathComponent("\(id.uuidString).caf") }

    public func removeDecoded(_ id: UUID) { try? FileManager.default.removeItem(at: decodedURL(for: id)) }

    /// Removes decoded copies of deleted recordings and unfinished decodes.
    func removeDecoded(except keep: Set<UUID>) {
        for url in (try? FileManager.default.contentsOfDirectory(at: decodedDir, includingPropertiesForKeys: nil)) ?? [] {
            let id = url.pathExtension == "caf" ? UUID(uuidString: url.deletingPathExtension().lastPathComponent) : nil
            if id.map(keep.contains) != true { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Ids of the OGG files in `audio/`.
    public func storedAudioIds() -> [UUID] {
        storedAudioFiles().filter { $0.path.hasSuffix(".ogg") }.map(\.id)
    }

    /// Every audio file in `audio/` named after a recording id: card OGG files and phone M4A
    /// files. `path` is relative to `root`.
    public func storedAudioFiles() -> [(id: UUID, path: String)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard ["ogg", "m4a"].contains(url.pathExtension),
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return (id, "audio/\(url.lastPathComponent)")
        }
    }

    // MARK: Diagnostics and space

    /// Keeps the raw bytes of a file that failed to decrypt, for a bug report (prd.md §6).
    public func saveDiagnostic(_ data: Data, name: String) throws {
        try data.write(to: diagnosticsDir.appendingPathComponent(name), options: .atomic)
    }

    public func availableCapacity() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// Appends download chunks to a part file; one handle for the whole download.
public final class PartWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ data: Data) throws { try handle.write(contentsOf: data) }

    public func close() { try? handle.close() }

    deinit { try? handle.close() }
}
