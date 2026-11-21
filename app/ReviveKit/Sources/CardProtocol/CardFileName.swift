import Foundation

extension CardFile {
    /// Card file names are `YYYYMMDDHHmmss.opus` in the card's clock, which the app sets to
    /// the phone's local time on every connect (`0x87`). Parsed in the phone's current zone on
    /// purpose (#59): a file recorded after one connect and synced after the phone changed zone
    /// is off by the difference. The card's time carries no zone (prd.md §5.2).
    public static func startDate(fileName: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(fileName.prefix(14)))
    }
}
