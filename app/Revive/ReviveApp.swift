// App shell. Screen state lives in ReviveKit's AppModel; device, sync and library logic in
// the other ReviveKit modules.

import SwiftUI
import UIKit
import UserNotifications

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
            // Before launch ends, so a tap that launched the app is delivered (#85).
            UNUserNotificationCenter.current().delegate = env.notifications
            #if DEBUG
            env.debugLog.add("launch: bluetoothCentrals=\(centrals) state=\(application.applicationState.rawValue)")
            #endif
            // With a paired card, or when iOS relaunched us for one, the stack must exist now so
            // pending connects and restoration work. Once Bluetooth is authorized, creating the
            // manager shows no prompt, so start it too (prewarm launches carry no centrals key).
            // Otherwise first use waits for P01, which asks for the permission.
            if env.hasPairedDevice || !centrals.isEmpty || AppEnvironment.bluetoothAuthorization == .allowed {
                env.startBluetooth()
            }
        }
        return true
    }
}
