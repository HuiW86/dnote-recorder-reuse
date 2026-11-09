import AppModel
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Library
import SyncEngine
import Testing

// product-spec.md §7.1: every app error code has the text and component the table gives.
// The texts are pinned here so a change has to update the spec too.

struct ErrorTextTests {
    @Test func textsFollowTheSpecTable() {
        let expected: [(CardServiceError, String?)] = [
            (.bluetoothOff, "蓝牙已关闭，请在控制中心或设置中打开"),
            (.bluetoothUnauthorized, "需要蓝牙权限才能连接录音卡"),
            (.bluetoothUnsupported, "蓝牙暂时不可用，请稍后再试"),
            (.connectTimeout, "连接超时。按住卡上的录音键，白灯闪烁后重试"),
            (.connectFailed, "连接超时。按住卡上的录音键，白灯闪烁后重试"),
            (.unknownCard, "找不到这张录音卡，请重新搜索"),
            (.disconnected, "连接已断开，连上后继续"),
            (.requestTimeout(.recordingStatus), "录音卡没有响应，请重试"),
            (.notPaired, "这张卡需要重新配对"),
            (.pairVerifyFailed, "配对没有成功，请重试"),
            (.pairCancelled, nil),
            (.cardBusyRecording, "录音中，结束后自动同步"),
            (.fileNotFound, nil),
            (.unexpectedReply(.switches), "录音卡返回了无法识别的数据，请重试"),
            (.invalidArgument("x"), nil),
            (.bondStorageFailed, "无法保存配对信息，请重试"),
        ]
        for (error, text) in expected {
            #expect(error.userText == text, "\(error)")
        }
        #expect(FirmwareText.unverified == "此固件版本未经验证，如遇问题请反馈")
    }

    /// The codes shown on the SyncStatusCard rather than as a text of their own.
    @Test func syncCodesMapToSyncCardRows() {
        func row(_ code: String) -> SyncCard? { SyncCard.make(.init(connected: true, status: .stopped(code))) }
        #expect(row("phoneStorageFull")?.title == "手机空间不足，同步已暂停")
        #expect(row("cardBusyRecording")?.title == "录音中，结束后自动同步")
        #expect(row("unexpectedReply") == .unexpectedReply)
        #expect(row("unexpectedReply")?.title == "录音卡返回了无法识别的数据，下拉可重试")
        #expect(row("unexpectedReply")?.action == .exportDiagnostics)
        // A pass stopped by the phone's own storage is not retried by the timer, so it does not
        // promise an automatic retry; files that failed to store count as failed below.
        #expect(row("storeFailed")?.title == "同步中断，下拉可重试")
        let failed = SyncCard.make(.init(connected: true, status: .idle,
                                         failures: .init(retryable: 3, undecryptable: 0, autoRetrying: 3)))
        #expect(failed?.title == "3 条录音同步失败，稍后自动重试")
        let exhausted = SyncCard.make(.init(connected: true, status: .idle, failures: .init(retryable: 3, undecryptable: 0)))
        #expect(exhausted?.title == "3 条录音同步失败，下拉可重试")
        let undecryptable = SyncCard.make(.init(connected: true, status: .idle,
                                                failures: .init(retryable: 0, undecryptable: 2)))
        #expect(undecryptable?.title == "2 条录音无法解密，已保留在卡上")
        #expect(SyncCard.make(.init(connected: false, status: .stopped("disconnected")))?.title == "连接已断开，连上后继续同步")
    }
}

/// Keychain writes fail, as when the device storage is full or the Keychain is locked.
private final class FailingBondStore: BondStore {
    struct Failure: Error {}
    func bondId(serial: String) throws -> Data? { nil }
    func save(_ bondId: Data, serial: String) throws { throw Failure() }
    func remove(serial: String) throws { throw Failure() }
}

@MainActor
struct PairingErrorTests {
    /// product-spec.md §7.1 `bondStorageFailed`: a step error on P03 with retry; nothing saved.
    @Test func keychainFailureIsReportedOnPairingStep() async throws {
        let h = try Harness(card: FakeCard(paired: false), bondStore: FailingBondStore())
        try await h.scanAndSelect()
        await waitUntil("failed") { h.pairing.phase == .failed(.pairing, .bondStorageFailed) }
        #expect(try h.library.pairedDevices().isEmpty)
        h.checkNoForbiddenWrites()
    }
}
