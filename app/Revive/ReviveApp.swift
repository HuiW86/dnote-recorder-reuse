// App shell. Screens are built in #41; device, sync and library logic lives in ReviveKit.

import SwiftUI
// ReviveKit is a multi-target product; import individual modules (CardService, Library, ...).
import Library

@main
struct ReviveApp: App {
    #if DEBUG
    @UIApplicationDelegateAdaptor private var delegate: DebugAppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            CardDebugView(model: delegate.model)
            #else
            Text("Revive")
            #endif
        }
    }
}

#if DEBUG
/// Creates the Bluetooth stack in `didFinishLaunching`, as state restoration requires, and
/// logs whether iOS relaunched the app for a Bluetooth event (#38 restoration check).
final class DebugAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private(set) lazy var model = CardDebugModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let centrals = options?[.bluetoothCentrals] as? [String] ?? []
        MainActor.assumeIsolated {
            model.log.add("launch: bluetoothCentrals=\(centrals) state=\(application.applicationState.rawValue)")
        }
        return true
    }
}
#endif
