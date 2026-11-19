import Foundation
import Library

/// What the "录音已同步" notification says after a sync pass that ran while the app was not in
/// front (features.md X8). Worked out here so it can be tested; the app posts it.
public struct SyncNotice: Equatable, Sendable {
    /// `userInfo` key carrying `recordingId` as a string.
    public static let recordingKey = "revive.recordingId"

    /// New card recordings stored by the pass, not counting ones already in 最近删除.
    public let count: Int
    /// The recording a tap opens when the pass stored exactly one; nil opens the list (#85).
    public let recordingId: UUID?

    public init(count: Int, recordingId: UUID?) {
        self.count = count
        self.recordingId = recordingId
    }

    public var title: String { "录音已同步" }
    public var body: String { "\(count) 条新录音已存入手机" }

    /// Nil when the pass stored nothing worth telling.
    public static func make(_ recordings: [Recording], storedSince start: Date) -> SyncNotice? {
        let stored = recordings.filter { $0.source == .card && $0.trashedAt == nil && $0.createdAt >= start }
        guard !stored.isEmpty else { return nil }
        return SyncNotice(count: stored.count, recordingId: stored.count == 1 ? stored[0].id : nil)
    }
}
