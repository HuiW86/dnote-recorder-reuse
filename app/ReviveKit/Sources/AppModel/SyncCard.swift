import CardService
import Foundation
import Library
import SyncEngine

/// What the home screen's SyncStatusCard shows (product-spec.md P05). Built by `make` from
/// SyncEngine and library state; nil means no card.
public enum SyncCard: Equatable, Sendable {
    case checking
    /// `index` is 1-based; `fraction` is the current file's progress, 0...1.
    case syncing(index: Int, total: Int, fraction: Double)
    case waitingForRecording
    case disconnected
    case done(at: Date)
    /// `retrying`: some of them still have automatic retries left.
    case failed(count: Int, retrying: Bool)
    case phoneStorageFull
    case undecryptable(count: Int)
    case cardSpaceLow
    /// The card answered something the protocol does not allow; the user can send the log.
    case unexpectedReply
    /// The pass stopped for another reason; the text says what to do.
    case stopped(String)

    public enum Action: Equatable, Sendable {
        case retry
        /// "导出诊断信息": this build does not retry undecryptable files, the user reports them (product-spec.md §7.1).
        case exportDiagnostics
    }

    public struct Input: Equatable, Sendable {
        public var connected: Bool
        public var status: SyncStatus
        public var isRunning: Bool
        public var progress: SyncEngine.Progress?
        public var pendingCount: Int
        public var lastCompletedAt: Date?
        public var failures: FailureCounts
        /// Free and total card storage from `0x80`; total 0 or nil means not read yet.
        public var cardFree: Int?
        public var cardTotal: Int?
        public var deleteAfterSync: Bool

        public init(connected: Bool, status: SyncStatus, isRunning: Bool = false,
                    progress: SyncEngine.Progress? = nil, pendingCount: Int = 0, lastCompletedAt: Date? = nil,
                    failures: FailureCounts = FailureCounts(retryable: 0, undecryptable: 0),
                    cardFree: Int? = nil, cardTotal: Int? = nil, deleteAfterSync: Bool = false) {
            self.connected = connected
            self.status = status
            self.isRunning = isRunning
            self.progress = progress
            self.pendingCount = pendingCount
            self.lastCompletedAt = lastCompletedAt
            self.failures = failures
            self.cardFree = cardFree
            self.cardTotal = cardTotal
            self.deleteAfterSync = deleteAfterSync
        }
    }

    public static func make(_ s: Input) -> SyncCard? {
        guard s.connected else {
            // Not connected: no card, unless a pass was cut off or files were left waiting.
            return s.status == .stopped(SyncFailure.disconnected.rawValue) || s.pendingCount > 0 ? .disconnected : nil
        }
        if case .syncing(_, let received, let total) = s.status, let p = s.progress {
            return .syncing(index: p.index, total: p.total, fraction: total > 0 ? Double(received) / Double(total) : 0)
        }
        if s.isRunning { return .checking }
        switch s.status {
        case .waitingForRecording, .stopped(SyncFailure.cardBusyRecording.rawValue):
            return .waitingForRecording
        case .stopped(SyncFailure.disconnected.rawValue):
            break  // back on the link; the next pass starts by itself
        case .stopped(SyncFailure.phoneStorageFull.rawValue):
            return .phoneStorageFull
        case .stopped(SyncFailure.unexpectedReply.rawValue):
            return .unexpectedReply
        case .stopped(let code):
            return .stopped(stoppedText(code))
        case .idle, .syncing:
            break
        }
        if s.failures.retryable > 0 { return .failed(count: s.failures.retryable, retrying: s.failures.autoRetrying > 0) }
        if s.failures.undecryptable > 0 { return .undecryptable(count: s.failures.undecryptable) }
        if !s.deleteAfterSync, let free = s.cardFree, let total = s.cardTotal, total > 0,
           Double(free) / Double(total) < 0.1 {
            return .cardSpaceLow
        }
        return s.lastCompletedAt.map { .done(at: $0) }
    }

    public var title: String {
        switch self {
        case .checking: "正在检查录音卡…"
        case .syncing(let index, let total, _): "正在同步 第 \(index) / \(total) 条"
        case .waitingForRecording: "录音中，结束后自动同步"
        case .disconnected: "连接已断开，连上后继续同步"
        case .done: "全部录音已存入手机"
        case .failed(let count, true): "\(count) 条录音同步失败，稍后自动重试"
        case .failed(let count, false): "\(count) 条录音同步失败，下拉可重试"
        case .phoneStorageFull: "手机空间不足，同步已暂停"
        case .undecryptable(let count): "\(count) 条录音无法解密，已保留在卡上"
        case .cardSpaceLow: "录音卡剩余空间不足 10%"
        case .unexpectedReply: "录音卡返回了无法识别的数据，下拉可重试"
        case .stopped(let text): text
        }
    }

    public var detail: String? {
        switch self {
        case .syncing: "同步完成前，卡上的录音不会被删除"
        case .phoneStorageFull: "清理空间后下拉重试"
        // Not 「同步后删除」: release builds do not show that switch yet (DeviceView).
        case .cardSpaceLow: "已同步的录音在手机上都有一份"
        default: nil
        }
    }

    public var action: Action? {
        switch self {
        case .failed: .retry
        case .undecryptable, .unexpectedReply: .exportDiagnostics
        default: nil
        }
    }

    /// Text for a pass that stopped early; codes are `SyncFailure` raw values (prd.md §6).
    static func stoppedText(_ code: String) -> String {
        let error: CardServiceError? = switch code {
        case SyncFailure.notPaired.rawValue: .notPaired
        case SyncFailure.cardBusy.rawValue: .cardBusy
        case SyncFailure.requestTimeout.rawValue: .requestTimeout(.listFiles)
        default: nil
        }
        return error?.userText ?? "同步中断，下拉可重试"
    }
}
