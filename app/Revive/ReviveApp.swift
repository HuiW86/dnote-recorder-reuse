// App shell. Screens are built in #41; device, sync and library logic lives in ReviveKit.

import SwiftUI
// ReviveKit is a multi-target product; import individual modules (CardService, Library, ...).
import Library

@main
struct ReviveApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Revive")
        }
    }
}
