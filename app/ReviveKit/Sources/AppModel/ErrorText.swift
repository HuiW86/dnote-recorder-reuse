import CardService

// User-facing text for app error codes (product-spec.md §7.1). Say what happened, whether
// the recordings are safe, and what to do next; never show codes or command bytes.

extension CardServiceError {
    /// Text for a step or a page; nil when the code is not shown to the user.
    public var userText: String? {
        switch self {
        case .bluetoothOff: "蓝牙已关闭，请在控制中心或设置中打开"
        case .bluetoothUnauthorized: "需要蓝牙权限才能连接录音卡"
        case .bluetoothUnsupported: "蓝牙暂时不可用，请稍后再试"
        case .connectTimeout, .connectFailed: "连接超时。按住卡上的录音键，白灯闪烁后重试"
        case .unknownCard: "找不到这张录音卡，请重新搜索"
        case .disconnected: "连接已断开，连上后继续"
        case .requestTimeout: "录音卡没有响应，请重试"
        case .notPaired: "这张卡需要重新配对"
        case .pairVerifyFailed: "配对没有成功，请重试"
        case .cardBusyRecording: "录音中，结束后自动同步"
        case .cardBusy: "录音卡暂时无法传输。长按关机再开机后自动继续"
        case .transferFailed: "录音同步失败，稍后自动重试"
        case .unexpectedReply: "录音卡返回了无法识别的数据，请重试"
        case .bondStorageFailed: "无法保存配对信息，请重试"
        case .pairCancelled, .fileNotFound, .invalidArgument: nil
        }
    }
}

/// Text for the firmware warning (features.md X1); shown, never blocking.
public enum FirmwareText {
    public static let unverified = "此固件版本未经验证，如遇问题请反馈"
}
