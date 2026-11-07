// App shell. Screen state lives in ReviveKit's AppModel; device, sync and library logic in
// the other ReviveKit modules.

import SwiftUI
import UIKit

@main
struct ReviveApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView(env: delegate.env)
        }
    }
}

/// Builds the environment in `didFinishLaunching`, as Bluetooth state restoration requires.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private(set) lazy var env = AppEnvironment()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let centrals = options?[.bluetoothCentrals] as? [String] ?? []
        MainActor.assumeIsolated {
            #if DEBUG
            env.debugLog.add("launch: bluetoothCentrals=\(centrals) state=\(application.applicationState.rawValue)")
            #endif
            // With a paired card, or when iOS relaunched us for one, the stack must exist now so
            // pending connects and restoration work. First use waits for P01 instead.
            if env.hasPairedDevice || !centrals.isEmpty { env.startBluetooth() }
        }
        return true
    }
}
