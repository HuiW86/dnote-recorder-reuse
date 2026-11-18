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
        guard let notice = SyncNotice.make((try? library.recordings()) ?? [], storedSince: started) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        // A tap opens the recording when there is one (#85); see NotificationRouter.
        if let id = notice.recordingId { content.userInfo = [SyncNotice.recordingKey: id.uuidString] }
        // One identifier: a later sync replaces the earlier notification instead of stacking.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "revive.sync-done", content: content, trigger: nil))
    }

    /// Asks for permission to show notifications; false when the user has refused.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Whether notifications are now refused in the system settings.
    static func isDenied() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .denied)
            }
        }
    }

    /// The switch follows the system: turned off there, it reads off here too (#85).
    static func followSystemSetting(_ preferences: Preferences) async {
        guard preferences.syncNotificationsEnabled, await isDenied() else { return }
        preferences.syncNotificationsEnabled = false
    }
}

/// Opens what a tapped "录音已同步" notification is about (#85). Kept by AppEnvironment: the
/// notification center holds its delegate weakly.
@MainActor
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// Set when a notification about one recording is tapped; home opens it and clears it.
    var recordingToOpen: UUID?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let value = response.notification.request.content.userInfo[SyncNotice.recordingKey] as? String
        let id = value.flatMap(UUID.init(uuidString:))
        Task { @MainActor in self.recordingToOpen = id }
        completionHandler()
    }
}
