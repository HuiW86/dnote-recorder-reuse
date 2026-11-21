import DeviceSource
import Foundation
import Library
import SyncEngine
import Testing

// SyncEngine with a device that is not a D·NOTE card (ADR-010, #73): no CardService, no frames,
// no decryption. The same state machine stores every file once, resumes a cut-off download and
// deletes on the device only after the recording is stored (CLAUDE.md rule 2).

/// Prefixes "OggS" and counts 1 ms per byte, so the stored audio shows which bytes arrived.
private struct StubConverter: SourceAudioConverter {
    func convert(_ raw: Data) throws -> SourceAudio {
        SourceAudio(ogg: Data("OggS".utf8) + raw, durationMs: raw.count)
    }
}

/// An in-memory device.
@MainActor
private final class StubDevice: SyncSource {
    var files: [String: Data]
    var startDates: [String: Date] = [:]
    var isConnected = true
    let connectionId: UUID? = UUID()
    /// The next download hands over this many bytes, then the link drops.
    var dropAfter: Int?
    private(set) var downloads: [(name: String, offset: Int)] = []
    private(set) var deleted: [String] = []

    init(files: [String: Data]) {
        self.files = files
    }

    var defaultDeviceName: String { "测试设备" }
    var audioConverter: any SourceAudioConverter { StubConverter() }

    func deviceInfo() async throws -> SourceInfo {
        SourceInfo(serial: "STUB0001", firmware: "0.1", battery: 80)
    }

    func isPairedWithThisPhone() async throws -> Bool { true }
    func isRecording() async throws -> Bool { false }

    func listFiles() async throws -> [SourceFile] {
        guard isConnected else { throw SourceError.disconnected }
        return files.map { SourceFile(name: $0.key, size: $0.value.count) }
    }

    func download(_ file: SourceFile, from offset: Int, onData: @escaping (Data) -> Void) async throws {
        guard isConnected else { throw SourceError.disconnected }
        guard let data = files[file.name] else { throw SourceError.fileNotFound }
        downloads.append((file.name, offset))
        let end = dropAfter.map { min(data.count, offset + $0) } ?? data.count
        onData(data.subdata(in: offset..<end))
        if end < data.count {
            dropAfter = nil
            isConnected = false
            throw SourceError.disconnected
        }
    }

    func delete(_ name: String) async throws {
        guard isConnected else { throw SourceError.disconnected }
        deleted.append(name)
        files[name] = nil
    }

    func startDate(of file: SourceFile) -> Date? { startDates[file.name] }
}

@MainActor
private func makeLibrary() throws -> RecordingLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("other-device-\(UUID().uuidString)")
    return RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
}

private func options(deleteAfterSync: Bool) -> SyncEngine.Options {
    SyncEngine.Options(deleteAfterSync: deleteAfterSync, retryDelays: [.seconds(60), .seconds(60), .seconds(60)],
                       spaceMargin: 0)
}

@MainActor
struct OtherDeviceTests {
    @Test func storesEachFileOnceThenDeletesIt() async throws {
        let a = Data(repeating: 1, count: 20), b = Data(repeating: 2, count: 30)
        let device = StubDevice(files: ["a": a, "b": b])
        let started = Date(timeIntervalSince1970: 1_793_000_000)
        device.startDates["a"] = started
        let library = try makeLibrary()
        let engine = try SyncEngine(source: device, library: library, options: options(deleteAfterSync: true),
                                    freeSpace: { .max })
        var saved: [Device] = []
        engine.onDeviceSaved = { saved.append($0) }

        await engine.syncNow()

        #expect(engine.status == .idle)
        let recordings = try library.recordings()
        #expect(recordings.count == 2)
        let byName = Dictionary(uniqueKeysWithValues: recordings.map { ($0.cardFileName ?? "", $0) })
        #expect(byName["a"]?.durationMs == a.count)
        #expect(byName["b"]?.durationMs == b.count)
        #expect(byName["a"]?.startedAt == started)
        #expect(saved.last?.name == "测试设备")
        // Deleted on the device only after both were stored, and confirmed by a second list.
        #expect(device.deleted.sorted() == ["a", "b"])
        #expect(device.files.isEmpty)
        let deviceId = try #require(saved.last?.id)
        #expect(try library.syncItems(deviceId: deviceId).allSatisfy { $0.state == .deletedOnCard })

        await engine.syncNow()
        #expect(device.downloads.count == 2)
        #expect(try library.recordings().count == 2)
    }

    @Test func cutOffDownloadResumesWithoutDuplicates() async throws {
        let content = Data((0..<100).map { UInt8($0) })
        let device = StubDevice(files: ["a": content])
        device.dropAfter = 40
        let library = try makeLibrary()
        let engine = try SyncEngine(source: device, library: library, options: options(deleteAfterSync: false),
                                    freeSpace: { .max })

        await engine.syncNow()
        #expect(engine.status == .stopped(SyncFailure.disconnected.rawValue))
        #expect(try library.recordings().isEmpty)

        device.isConnected = true
        await engine.syncNow()
        #expect(engine.status == .idle)
        #expect(device.downloads.map(\.offset) == [0, 40])
        let recordings = try library.recordings()
        #expect(recordings.count == 1)
        #expect(recordings.first?.durationMs == content.count)
        // "同步后删除" is off: the device keeps its copy.
        #expect(device.deleted.isEmpty)
        #expect(device.files["a"] == content)

        await engine.syncNow()
        #expect(device.downloads.count == 2)
        #expect(try library.recordings().count == 1)
    }
}
