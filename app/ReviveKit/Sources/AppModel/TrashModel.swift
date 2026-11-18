import Foundation
import Library
import Observation

/// 最近删除 (features.md D1b): recordings deleted on this phone stay 7 days and can be restored
/// as they were. Nothing here talks to the card.
@MainActor
@Observable
public final class TrashModel {
    /// The most recently deleted first.
    public private(set) var recordings: [Recording] = []
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observation: LibraryObservation?

    public init(library: RecordingLibrary, now: @escaping () -> Date = { Date() }) {
        self.library = library
        self.now = now
    }

    public func start() {
        guard observation == nil else { return }
        observation = library.observeTrash(
            onError: { [weak self] _ in self?.toast = Toast("无法读取最近删除") },
            onChange: { [weak self] in self?.recordings = $0 })
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Whole days until the recording is removed for good; 0 on its last day.
    public func daysLeft(_ recording: Recording) -> Int {
        guard let trashedAt = recording.trashedAt else { return 0 }
        let left = trashedAt.addingTimeInterval(Recording.trashRetention).timeIntervalSince(now())
        return max(0, Int((left / 86_400).rounded(.down)))
    }

    /// "还剩 3 天", "今天到期".
    public func remainingText(_ recording: Recording) -> String {
        let days = daysLeft(recording)
        return days == 0 ? "今天到期" : "还剩 \(days) 天"
    }

    /// The card no longer holds this recording, so deleting it here loses it for good.
    public func isLastCopy(_ recording: Recording) -> Bool {
        guard recording.source == .card else { return true }
        return !((try? library.cardCopyRemains(recordingId: recording.id)) ?? false)
    }

    public func restore(_ id: UUID) {
        do {
            try library.restoreRecording(id: id)
            toast = Toast("已恢复")
        } catch {
            toast = Toast("恢复失败，请重试")
        }
    }

    public func deleteForever(_ id: UUID) {
        do {
            try library.deleteRecording(id: id)
            toast = Toast("已彻底删除")
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }

    public func empty() {
        do {
            for recording in recordings { try library.deleteRecording(id: recording.id) }
            toast = Toast("已清空")
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }
}
