import Foundation
import Library
import SyncEngine

// List and detail text for recordings (product-spec.md P05, P06, §7.2). Simplified Chinese only.

public enum RecordingText {
    /// "11月7日 14:02"; "时间未知" when the card file name carries no time.
    /// A title the user gave (features.md X6) or the AI made (G1) is shown as it is.
    public static func title(_ r: Recording, calendar: Calendar = .current) -> String {
        if r.hasCustomTitle || r.hasAITitle { return r.title }
        guard hasKnownTime(r) else { return "时间未知" }
        return dateTime(r.startedAt, calendar: calendar)
    }

    /// "11月7日 14:02", whatever the phone's region: the app is Chinese only.
    public static func dateTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%d月%d日 ", c.month ?? 0, c.day ?? 0) + time(date, calendar: calendar)
    }

    /// "14:02", 24-hour.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "14:02 · 23 分钟", plus "· 卡名" when several cards are paired, or "· 手机录音" / "· 导入"
    /// for a recording that did not come from a card (features.md D1c 来源标识).
    public static func subtitle(_ r: Recording, deviceName: String?, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if hasKnownTime(r) {
            parts.append(time(r.startedAt, calendar: calendar))
        }
        parts.append(duration(ms: r.durationMs))
        if let deviceName, !deviceName.isEmpty { parts.append(deviceName) }
        if r.source != .card { parts.append(sourceName(r.source)) }
        return parts.joined(separator: " · ")
    }

    /// Where a recording came from (features.md D1c), for the source filter and the detail page.
    public static func sourceName(_ source: Recording.Source) -> String {
        switch source {
        case .card: "录音卡"
        case .phone: "手机录音"
        case .import: "导入"
        case .realtime: "实时录音"
        }
    }

    /// "1 小时 5 分钟", "23 分钟", "45 秒".
    public static func duration(ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        let h = seconds / 3600, m = seconds % 3600 / 60
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时" }
        if m > 0 { return "\(m) 分钟" }
        return "\(seconds) 秒"
    }

    /// "23 分钟 5 秒" for the detail page.
    public static func longDuration(ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) 小时") }
        if m > 0 { parts.append("\(m) 分钟") }
        if s > 0 || parts.isEmpty { parts.append("\(s) 秒") }
        return parts.joined(separator: " ")
    }

    /// "00:12:34" for the recording timer and the player.
    public static func clock(seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// Card recordings whose file name could not be parsed were stamped with the sync time.
    private static func hasKnownTime(_ r: Recording) -> Bool {
        guard r.source == .card, let name = r.cardFileName else { return true }
        return SyncEngine.startDate(fileName: name) != nil
    }
}
