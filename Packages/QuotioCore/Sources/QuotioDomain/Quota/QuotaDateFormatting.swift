import Foundation

/// Fixed, locale/timezone-independent absolute datetime label for quota resets and
/// token expiries — deliberately always `Asia/Tokyo` + `en_US_POSIX`, unlike the
/// existing relative "Nd Nh" countdowns, which stay in the device's own locale/timezone.
/// Reset countdowns and this absolute label are two different, separately-computed
/// views of the same `resetTime` string — this type never touches "last refreshed"/
/// "last updated" timestamps, which are a distinct concept.
public enum QuotaDateFormatting {
    /// `nil` when `value` is empty or fails to parse as ISO-8601 — never a fabricated
    /// date.
    public static func absoluteJST(_ value: String) -> String? {
        guard !value.isEmpty, let date = parseISO8601Date(value) else { return nil }
        return absoluteJST(date)
    }

    /// `yyyy-MM-dd HH:mm JST`, always 24-hour, always `Asia/Tokyo` — matches across
    /// every caller (menu bar reset countdown, token-expiry card, Codex reset-credit
    /// row) regardless of the user's own locale/timezone/12-vs-24-hour setting.
    public static func absoluteJST(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) JST"
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}
