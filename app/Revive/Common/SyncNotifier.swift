import AppModel
import Library
import Observation
import SyncEngine
import UIKit
import UserNotifications

/// Posts a local notification when a sync that ran while the app was not in front stored new
/// recordings (features.md X8). Off until the user turns it on in settings; nothing leaves
/// the phone.
@MainActor
final class SyncNotifier {
    private let engine: SyncEngine
    private let library: RecordingLibrary
    private let preferences: Preferences
    /// When the pass that is running now was first seen.
    private var passStartedAt: Date?

    init(engine: SyncEngine, library: RecordingLibrary, preferences: Preferences) {
        self.engine = engine
        self.library = library
        self.preferences = preferences
        if engine.isRunning { passStartedAt = Date() }
        watch()
    }

    private func watch() {
        withObservationTracking { _ = engine.isRunning } onChange: { [weak self] in
            Task { @MainActor in
                self?.runningChanged()
                self?.watch()
            }
        }
    }

    private func runningChanged() {
        if engine.isRunning {
            if passStartedAt == nil { passStartedAt = Date() }
            return
        }
        guard let started = passStartedAt else { return }
        passStartedAt = nil
        guard preferences.syncNotificationsEnabled, UIApplication.shared.applicationState != .active else { return }
        let stored = ((try? library.recordings()) ?? []).filter {
            $0.source == .card && $0.trashedAt == nil && $0.createdAt >= started
        }.count
        guard stored > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "录音已同步"
        content.body = "\(stored) 条新录音已存入手机"
        // One identifier: a later sync replaces the earlier notification instead of stacking.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "revive.sync-done", content: content, trigger: nil))
    }

    /// Asks for permission to show notifications; false when the user has refused.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
