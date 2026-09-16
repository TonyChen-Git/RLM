import Foundation

/// A bounded five-field cron expression: minute, hour, day-of-month, month,
/// day-of-week. It supports `*`, lists, ranges and `/step`. Sunday is 0 or 7.
/// Evaluation is minute-granular and intentionally has no shell command field.
struct AutomationCronSchedule: Codable, Equatable, Sendable {
    static let maximumExpressionBytes = 512
    static let maximumSearchMinutes = 366 * 24 * 60

    var expression: String
    var timeZoneIdentifier: String

    init(expression: String, timeZoneIdentifier: String = "UTC") {
        self.expression = expression
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    func validate() throws {
        _ = try parsed()
    }

    func matches(_ date: Date) throws -> Bool {
        let parsed = try parsed()
        return parsed.matches(date)
    }

    /// Returns at most `limit` occurrences. A one-year scan bound keeps corrupt
    /// or extremely old scheduler cursors from causing unbounded recovery work.
    /// When a cursor is older than that, `newestFirst` still finds the most
    /// recent annual occurrence suitable for skip/run-once recovery.
    func occurrences(
        after: Date,
        through: Date,
        limit: Int,
        newestFirst: Bool
    ) throws -> [Date] {
        guard limit > 0, through > after else { return [] }
        let parsed = try parsed()
        let minute: TimeInterval = 60
        let lowerMinute = floor(after.timeIntervalSince1970 / minute) * minute
        let upperMinute = floor(through.timeIntervalSince1970 / minute) * minute
        guard upperMinute > lowerMinute else { return [] }

        var matches: [Date] = []
        matches.reserveCapacity(min(limit, AutomationLimits.maximumCatchUpRuns))
        let scanLimit = Self.maximumSearchMinutes

        if newestFirst {
            var candidate = Date(timeIntervalSince1970: upperMinute)
            var scanned = 0
            while candidate.timeIntervalSince1970 > lowerMinute,
                  scanned < scanLimit,
                  matches.count < limit {
                if parsed.matches(candidate) { matches.append(candidate) }
                candidate = candidate.addingTimeInterval(-minute)
                scanned += 1
            }
            return matches.sorted()
        }

        // For catch-up, retain the newest bounded year instead of spending time
        // walking an arbitrarily old cursor.
        let boundedLower = max(lowerMinute, upperMinute - Double(scanLimit) * minute)
        var candidate = Date(timeIntervalSince1970: boundedLower + minute)
        var scanned = 0
        while candidate.timeIntervalSince1970 <= upperMinute,
              scanned < scanLimit,
              matches.count < limit {
            if candidate > after, parsed.matches(candidate) { matches.append(candidate) }
            candidate = candidate.addingTimeInterval(minute)
            scanned += 1
        }
        return matches
    }

    private func parsed() throws -> ParsedCron {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumExpressionBytes else {
            throw AutomationError.invalidSchedule("cron expression 為空或過長。")
        }
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AutomationError.invalidSchedule("未知時區：\(timeZoneIdentifier)。")
        }
        let fields = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else {
            throw AutomationError.invalidSchedule("cron 必須正好有五個欄位。")
        }
        let minute = try CronField(fields[0], minimum: 0, maximum: 59)
        let hour = try CronField(fields[1], minimum: 0, maximum: 23)
        let dayOfMonth = try CronField(fields[2], minimum: 1, maximum: 31)
        let month = try CronField(fields[3], minimum: 1, maximum: 12)
        let weekday = try CronField(
            fields[4],
            minimum: 0,
            maximum: 7,
            normalization: { $0 == 7 ? 0 : $0 }
        )
        return ParsedCron(
            minute: minute,
            hour: hour,
            dayOfMonth: dayOfMonth,
            month: month,
            weekday: weekday,
            timeZone: zone
        )
    }
}

private struct ParsedCron {
    var minute: CronField
    var hour: CronField
    var dayOfMonth: CronField
    var month: CronField
    var weekday: CronField
    var timeZone: TimeZone

    func matches(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: date
        )
        guard let minuteValue = components.minute,
              let hourValue = components.hour,
              let dayValue = components.day,
              let monthValue = components.month,
              let calendarWeekday = components.weekday,
              minute.contains(minuteValue),
              hour.contains(hourValue),
              month.contains(monthValue) else { return false }

        let cronWeekday = calendarWeekday - 1
        let dayMatches = dayOfMonth.contains(dayValue)
        let weekdayMatches = weekday.contains(cronWeekday)
        if !dayOfMonth.isWildcard && !weekday.isWildcard {
            return dayMatches || weekdayMatches
        }
        return dayMatches && weekdayMatches
    }
}

private struct CronField {
    let values: Set<Int>
    let isWildcard: Bool

    init(
        _ source: String,
        minimum: Int,
        maximum: Int,
        normalization: (Int) -> Int = { $0 }
    ) throws {
        guard !source.isEmpty, source.utf8.count <= 128 else {
            throw AutomationError.invalidSchedule("cron 欄位為空或過長。")
        }
        var parsed = Set<Int>()
        let items = source.split(separator: ",", omittingEmptySubsequences: false)
        guard !items.isEmpty, items.count <= maximum - minimum + 1 else {
            throw AutomationError.invalidSchedule("cron list 超過安全上限。")
        }

        for itemSlice in items {
            let item = String(itemSlice)
            let stepParts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(stepParts.count) else {
                throw AutomationError.invalidSchedule("cron step 格式錯誤。")
            }
            let step: Int
            if stepParts.count == 2 {
                guard let decoded = Int(stepParts[1]), decoded > 0,
                      decoded <= maximum - minimum + 1 else {
                    throw AutomationError.invalidSchedule("cron step 超出範圍。")
                }
                step = decoded
            } else {
                step = 1
            }

            let base = String(stepParts[0])
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = minimum
                upper = maximum
            } else {
                let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(rangeParts.count),
                      let first = Int(rangeParts[0]) else {
                    throw AutomationError.invalidSchedule("cron value 格式錯誤。")
                }
                lower = first
                if rangeParts.count == 2 {
                    guard let last = Int(rangeParts[1]) else {
                        throw AutomationError.invalidSchedule("cron range 格式錯誤。")
                    }
                    upper = last
                } else if stepParts.count == 2 {
                    upper = maximum
                } else {
                    upper = first
                }
            }
            guard lower >= minimum, upper <= maximum, lower <= upper else {
                throw AutomationError.invalidSchedule("cron value 超出 \(minimum)...\(maximum)。")
            }
            var value = lower
            while value <= upper {
                parsed.insert(normalization(value))
                guard value <= Int.max - step else { break }
                value += step
            }
        }
        guard !parsed.isEmpty else {
            throw AutomationError.invalidSchedule("cron 欄位沒有可執行值。")
        }
        values = parsed
        isWildcard = source == "*"
    }

    func contains(_ value: Int) -> Bool { values.contains(value) }
}
