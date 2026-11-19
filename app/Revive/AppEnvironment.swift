import AppModel
import CardLink
import CardService
import CoreBluetooth
import Foundation
import Library
import Assistant
import Observation
import os
import Player
import SyncEngine

/// Composition root: the library, preferences and the one Bluetooth stack. Created in
/// `didFinishLaunching`, as state restoration requires.
@MainActor
@Observable
final class AppEnvironment {
    let preferences = Preferences()
    /// The user's AI service, read fresh each time (features.md X11): nil until an address and
    /// a model are saved. The key comes from the Keychain.
    let assistantConfig = AssistantConfigSource {
        let defaults = UserDefaults.standard
        let config = ServiceConfig(baseURL: defaults.string(forKey: Preferences.assistantBaseURLKey) ?? "",
                                   model: defaults.string(forKey: Preferences.assistantModelKey) ?? "",
                                   apiKey: (try? KeychainKeyStore().read()) ?? "")
        return config.isComplete ? config : nil
    }

    /// The same service for transcription, when the user gave it a transcription model; nil
    /// otherwise, and then no audio is ever uploaded (ADR-009).
    var cloudTranscriptionConfig: ServiceConfig? {
        guard let chat = assistantConfig.current() else { return nil }
        let model = preferences.assistantTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return ServiceConfig(baseURL: chat.baseURL, model: model, apiKey: chat.apiKey)
    }
    let library: RecordingLibrary?
    /// Set when the library could not be opened; the app cannot work without it.
    let libraryError: String?
    /// Nil until Bluetooth is started: creating the stack is what shows the permission prompt,
    /// so first use waits for "继续" on P01 (product-spec.md §3.1).
    private(set) var session: CardSession?
    /// At least one card paired from this phone; false shows the first-use flow.
    private(set) var hasPairedDevice: Bool
    /// One player for the whole app, so leaving a page does not cut playback off.
    let player: RecordingPlayer?
    /// The phone's microphone, for when no card is at hand (features.md X18).
    let phoneRecorder: PhoneRecorder?
    /// Exported from P09; written by the card session (product-spec.md §8).
    let diagnostics = DiagnosticLog(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics.log"))

    #if DEBUG
    let debugLog = DebugLog()
    #endif

    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "App")
    /// Kept alive for as long as the Bluetooth stack (features.md X8).
    @ObservationIgnored private var syncNotifier: SyncNotifier?

    init() {
        do {
            // The DEBUG demo library (screenshots) lives apart from the real one.
            let folder = LaunchOptions.demoLibrary ? "demo-library" : "library"
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true)
            let opened = RecordingLibrary(database: try AppDatabase.onDisk(directory: root),
                                          store: try AudioStore(root: root))
            #if DEBUG
            if LaunchOptions.demoLibrary { DemoLibrary.seedIfEmpty(opened) }
            #endif
            library = opened
            libraryError = nil
        } catch {
            library = nil
            libraryError = String(describing: error)
            diagnostics.add("app", "library unavailable: \(error)")
        }
        hasPairedDevice = ((try? library?.pairedDevices()) ?? []).isEmpty == false
        // Recordings deleted more than 7 days ago leave 最近删除 for good (features.md D1b).
        if let purged = try? library?.purgeTrash(trashedBefore: Date().addingTimeInterval(-Recording.trashRetention)),
           purged > 0 {
            diagnostics.add("app", "purged \(purged) recording(s) from trash")
        }
        player = library.map { RecordingPlayer(library: $0) }
        phoneRecorder = library.map { PhoneRecorder(library: $0) }
        RecordingExporter.cleanUp()
    }

    /// Creates the Bluetooth stack once and returns it.
    @discardableResult
    func startBluetooth() -> CardSession? {
        if let session { return session }
        guard let library else { return nil }
        var link: any CardLink
        #if DEBUG
        if LaunchOptions.demoLibrary {
            link = DemoCardLink()
        } else {
            let bluetooth = BluetoothCardLink()
            bluetooth.onRestore = { [debugLog] in debugLog.add($0) }
            link = TappedLink(bluetooth, log: debugLog)
        }
        #else
        link = BluetoothCardLink()
        #endif
        do {
            // The build lets SyncEngine retry, once per build, files an older build could not decrypt (#59).
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            session = try CardSession(link: link, bondStore: KeychainBondStore(), library: library,
                                      syncOptions: SyncEngine.Options(appBuild: build), diagnostics: diagnostics)
            session?.deleteAfterSync = { [preferences] in preferences.deleteAfterSync(for: $0) }
            if let engine = session?.syncEngine {
                syncNotifier = SyncNotifier(engine: engine, library: library, preferences: preferences)
            }
        } catch {
            log.error("card session unavailable: \(String(describing: error), privacy: .public)")
        }
        return session
    }

    /// Re-reads whether any card is paired, after pairing or unpairing.
    func refreshDevices() {
        session?.refreshDevices()
        hasPairedDevice = ((try? library?.pairedDevices()) ?? []).isEmpty == false
    }

    static var bluetoothAuthorization: BluetoothAuthorization {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
