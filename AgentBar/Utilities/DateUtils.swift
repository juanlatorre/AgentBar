import Foundation

enum DateUtils {
    static let fiveHourInterval: TimeInterval = 5 * 3600
    static let weeklyInterval: TimeInterval = 7 * 24 * 3600
    static let monthlyInterval: TimeInterval = 30 * 24 * 3600

    static func fiveHourWindowStart(relativeTo now: Date = Date()) -> Date {
        now.addingTimeInterval(-fiveHourInterval)
    }

    static func weeklyWindowStart(relativeTo now: Date = Date()) -> Date {
        now.addingTimeInterval(-weeklyInterval)
    }

    static func monthlyWindowStart(relativeTo now: Date = Date()) -> Date {
        now.addingTimeInterval(-monthlyInterval)
    }

    static func parseISO8601(_ string: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: string) { return date }

        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        if let date = noFrac.date(from: string) { return date }

        // Handles timestamps like "2025-06-05T17:12:37.153082Z" from ~/.claude.json
        let microsecondFormatter = DateFormatter()
        microsecondFormatter.locale = Locale(identifier: "en_US_POSIX")
        microsecondFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        microsecondFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return microsecondFormatter.date(from: string)
    }
}
