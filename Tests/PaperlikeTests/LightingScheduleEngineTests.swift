import Foundation
import PaperlikeCore

func lightingScheduleEngineTests() -> [TestCase] {
    [
        TestCase("LightingScheduleEngineTests.weekdayRuleAndBoundary") {
            let rule = scheduleRule(
                name: "白天",
                weekdays: [.monday],
                start: (9, 0),
                end: (18, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: automationDate(2026, 8, 3, 10, 0),
                calendar: automationCalendar()
            )

            try expectEqual(decision.activeRule?.id, rule.id)
            try expectEqual(
                decision.nextBoundary,
                automationDate(2026, 8, 3, 18, 0)
            )
        },
        TestCase(
            "LightingScheduleEngineTests.crossMidnightUsesStartingWeekday"
        ) {
            let rule = scheduleRule(
                name: "夜间",
                weekdays: [.monday],
                start: (22, 0),
                end: (7, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: automationDate(2026, 8, 4, 1, 0),
                calendar: automationCalendar()
            )

            try expectEqual(decision.activeRule?.id, rule.id)
            try expectEqual(
                decision.nextBoundary,
                automationDate(2026, 8, 4, 7, 0)
            )
        },
        TestCase("LightingScheduleEngineTests.laterRuleWinsOverlap") {
            let first = scheduleRule(
                name: "第一条",
                weekdays: [.monday],
                start: (9, 0),
                end: (18, 0)
            )
            let second = scheduleRule(
                name: "第二条",
                weekdays: [.monday],
                start: (10, 0),
                end: (12, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [first, second],
                at: automationDate(2026, 8, 3, 11, 0),
                calendar: automationCalendar()
            )

            try expectEqual(decision.activeRule?.id, second.id)
            try expectEqual(
                decision.matchingRuleIDs,
                [first.id, second.id]
            )
            try expectEqual(
                decision.nextBoundary,
                automationDate(2026, 8, 3, 12, 0)
            )
        },
        TestCase("LightingScheduleEngineTests.equalTimesMeanFullDay") {
            let rule = scheduleRule(
                name: "全天",
                weekdays: [.monday],
                start: (0, 0),
                end: (0, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: automationDate(2026, 8, 3, 15, 0),
                calendar: automationCalendar()
            )

            try expectEqual(decision.activeRule?.id, rule.id)
            try expectEqual(
                decision.nextBoundary,
                automationDate(2026, 8, 4, 0, 0)
            )
        },
        TestCase(
            "LightingScheduleEngineTests.disabledRuleDoesNotMatch"
        ) {
            var rule = scheduleRule(
                name: "关闭",
                weekdays: [.monday],
                start: (9, 0),
                end: (18, 0)
            )
            rule.isEnabled = false

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: automationDate(2026, 8, 3, 10, 0),
                calendar: automationCalendar()
            )

            try expectEqual(decision.activeRule, nil)
            try expectEqual(decision.nextBoundary, nil)
            try expectEqual(decision.matchingRuleIDs, [])
        },
        TestCase("LightingScheduleEngineTests.findsNextWeeklyStart") {
            let rule = scheduleRule(
                name: "下周一",
                weekdays: [.monday],
                start: (9, 0),
                end: (18, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: automationDate(2026, 8, 4, 10, 0),
                calendar: automationCalendar()
            )

            try expectEqual(decision.activeRule, nil)
            try expectEqual(
                decision.nextBoundary,
                automationDate(2026, 8, 10, 9, 0)
            )
        },
        TestCase("LightingScheduleEngineTests.detectsRuleOverlap") {
            let first = scheduleRule(
                name: "白天",
                weekdays: [.monday],
                start: (9, 0),
                end: (18, 0)
            )
            let second = scheduleRule(
                name: "午间",
                weekdays: [.monday],
                start: (12, 0),
                end: (14, 0)
            )

            try expect(
                LightingScheduleEngine.hasConflicts(
                    rules: [first, second]
                ),
                "重叠规则应被识别"
            )
            try expect(
                !LightingScheduleEngine.hasConflicts(rules: [first]),
                "单条规则不应被误报为冲突"
            )
        },
        TestCase(
            "LightingScheduleEngineTests.usesWallClockAcrossSpringDST"
        ) {
            let calendar = losAngelesCalendar()
            let rule = scheduleRule(
                name: "春季",
                weekdays: [.sunday],
                start: (9, 0),
                end: (18, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: localDate(2026, 3, 8, 8, 0, calendar: calendar),
                calendar: calendar
            )

            try expectEqual(decision.activeRule, nil)
            try expectEqual(
                decision.nextBoundary,
                localDate(2026, 3, 8, 9, 0, calendar: calendar)
            )
        },
        TestCase(
            "LightingScheduleEngineTests.usesWallClockAcrossAutumnDST"
        ) {
            let calendar = losAngelesCalendar()
            let rule = scheduleRule(
                name: "秋季",
                weekdays: [.sunday],
                start: (9, 0),
                end: (18, 0)
            )

            let decision = LightingScheduleEngine.evaluate(
                rules: [rule],
                at: localDate(2026, 11, 1, 8, 30, calendar: calendar),
                calendar: calendar
            )

            try expectEqual(decision.activeRule, nil)
            try expectEqual(
                decision.nextBoundary,
                localDate(2026, 11, 1, 9, 0, calendar: calendar)
            )
        }
    ]
}

private func automationCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func losAngelesCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar
) -> Date {
    calendar.date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

private func automationDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int
) -> Date {
    automationCalendar().date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

private func scheduleRule(
    name: String,
    weekdays: Set<Weekday>,
    start: (Int, Int),
    end: (Int, Int)
) -> LightingScheduleRule {
    LightingScheduleRule(
        name: name,
        weekdays: weekdays,
        start: MinuteOfDay(hour: start.0, minute: start.1),
        end: MinuteOfDay(hour: end.0, minute: end.1),
        configuration: LightingConfiguration(
            frontLightMode: 3,
            brightness: 50,
            temperature: 50
        )
    )
}
