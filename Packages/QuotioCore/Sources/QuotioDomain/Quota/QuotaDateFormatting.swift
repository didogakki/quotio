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

    /// Parses `value` as ISO-8601 (with or without fractional seconds), the same
    /// tolerant parsing `absoluteJST(_:String)` uses internally — exposed so callers
    /// that need the `Date` itself (not just its JST label) share one parsing rule
    /// rather than re-implementing it.
    public static func parseISO8601(_ value: String) -> Date? {
        parseISO8601Date(value)
    }

    /// Compact "3h32m"/"2d5h"/"12m" countdown to `date` — the same style already shown
    /// next to each quota meter in the menu bar. Never negative: a `date` at or before
    /// `now` reads as "0m" rather than producing a nonsensical countdown, since callers
    /// are expected to only pass a still-upcoming `date`.
    public static func relativeCompact(to date: Date, from now: Date = Date()) -> String {
        let totalMinutes = max(0, Int(date.timeIntervalSince(now)) / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}
