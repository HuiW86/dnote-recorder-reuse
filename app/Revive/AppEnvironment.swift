import AppModel
import CardLink
import CardService
import CoreBluetooth
import Foundation
import Library
import Observation
import os

/// Composition root: the library, preferences and the one Bluetooth stack. Created in
/// `didFinishLaunching`, as state restoration requires.
@MainActor
@Observable
final class AppEnvironment {
    let preferences = Preferences()
    let library: RecordingLibrary?
    /// Set when the library could not be opened; the app cannot work without it.
    let libraryError: String?
    /// Nil until Bluetooth is started: creating the stack is what shows the permission prompt,
    /// so first use waits for "继续" on P01 (product-spec.md §3.1).
    private(set) var session: CardSession?
    /// At least one card paired from this phone; false shows the first-use flow.
    private(set) var hasPairedDevice: Bool

    #if DEBUG
    let debugLog = DebugLog()
    #endif

    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "App")

    init() {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("library", isDirectory: true)
            library = RecordingLibrary(database: try AppDatabase.onDisk(directory: root),
                                       store: try AudioStore(root: root))
            libraryError = nil
        } catch {
            library = nil
            libraryError = String(describing: error)
        }
        hasPairedDevice = ((try? library?.pairedDevices()) ?? []).isEmpty == false
    }

    /// Creates the Bluetooth stack once and returns it.
    @discardableResult
    func startBluetooth() -> CardSession? {
        if let session { return session }
        guard let library else { return nil }
        var link: any CardLink = BluetoothCardLink()
        #if DEBUG
        link = TappedLink(link, log: debugLog)
        #endif
        do {
            session = try CardSession(link: link, bondStore: KeychainBondStore(), library: library)
        } catch {
            log.error("card session unavailable: \(String(describing: error), privacy: .public)")
        }
        return session
    }

    /// Re-reads whether any card is paired, after pairing or unpairing.
    func refreshDevices() {
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
