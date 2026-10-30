import Foundation

public struct LightingScheduleDecision: Equatable, Sendable {
    public let activeRule: LightingScheduleRule?
    public let nextBoundary: Date?
    public let matchingRuleIDs: [UUID]

    public init(
        activeRule: LightingScheduleRule?,
        nextBoundary: Date?,
        matchingRuleIDs: [UUID]
    ) {
        self.activeRule = activeRule
        self.nextBoundary = nextBoundary
        self.matchingRuleIDs = matchingRuleIDs
    }
}

public enum LightingScheduleEngine {
    private struct RuleInterval {
        let start: Date
        let end: Date

        func contains(_ date: Date) -> Bool {
            date >= start && date < end
        }
    }

    public static func evaluate(
        rules: [LightingScheduleRule],
        at now: Date,
        calendar: Calendar
    ) -> LightingScheduleDecision {
        let today = calendar.startOfDay(for: now)
        var matches: [LightingScheduleRule] = []
        var boundaries: [Date] = []

        for rule in rules where rule.isEnabled && !rule.weekdays.isEmpty {
            for offset in -1...8 {
                guard let day = calendar.date(
                    byAdding: .day,
                    value: offset,
                    to: today
                ),
                let interval = interval(
                    for: rule,
                    startingOn: day,
                    calendar: calendar
                ) else {
                    continue
                }

                if offset <= 0, interval.contains(now),
                   !matches.contains(where: { $0.id == rule.id }) {
                    matches.append(rule)
                }
                if interval.start > now {
                    boundaries.append(interval.start)
                }
                if interval.end > now {
                    boundaries.append(interval.end)
                }
            }
        }

        return LightingScheduleDecision(
            activeRule: matches.last,
            nextBoundary: boundaries.min(),
            matchingRuleIDs: matches.map(\.id)
        )
    }

    public static func hasConflicts(
        rules: [LightingScheduleRule]
    ) -> Bool {
        let minutesPerWeek = 7 * 1_440
        var occupied: [Int: UUID] = [:]

        for rule in rules where rule.isEnabled {
            let duration: Int
            if rule.start == rule.end {
                duration = 1_440
            } else if rule.end > rule.start {
                duration = rule.end.value - rule.start.value
            } else {
                duration = 1_440 - rule.start.value + rule.end.value
            }

            for weekday in rule.weekdays {
                let dayIndex = weekday.rawValue - 1
                let firstMinute = dayIndex * 1_440 + rule.start.value
                for offset in 0..<duration {
                    let minute = (firstMinute + offset) % minutesPerWeek
                    if let owner = occupied[minute], owner != rule.id {
                        return true
                    }
                    occupied[minute] = rule.id
                }
            }
        }
        return false
    }

    private static func interval(
        for rule: LightingScheduleRule,
        startingOn day: Date,
        calendar: Calendar
    ) -> RuleInterval? {
        let weekdayValue = calendar.component(.weekday, from: day)
        guard let weekday = Weekday(rawValue: weekdayValue),
              rule.weekdays.contains(weekday),
              let start = wallClockDate(
                  rule.start,
                  on: day,
                  calendar: calendar
              )
        else {
            return nil
        }

        let end: Date?
        if rule.start == rule.end {
            end = calendar.date(byAdding: .day, value: 1, to: start)
        } else if rule.end > rule.start {
            end = wallClockDate(
                rule.end,
                on: day,
                calendar: calendar
            )
        } else if let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: day)
        ) {
            end = wallClockDate(
                rule.end,
                on: nextDay,
                calendar: calendar
            )
        } else {
            end = nil
        }

        guard let end else {
            return nil
        }
        return RuleInterval(start: start, end: end)
    }

    private static func wallClockDate(
        _ minute: MinuteOfDay,
        on day: Date,
        calendar: Calendar
    ) -> Date? {
        calendar.date(
            bySettingHour: minute.value / 60,
            minute: minute.value % 60,
            second: 0,
            of: calendar.startOfDay(for: day),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
