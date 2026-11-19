import Foundation
import Library

/// Recordings of one calendar day for the list (design-spec.md §3, #89): the day's title and
/// how many recordings and how long they are together.
public struct RecordingDay: Identifiable, Equatable, Sendable {
    /// Start of the day.
    public let id: Date
    /// "今天", "昨天", "11月7日", or "2025年11月7日" in another year.
    public let title: String
    public var recordings: [Recording]

    public var totalMs: Int { recordings.reduce(0) { $0 + $1.durationMs } }

    /// "3 条 · 1 小时 5 分钟" beside the day's title.
    public var countText: String {
        "\(recordings.count) 条 · \(RecordingText.duration(ms: totalMs))"
    }

    /// Groups recordings by the day they started, keeping their order: consecutive recordings
    /// of the same day share a group, so a newest-first list gives the newest day first.
    public static func group(_ recordings: [Recording], calendar: Calendar = .current,
                             now: Date = Date()) -> [RecordingDay] {
        var days: [RecordingDay] = []
        for recording in recordings {
            let day = calendar.startOfDay(for: recording.startedAt)
            if let last = days.indices.last, days[last].id == day {
                days[last].recordings.append(recording)
            } else {
                days.append(RecordingDay(id: day, title: title(day, calendar: calendar, now: now),
                                         recordings: [recording]))
            }
        }
        return days
    }

    static func title(_ day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "昨天" }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let monthDay = "\(c.month ?? 0)月\(c.day ?? 0)日"
        return c.year == calendar.component(.year, from: now) ? monthDay : "\(c.year ?? 0)年" + monthDay
    }
}
