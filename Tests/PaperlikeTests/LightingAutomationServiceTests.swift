import Foundation
import PaperlikeCore

func lightingAutomationServiceTests() -> [TestCase] {
    [
        TestCase("LightingAutomationServiceTests.suspensionPreservesOriginalLighting") {
            let clock = LockedDateProvider(serviceDate(2026, 8, 3, 10, 0))
            let recorder = LightingApplyRecorder()
            let settings = serviceFixture(recorder: recorder).settings
            let original = LightingConfiguration(frontLightMode: 1, brightness: 12, temperature: 24)
            let service = LightingAutomationService(now: { clock.get() }, calendar: { serviceCalendar() },
                sleepUntil: { _ in try await Task.sleep(for: .seconds(3_600)) },
                currentConfig: { await recorder.snapshot().last ?? original },
                apply: { await recorder.append($0) })
            await service.update(settings: settings, isConnected: true, applyImmediately: true)
            await service.setSuspended(true)
            await service.setSuspended(false)
            await service.setSuspended(true)
            clock.set(serviceDate(2026, 8, 3, 18, 1))
            await service.setSuspended(false)
            try expectEqual(await recorder.snapshot(), [settings.rules[0].configuration, settings.rules[0].configuration, original])
            await service.stop()
        },
        TestCase("LightingAutomationServiceTests.timedPauseSurvivesReconnectAndResumes") {
            let clock = LockedDateProvider(serviceDate(2026, 8, 3, 10, 0))
            let recorder = LightingApplyRecorder()
            let settings = serviceFixture(recorder: recorder).settings
            let service = LightingAutomationService(now: { clock.get() }, calendar: { serviceCalendar() },
                sleepUntil: { _ in try await Task.sleep(for: .seconds(3_600)) }, apply: { await recorder.append($0) })
            await service.update(settings: settings, isConnected: true, applyImmediately: true)
            await service.pause(until: serviceDate(2026, 8, 3, 10, 30))
            await service.connectionChanged(isConnected: false)
            await service.connectionChanged(isConnected: true)
            try expectEqual(await recorder.snapshot().count, 1)
            clock.set(serviceDate(2026, 8, 3, 10, 31))
            await service.refreshNow()
            try expectEqual(await recorder.snapshot().count, 2)
            await service.setSuspended(true)
            await service.refreshNow(forceApply: true)
            try expectEqual(await recorder.snapshot().count, 2)
            await service.setSuspended(false)
            try expectEqual(await recorder.snapshot().count, 3)
            await service.stop()
        },
        TestCase("LightingAutomationServiceTests.boundaryDoesNotCancelItsOwnApply") {
            let clock = LockedDateProvider(serviceDate(2026, 8, 3, 10, 0))
            let recorder = LightingApplyRecorder()
            let settings = serviceFixture(recorder: recorder).settings
            let boundary = serviceDate(2026, 8, 3, 18, 0)
            let original = LightingConfiguration(frontLightMode: 1, brightness: 12, temperature: 24)
            let service = LightingAutomationService(
                now: { clock.get() }, calendar: { serviceCalendar() },
                sleepUntil: { date in
                    if date == boundary { clock.set(date) }
                    else { try await Task.sleep(for: .seconds(3_600)) }
                },
                currentConfig: { original },
                apply: {
                    try Task.checkCancellation()
                    await recorder.append($0)
                }
            )
            await service.update(settings: settings, isConnected: true, applyImmediately: true)
            for _ in 0..<200 {
                if await recorder.snapshot().count == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await service.stop()
            try expectEqual(await recorder.snapshot(), [settings.rules[0].configuration, original])
        },
        TestCase("LightingAutomationServiceTests.failureClearsAfterSuccessfulRetry") {
            let recorder = FailingOnceLightingRecorder()
            let rule = serviceFixture(recorder: LightingApplyRecorder()).settings.rules[0]
            let service = LightingAutomationService(
                now: { serviceDate(2026, 8, 3, 10, 0) },
                calendar: { serviceCalendar() },
                sleepUntil: { _ in try await Task.sleep(for: .seconds(3_600)) },
                apply: { try await recorder.apply($0) }
            )
            await service.update(settings: LightingAutomationSettings(isEnabled: true, rules: [rule]),
                                 isConnected: true, applyImmediately: true)
            let failed = await service.currentStatus()
            try expect(!failed.isApplied && failed.failureMessage != nil, "failed writes are not active success")
            await service.refreshNow()
            let succeeded = await service.currentStatus()
            try expect(succeeded.isApplied && succeeded.failureMessage == nil, "success clears the old failure")
            await service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.appliesCurrentRuleWhenConnected"
        ) {
            let recorder = LightingApplyRecorder()
            let fixture = serviceFixture(recorder: recorder)

            await fixture.service.update(
                settings: fixture.settings,
                isConnected: true,
                applyImmediately: true
            )

            try expectEqual(
                await recorder.snapshot(),
                [fixture.settings.rules[0].configuration]
            )
            await fixture.service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.waitsForReconnect"
        ) {
            let recorder = LightingApplyRecorder()
            let fixture = serviceFixture(recorder: recorder)

            await fixture.service.update(
                settings: fixture.settings,
                isConnected: false,
                applyImmediately: true
            )
            try expectEqual(await recorder.snapshot(), [])

            await fixture.service.connectionChanged(isConnected: true)

            try expectEqual(
                await recorder.snapshot(),
                [fixture.settings.rules[0].configuration]
            )
            await fixture.service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.manualOverrideDefersReapply"
        ) {
            let recorder = LightingApplyRecorder()
            let fixture = serviceFixture(recorder: recorder)

            await fixture.service.update(
                settings: fixture.settings,
                isConnected: true,
                applyImmediately: true
            )
            await fixture.service.noteManualOverride()
            await fixture.service.refreshNow()

            try expectEqual(
                await recorder.snapshot(),
                [fixture.settings.rules[0].configuration]
            )
            let status = await fixture.service.currentStatus()
            try expect(status.isPaused, "手动调整后应暂停到下一边界")
            await fixture.service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.disabledAutomationDoesNotApply"
        ) {
            let recorder = LightingApplyRecorder()
            let fixture = serviceFixture(recorder: recorder)
            var disabled = fixture.settings
            disabled.isEnabled = false

            await fixture.service.update(
                settings: disabled,
                isConnected: true,
                applyImmediately: true
            )

            try expectEqual(await recorder.snapshot(), [])
            try expectEqual(
                await fixture.service.currentStatus().activeRule,
                nil
            )
            await fixture.service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.publishesScheduleStatus"
        ) {
            let recorder = LightingApplyRecorder()
            let fixture = serviceFixture(recorder: recorder)
            var iterator = fixture.service.events.makeAsyncIterator()
            _ = await iterator.next()

            await fixture.service.update(
                settings: fixture.settings,
                isConnected: true,
                applyImmediately: true
            )

            let status = await iterator.next()
            try expectEqual(
                status?.activeRule?.id,
                fixture.settings.rules[0].id
            )
            try expectEqual(
                status?.nextBoundary,
                serviceDate(2026, 8, 3, 18, 0)
            )
            await fixture.service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.resumesAtBoundaryWhenRuleStaysSame"
        ) {
            let clock = LockedDateProvider(
                serviceDate(2026, 8, 3, 9, 30)
            )
            let recorder = LightingApplyRecorder()
            let lowerPriority = LightingScheduleRule(
                name: "短时段",
                weekdays: [.monday],
                start: MinuteOfDay(hour: 10, minute: 0),
                end: MinuteOfDay(hour: 11, minute: 0),
                configuration: LightingConfiguration(
                    frontLightMode: 1,
                    brightness: 20,
                    temperature: 20
                )
            )
            let winningRule = LightingScheduleRule(
                name: "主规则",
                weekdays: [.monday],
                start: MinuteOfDay(hour: 9, minute: 0),
                end: MinuteOfDay(hour: 18, minute: 0),
                configuration: LightingConfiguration(
                    frontLightMode: 3,
                    brightness: 60,
                    temperature: 40
                )
            )
            let service = LightingAutomationService(
                now: { clock.get() },
                calendar: { serviceCalendar() },
                sleepUntil: { _ in
                    try await Task.sleep(for: .seconds(3_600))
                },
                apply: { await recorder.append($0) }
            )
            let settings = LightingAutomationSettings(
                isEnabled: true,
                rules: [lowerPriority, winningRule]
            )
            await service.update(
                settings: settings,
                isConnected: true,
                applyImmediately: true
            )
            await service.noteManualOverride()

            clock.set(serviceDate(2026, 8, 3, 10, 0))
            await service.refreshNow()

            try expectEqual(
                await recorder.snapshot(),
                [
                    winningRule.configuration,
                    winningRule.configuration
                ]
            )
            await service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.forceRefreshReappliesCurrentRule"
        ) {
            let recorder = LightingApplyRecorder()
            let fixture = serviceFixture(recorder: recorder)
            await fixture.service.update(
                settings: fixture.settings,
                isConnected: true,
                applyImmediately: true
            )

            await fixture.service.refreshNow(forceApply: true)

            try expectEqual(
                await recorder.snapshot(),
                [
                    fixture.settings.rules[0].configuration,
                    fixture.settings.rules[0].configuration
                ]
            )
            await fixture.service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.staleApplyCannotOverwriteNewSettings"
        ) {
            let blocker = BlockingLightingApplyRecorder()
            var started = blocker.started.makeAsyncIterator()
            let now = serviceDate(2026, 8, 3, 10, 0)
            let service = LightingAutomationService(
                now: { now },
                calendar: { serviceCalendar() },
                sleepUntil: { _ in
                    try await Task.sleep(for: .seconds(3_600))
                },
                apply: { await blocker.apply($0) }
            )
            let ruleID = UUID()
            let oldRule = LightingScheduleRule(
                id: ruleID,
                name: "旧配置",
                weekdays: [.monday],
                start: MinuteOfDay(hour: 9, minute: 0),
                end: MinuteOfDay(hour: 18, minute: 0),
                configuration: LightingConfiguration(
                    frontLightMode: 3,
                    brightness: 30,
                    temperature: 30
                )
            )
            var newRule = oldRule
            newRule.name = "新配置"
            newRule.configuration = LightingConfiguration(
                frontLightMode: 3,
                brightness: 70,
                temperature: 70
            )

            let firstUpdate = Task {
                await service.update(
                    settings: LightingAutomationSettings(
                        isEnabled: true,
                        rules: [oldRule]
                    ),
                    isConnected: true,
                    applyImmediately: true
                )
            }
            _ = await started.next()
            let pending = await service.currentStatus()
            try expect(!pending.isApplied, "in-flight writes are not reported as successful")
            await service.refreshNow()
            try expectEqual(await blocker.snapshot().count, 1)

            await service.update(
                settings: LightingAutomationSettings(
                    isEnabled: true,
                    rules: [newRule]
                ),
                isConnected: true,
                applyImmediately: true
            )
            await blocker.releaseFirst()
            await firstUpdate.value

            await service.refreshNow()

            try expectEqual(
                await blocker.snapshot(),
                [oldRule.configuration, newRule.configuration]
            )
            await service.stop()
        },
        TestCase(
            "LightingAutomationServiceTests.stopWinsAgainstInFlightApply"
        ) {
            let blocker = BlockingLightingApplyRecorder()
            var started = blocker.started.makeAsyncIterator()
            let now = serviceDate(2026, 8, 3, 10, 0)
            let service = LightingAutomationService(
                now: { now },
                calendar: { serviceCalendar() },
                sleepUntil: { _ in
                    try await Task.sleep(for: .seconds(3_600))
                },
                apply: { await blocker.apply($0) }
            )
            let rule = LightingScheduleRule(
                name: "停止测试",
                weekdays: [.monday],
                start: MinuteOfDay(hour: 9, minute: 0),
                end: MinuteOfDay(hour: 18, minute: 0),
                configuration: LightingConfiguration(
                    frontLightMode: 3,
                    brightness: 50,
                    temperature: 50
                )
            )
            let update = Task {
                await service.update(
                    settings: LightingAutomationSettings(
                        isEnabled: true,
                        rules: [rule]
                    ),
                    isConnected: true,
                    applyImmediately: true
                )
            }
            _ = await started.next()

            await service.stop()
            await blocker.releaseFirst()
            await update.value

            try expectEqual(
                await service.currentStatus(),
                .inactive
            )
            try expectEqual(await blocker.snapshot().count, 1)
        },
        TestCase(
            "LightingAutomationServiceTests.restoresPreAutomationConfigWhenRuleEnds"
        ) {
            let clock = LockedDateProvider(serviceDate(2026, 8, 3, 10, 0))
            let recorder = LightingApplyRecorder()

            let manualConfig = LightingConfiguration(
                frontLightMode: 1,
                brightness: 15,
                temperature: 25
            )

            let rule = LightingScheduleRule(
                name: "限时规则",
                weekdays: [.monday],
                start: MinuteOfDay(hour: 9, minute: 0),
                end: MinuteOfDay(hour: 11, minute: 0),
                configuration: LightingConfiguration(
                    frontLightMode: 3,
                    brightness: 70,
                    temperature: 50
                )
            )

            let service = LightingAutomationService(
                now: { clock.get() },
                calendar: { serviceCalendar() },
                sleepUntil: { _ in
                    try await Task.sleep(for: .seconds(3_600))
                },
                currentConfig: { manualConfig },
                apply: { await recorder.append($0) }
            )

            let settings = LightingAutomationSettings(
                isEnabled: true,
                rules: [rule]
            )

            // 1. Enter automation rule (at 10:00, which is during the rule)
            await service.update(
                settings: settings,
                isConnected: true,
                applyImmediately: true
            )

            try expectEqual(
                await recorder.snapshot(),
                [rule.configuration]
            )

            // 2. Advance time past the end of the rule (at 11:01, rule ends)
            clock.set(serviceDate(2026, 8, 3, 11, 1))
            await service.refreshNow()

            // Should apply the original manual configuration to restore
            try expectEqual(
                await recorder.snapshot(),
                [rule.configuration, manualConfig]
            )

            await service.stop()
        }
    ]
}

private actor LightingApplyRecorder {
    private var values: [LightingConfiguration] = []

    func append(_ value: LightingConfiguration) {
        values.append(value)
    }

    func snapshot() -> [LightingConfiguration] {
        values
    }
}

private actor FailingOnceLightingRecorder {
    private var attempts = 0
    func apply(_ value: LightingConfiguration) throws {
        attempts += 1
        if attempts == 1 { throw PaperlikeDeviceError.busy }
    }
}

private final class LockedDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func get() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor BlockingLightingApplyRecorder {
    nonisolated let started: AsyncStream<LightingConfiguration>
    private nonisolated let startedContinuation:
        AsyncStream<LightingConfiguration>.Continuation
    private var values: [LightingConfiguration] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    init() {
        let pair = AsyncStream<LightingConfiguration>.makeStream()
        started = pair.stream
        startedContinuation = pair.continuation
    }

    func apply(_ value: LightingConfiguration) async {
        values.append(value)
        if values.count == 1 {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
                startedContinuation.yield(value)
            }
        } else {
            startedContinuation.yield(value)
        }
    }

    func releaseFirst() {
        let continuation = firstRelease
        firstRelease = nil
        continuation?.resume()
    }

    func snapshot() -> [LightingConfiguration] {
        values
    }
}

private struct LightingServiceFixture {
    let service: LightingAutomationService
    let settings: LightingAutomationSettings
}

private func serviceFixture(
    recorder: LightingApplyRecorder
) -> LightingServiceFixture {
    let now = serviceDate(2026, 8, 3, 10, 0)
    let configuration = LightingConfiguration(
        frontLightMode: 3,
        brightness: 62,
        temperature: 44
    )
    let rule = LightingScheduleRule(
        name: "工作日白天",
        weekdays: [.monday],
        start: MinuteOfDay(hour: 9, minute: 0),
        end: MinuteOfDay(hour: 18, minute: 0),
        configuration: configuration
    )
    let service = LightingAutomationService(
        now: { now },
        calendar: { serviceCalendar() },
        sleepUntil: { _ in
            try await Task.sleep(for: .seconds(3_600))
        },
        apply: { configuration in
            await recorder.append(configuration)
        }
    )
    return LightingServiceFixture(
        service: service,
        settings: LightingAutomationSettings(
            isEnabled: true,
            rules: [rule]
        )
    )
}

private func serviceCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func serviceDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int
) -> Date {
    serviceCalendar().date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}
