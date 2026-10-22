import Foundation

/// Provider-reported accounting for a complete durable turn, never a session meter.
public struct TurnTokenUsage: Codable, Sendable, Equatable {
    public let totalTokens: Int

    public init?(totalTokens: Int) {
        guard totalTokens >= 0 else { return nil }
        self.totalTokens = totalTokens
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let count = try values.decode(Int.self, forKey: .totalTokens)
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .totalTokens, in: values, debugDescription: "Negative token count")
        }
        totalTokens = count
    }
}

/// Fixed 24-hour clocks in the device's local time zone, independent of locale's hour cycle.
public enum TurnResponseClock {
    public static func text(at date: Date, now: Date = .now, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }
}
