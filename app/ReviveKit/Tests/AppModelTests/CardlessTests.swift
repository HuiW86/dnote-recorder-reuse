import AppModel
import CardLink
import CardService
import Foundation
import Library
import Testing

// 先不连卡 (product-spec.md P01, §2.1): the tabs over a session with no Bluetooth behind it, for
// someone without a card. Phone recording itself needs the microphone and is checked on a phone.
@MainActor
struct CardlessTests {
    @Test func choiceIsRememberedAcrossLaunches() throws {
        let suite = "test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = Preferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!first.usesWithoutCard)
        first.usesWithoutCard = true
        #expect(Preferences(defaults: try #require(UserDefaults(suiteName: suite))).usesWithoutCard)
        first.usesWithoutCard = false
        #expect(!Preferences(defaults: try #require(UserDefaults(suiteName: suite))).usesWithoutCard)
    }

    /// No card and no Bluetooth: the status is `noDevice` (the record key offers the phone and
    /// "添加录音卡"), not `bluetoothUnavailable`; imported files are listed as usual.
    @Test func homeWorksWithoutACard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cardless-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let session = try CardSession(link: NoCardLink(), bondStore: InMemoryBondStore(), library: library)
        let preferences = Preferences(defaults: try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)")))
        let model = HomeModel(session: session, preferences: preferences)
        model.start()
        #expect(model.currentDevice == nil)
        #expect(model.status == .noDevice)
        #expect(model.deviceRows.isEmpty)
        #expect(model.battery == nil)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notes = root.appendingPathComponent("想法.txt")
        try Data("先记下来，有卡以后再说。".utf8).write(to: notes)
        await model.importAudio([notes])
        #expect(model.toast?.text == "已导入")
        await waitUntil("listed") { model.recordings.count == 1 }
        #expect(model.recordings.first?.title == "想法")
        #expect(model.status == .noDevice)
        model.stop()
    }
}
