import Account
import AIRoute
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
import Transcription

/// Composition root: the library, preferences and the one Bluetooth stack. Created in
/// `didFinishLaunching`, as state restoration requires.
@MainActor
@Observable
final class AppEnvironment {
    let preferences = Preferences()
    /// The user's AI service, read fresh each time (features.md X11): nil until an address and
    /// a model are saved. The key comes from the Keychain.
    let assistantConfig = AssistantConfigSource.saved()

    /// The 闻笺 account (features.md K1); nil unless the build names a server (`ReviveAPIBaseURL`),
    /// so a build without one shows no account anywhere. Never needed by the card (CLAUDE.md rule 3).
    let account: AccountSession? = AccountService.session()

    /// The three AI paths for the recording page (product-spec.md §7.3b).
    func aiPaths(library: RecordingLibrary) -> AIPaths {
        AIPaths.app(preferences: preferences, library: library, assistant: assistantConfig, account: account)
    }

    /// 录完自动整理's transcriber: the default way when it can be used now without asking
    /// (`AIRoute.automatic`). The phone only once speech recognition was allowed, so no prompt
    /// appears without a tap; the 闻笺 account is left for the page.
    func automaticTranscriber(library: RecordingLibrary) -> (any SpeechTranscribing)? {
        let situation = AccountAI.situation(
            for: .transcribe, preferences: preferences,
            onDeviceSupported: OnDeviceTranscriber.isSupported() && OnDeviceTranscriber.isAuthorized,
            ownTranscription: TranscriberChoice.cloudConfig(preferences: preferences, assistant: assistantConfig) != nil,
            ownService: assistantConfig.current() != nil, accountSignedIn: nil, hasTranscript: false)
        // A phone that had 录完自动整理 on with no way to transcribe kept skipping that step; it
        // keeps doing so until a 默认转写方式 is chosen, so the upgrade sends nothing new.
        if preferences.defaultTranscriptionPath == nil, preferences.autoTranscriptionSkippedBefore { return nil }
        guard let path = AIRoute.automatic(.transcribe, in: situation) else { return nil }
        return aiPaths(library: library).transcriber(path)
    }

    /// 录完自动整理 (features.md X22); nil without a library.
    private(set) var autoProcessor: AutoProcessor?
    let library: RecordingLibrary?
    /// Set when the library could not be opened; the app cannot work without it.
    let libraryError: String?
    /// Nil until Bluetooth is started: creating the stack is what shows the permission prompt,
    /// so first use waits for "继续" on P01 (product-spec.md §3.1).
    private(set) var session: CardSession?
    /// At least one card paired from this phone; false shows the first-use flow, unless the
    /// user chose 先不连卡 (`Preferences.usesWithoutCard`).
    private(set) var hasPairedDevice: Bool
    /// The tabs' session for 先不连卡 while Bluetooth was never asked about: no CoreBluetooth
    /// behind it (`NoCardLink`), so iOS shows no prompt before P01 has explained it.
    @ObservationIgnored private var cardlessSession: CardSession?
    /// One player for the whole app, so leaving a page does not cut playback off.
    let player: RecordingPlayer?
    /// The phone's microphone, for when no card is at hand (features.md X18).
    let phoneRecorder: PhoneRecorder?
    /// Exported from P09; written by the card session (product-spec.md §8).
    let diagnostics = DiagnosticLog(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics.log"))

    /// Taps on the sync notification (#85); the notification center's delegate.
    let notifications = NotificationRouter()
    /// Audio files other apps handed over (features.md E2), waiting for the tabs to import them.
    var incomingAudio: [URL] = []

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
        // §7.3b: a phone that had the app before keeps the ways it used, once.
        preferences.adoptEarlierAIDefaults(
            ownTranscription: TranscriberChoice.cloudConfig(preferences: preferences, assistant: assistantConfig) != nil,
            ownService: assistantConfig.current() != nil)
        if let library {
            let processor = AutoProcessor(library: library, preferences: preferences,
                                          transcriberSource: { [unowned self] in self.automaticTranscriber(library: library) },
                                          assistant: assistantConfig, diagnostics: diagnostics)
            processor.start()
            autoProcessor = processor
        }
    }

    /// Creates the Bluetooth stack once and returns it.
    @discardableResult
    func startBluetooth() -> CardSession? {
        if let session { return session }
        guard let library else { return nil }
        var link: any CardLink
        #if DEBUG
        if LaunchOptions.demoLibrary {
            link = NoCardLink()
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

    /// The session the tabs run on. The real Bluetooth stack whenever it exists, a card is
    /// paired, or iOS has already answered about Bluetooth (starting it then shows no prompt);
    /// otherwise, for 先不连卡, a session over `NoCardLink`.
    func mainSession() -> CardSession? {
        if BluetoothStart.realStackForTabs(stackExists: session != nil, hasPairedCard: hasPairedDevice,
                                           authorization: Self.bluetoothAuthorization) {
            return startBluetooth()
        }
        if let cardlessSession { return cardlessSession }
        guard let library else { return nil }
        cardlessSession = try? CardSession(link: NoCardLink(), bondStore: KeychainBondStore(), library: library,
                                           diagnostics: diagnostics)
        return cardlessSession
    }

    /// The tabs run without a Bluetooth stack (先不连卡); adding a card then goes through P01.
    var isCardless: Bool { session == nil }

    /// "添加录音卡" while `isCardless`: back to the first-use flow, where P01 says what Bluetooth
    /// is for before iOS asks (product-spec.md §3.1). Its own "先不连卡" comes back here.
    func addFirstCard() {
        diagnostics.add("app", "add first card from 先不连卡")
        preferences.usesWithoutCard = false
    }

    /// Re-reads whether any card is paired, after pairing or unpairing.
    func refreshDevices() {
        session?.refreshDevices()
        hasPairedDevice = ((try? library?.pairedDevices()) ?? []).isEmpty == false
        // Paired now: unpairing the last card goes back to P01 as for everyone else (§2.1), and
        // P01 offers 先不连卡 again.
        if hasPairedDevice { preferences.usesWithoutCard = false }
    }

    static var bluetoothAuthorization: BluetoothAuthorization {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// Where the account lives: the server named in Info.plist (`ReviveAPIBaseURL`, from
/// project.yml), the refresh token in the Keychain.
enum AccountService {
    static func session(bundle: Bundle = .main) -> AccountSession? {
        guard let text = bundle.object(forInfoDictionaryKey: "ReviveAPIBaseURL") as? String,
              let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", url.host != nil else { return nil }
        return AccountSession(client: AccountClient(baseURL: url), store: KeychainSessionStore())
    }
}
