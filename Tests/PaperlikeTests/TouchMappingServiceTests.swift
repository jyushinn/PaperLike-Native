import CoreGraphics
import Combine
import Foundation
import PaperlikeTouch

func touchMappingServiceTests() -> [TestCase] {
    [
        TestCase("TouchMappingService.inertiaKeepsTheOriginalScrollTarget") {
            try await MainActor.run {
                let harness = makeMappingHarness(initialSettings: TouchMappingSettings(isSingleFingerScrollEnabled: true, isCursorHiddenOnTouch: false))
                harness.service.start()
                defer { harness.service.shutdown() }
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048), timestamp: 1)
                harness.input.emitReport(validTouchReport(x: 1_200, y: 2_048), timestamp: 1.02)
                var release = validTouchReport(x: 1_200, y: 2_048)
                release[1] = 0
                release[83] = 0
                harness.input.emitReport(release, timestamp: 1.03)
                let countBeforeInertia = harness.poster.events.count
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
                try expect(harness.poster.events.count > countBeforeInertia, "inertia must emit after release")
                for event in harness.poster.events {
                    if case let .scroll(_, _, target) = event {
                        try expectEqual(target, CGPoint(x: 480, y: 540))
                    }
                }
            }
        },
        TestCase("TouchMappingService.restoreDefaultsUpdatesCursorRuntime") {
            try await MainActor.run {
                let cursor = TouchCursorManager()
                let harness = makeMappingHarness(initialSettings: TouchMappingSettings(isCursorHiddenOnTouch: false), cursorManager: cursor)
                try expectEqual(cursor.isEnabled, false)
                harness.service.restoreDefaults()
                try expectEqual(cursor.isEnabled, harness.service.settings.isCursorHiddenOnTouch)
            }
        },
        TestCase("TouchMappingService.validReportAfterMalformedReportRecoversUsingCachedTrust") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                let checks = harness.accessibility.checkCount
                harness.input.emitReport([1, 2, 3])
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))
                try expectEqual(harness.poster.events, [.move(CGPoint(x: 480, y: 540))])
                try expectEqual(harness.service.status, .ready)
                try expectEqual(harness.accessibility.checkCount, checks)
            }
        },
        TestCase("TouchMappingService.visibleDiagnosticsPublishFinalReleaseWithoutAnotherReport") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                var snapshots: [TouchDiagnosticsSnapshot] = []
                let subscription = harness.service.touchDiagnosticsSubject.sink { snapshots.append($0) }
                defer { subscription.cancel(); harness.service.setDiagnosticsEnabled(false) }
                harness.service.setDiagnosticsEnabled(true)
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))
                var release = validTouchReport(x: 1_024, y: 2_048)
                release[1] = 0
                release[83] = 0
                harness.input.emitReport(release, timestamp: 1.1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.11))
                try expect(snapshots.count >= 2, "sampling publishes after the final HID report")
                try expectEqual(snapshots.last?.contactCount, 0)
            }
        },
        TestCase("TouchMappingService.visibleDiagnosticsPublishAtMostTenHzAndStopWhenHidden") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                var updates = 0
                let subscription = harness.service.touchDiagnosticsSubject.sink { _ in updates += 1 }
                defer { subscription.cancel() }
                harness.service.setDiagnosticsEnabled(true)
                try expectEqual(updates, 1)
                for x in 1_000...1_099 { harness.input.emitReport(validTouchReport(x: UInt16(x), y: 2_048)) }
                try expectEqual(updates, 1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.11))
                harness.input.emitReport(validTouchReport(x: 1_200, y: 2_048))
                try expectEqual(updates, 2)
                try expectEqual(harness.service.touchDiagnostics.centroid, CGPoint(x: 562.5, y: 540))
                harness.service.setDiagnosticsEnabled(false)
                harness.input.emitReport(validTouchReport(x: 1_300, y: 2_048))
                try expectEqual(updates, 2)
                try expectEqual(harness.service.touchDiagnostics.centroid, CGPoint(x: 609.375, y: 540))
                try expect(harness.poster.events.count > 50, "mouse output remains at report rate")
            }
        },
        TestCase("TouchMappingService.reportsReuseAccessibilityCacheUntilRefresh") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                let checks = harness.accessibility.checkCount
                for x in 1_000...1_099 {
                    harness.input.emitReport(validTouchReport(x: UInt16(x), y: 2_048))
                }
                try expectEqual(harness.accessibility.checkCount, checks)
                harness.accessibility.isTrusted = false
                harness.service.refresh()
                try expectEqual(harness.service.status, .accessibilityRequired)
                try expectEqual(harness.poster.events.last, .leftUp(CGPoint(x: CGFloat(1_099) / 4_096 * 1_920, y: 540)))
                let eventCount = harness.poster.events.count
                harness.input.emitReport(validTouchReport(x: 1_200, y: 2_048))
                try expectEqual(harness.poster.events.count, eventCount)
            }
        },
        TestCase("TouchMappingService.hiddenDiagnosticsDoNotPublishButRemainReadable") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                var updates = 0
                let subscription = harness.service.touchDiagnosticsSubject.sink { _ in updates += 1 }
                defer { subscription.cancel() }
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))
                try expectEqual(updates, 0)
                try expectEqual(harness.service.touchDiagnostics.contactCount, 1)
                try expect(harness.service.touchDiagnostics.contactsDescription.contains("1024"), "latest diagnostic coordinates remain readable")
            }
        },
        TestCase("TouchMappingService.normalReportsDoNotInvalidateUI") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                var updates = 0
                let subscription = harness.service.objectWillChange.sink { updates += 1 }
                defer { subscription.cancel() }
                for x in 1_000...1_099 {
                    harness.input.emitReport(validTouchReport(x: UInt16(x), y: 2_048))
                }
                try expectEqual(updates, 0)
                try expect(!harness.poster.events.isEmpty, "input still reaches the mouse")
            }
        },
        TestCase("TouchMappingService.disabledNeverPostsInput") {
            try await MainActor.run {
                let harness = makeMappingHarness(isEnabled: false)
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.poster.events, [])
            }
        },
        TestCase("TouchMappingService.untrustedNeverPostsInput") {
            try await MainActor.run {
                let harness = makeMappingHarness(trusted: false)
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.poster.events, [])
                try expectEqual(harness.accessibility.promptRequestCount, 0)
            }
        },
        TestCase("TouchMappingService.absentDeviceNeverPostsInput") {
            try await MainActor.run {
                let harness = makeMappingHarness(connected: false)
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.poster.events, [])
            }
        },
        TestCase("TouchMappingService.missingTargetDisplayNeverPostsInput") {
            try await MainActor.run {
                let harness = makeMappingHarness(displays: [])
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.poster.events, [])
                try expectEqual(harness.service.targetDisplay, nil)
            }
        },
        TestCase("TouchMappingService.ambiguousAutomaticTargetNeverPostsInput") {
            try await MainActor.run {
                let harness = makeMappingHarness(displays: [
                    paperlikeDisplay(id: 11, name: "Paperlike13K Color"),
                    paperlikeDisplay(id: 12, name: "PaperLike 13K Touch")
                ])
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.poster.events, [])
                try expectEqual(harness.service.targetDisplay, nil)
            }
        },
        TestCase("TouchMappingService.matchesPaperlikeVariantAutomatically") {
            try await MainActor.run {
                let harness = makeMappingHarness(displays: [
                    paperlikeDisplay(id: 11, name: "PaperLike 13.3")
                ])
                harness.service.start()
                try expectEqual(harness.service.targetDisplay?.id, 11)
            }
        },
        TestCase("TouchMappingService.usesValidatedHIDBoundsWithoutManualCalibration") {
            try await MainActor.run {
                let harness = makeMappingHarness(coordinateBounds: TouchCalibration(minX: 100, maxX: 4_000, minY: 200, maxY: 3_800))
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 2_050, y: 2_000))

                try expectEqual(harness.service.calibrationSource, .automaticHID)
                try expectEqual(harness.poster.events, [.move(CGPoint(x: 960, y: 540))])
            }
        },
        TestCase("TouchMappingService.manualCalibrationOverridesHIDBounds") {
            try await MainActor.run {
                let harness = makeMappingHarness(coordinateBounds: TouchCalibration(minX: 100, maxX: 4_000, minY: 200, maxY: 3_800))
                let manual = TouchCalibration(minX: 0, maxX: 2_000, minY: 0, maxY: 4_000)!
                harness.service.start()
                harness.service.setCalibration(manual)
                harness.input.emitReport(validTouchReport(x: 1_000, y: 2_000))

                try expectEqual(harness.service.calibrationSource, .manual)
                try expectEqual(harness.poster.events, [.move(CGPoint(x: 960, y: 540))])
            }
        },
        TestCase("TouchMappingService.explicitDefaultCalibrationStillOverridesHIDBounds") {
            try await MainActor.run {
                let harness = makeMappingHarness(
                    displays: [paperlikeDisplay(stableID: nil)],
                    coordinateBounds: TouchCalibration(minX: 100, maxX: 4_000, minY: 200, maxY: 3_800)
                )
                harness.service.start()
                harness.service.setCalibration(.default)
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.service.calibrationSource, .manual)
                try expectEqual(harness.poster.events, [.move(CGPoint(x: 480, y: 540))])
            }
        },
        TestCase("TouchMappingService.switchingToEqualManualBoundsStillReleasesDrag") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                primeActiveDrag(harness)
                let eventCountBeforeChange = harness.poster.events.count

                harness.service.setCalibration(.default)

                try expectEqual(harness.poster.events.count, eventCountBeforeChange + 1)
                try expectEqual(harness.poster.events.last, .leftUp(CGPoint(x: 960, y: 540)))
            }
        },
        TestCase("TouchMappingService.selectingDisplayPersistsStableIdentity") {
            try await MainActor.run {
                let chosen = paperlikeDisplay(id: 22, stableID: "monitor-A")
                let harness = makeMappingHarness(displays: [paperlikeDisplay(), chosen])
                harness.service.start()
                harness.service.setDisplaySelection(.display(22))
                harness.displays.setDisplays([paperlikeDisplay(), paperlikeDisplay(id: 33, stableID: "monitor-A")])

                try expectEqual(harness.service.settings.displaySelection, .stable("monitor-A"))
                try expectEqual(harness.service.targetDisplay?.id, 33)
            }
        },
        TestCase("TouchMappingService.migratesLegacyDisplayAndKeepsItsManualCalibrationScoped") {
            try await MainActor.run {
                let legacy = TouchMappingSettings(
                    displaySelection: .display(11),
                    calibration: TouchCalibration(minX: 100, maxX: 3_900, minY: 200, maxY: 3_800)!
                )
                let harness = makeMappingHarness(
                    displays: [paperlikeDisplay(id: 11, stableID: "monitor-A"), paperlikeDisplay(id: 22, stableID: "monitor-B")],
                    initialSettings: legacy
                )
                harness.service.start()
                try expectEqual(harness.service.settings.displaySelection, .stable("monitor-A"))
                try expectEqual(harness.service.calibrationSource, .manual)
                harness.service.setDisplaySelection(.display(22))

                try expectEqual(harness.service.calibrationSource, .automaticFallback)
                try expectEqual(harness.service.settings.calibrationByDisplay["monitor-A"], legacy.calibration)
                try expectEqual(harness.settingsStore.load(), harness.service.settings)
            }
        },
        TestCase("TouchMappingService.manualCalibrationIsPerStableDisplay") {
            try await MainActor.run {
                let first = paperlikeDisplay(id: 11, stableID: "monitor-A")
                let second = paperlikeDisplay(id: 22, stableID: "monitor-B")
                let harness = makeMappingHarness(displays: [first, second])
                let manual = TouchCalibration(minX: 100, maxX: 3_900, minY: 200, maxY: 3_800)!
                harness.service.start()
                harness.service.setDisplaySelection(.display(11))
                harness.service.setCalibration(manual)
                harness.service.setDisplaySelection(.display(22))
                try expectEqual(harness.service.calibrationSource, .automaticFallback)
                harness.service.setDisplaySelection(.display(11))

                try expectEqual(harness.service.calibrationSource, .manual)
                try expectEqual(harness.service.effectiveCalibration, manual)
            }
        },
        TestCase("TouchMappingService.useAutomaticCalibrationClearsOnlyCurrentDisplayAndReleasesDrag") {
            try await MainActor.run {
                let first = paperlikeDisplay(id: 11, stableID: "monitor-A")
                let second = paperlikeDisplay(id: 22, stableID: "monitor-B")
                let harness = makeMappingHarness(displays: [first, second])
                let firstCalibration = TouchCalibration(minX: 100, maxX: 3_900, minY: 200, maxY: 3_800)!
                let secondCalibration = TouchCalibration(minX: 200, maxX: 3_800, minY: 300, maxY: 3_700)!
                harness.service.start()
                harness.service.setDisplaySelection(.display(11))
                harness.service.setCalibration(firstCalibration)
                harness.service.setDisplaySelection(.display(22))
                harness.service.setCalibration(secondCalibration)
                harness.service.setDisplaySelection(.display(11))
                primeActiveDrag(harness)
                let eventsBeforeReset = harness.poster.events.count

                harness.service.useAutomaticCalibration()

                try expectEqual(harness.poster.events.count, eventsBeforeReset + 1)
                try expectEqual(harness.service.calibrationSource, .automaticFallback)
                try expectEqual(harness.service.settings.displaySelection, .stable("monitor-A"))
                try expectEqual(harness.service.settings.calibrationByDisplay["monitor-B"], secondCalibration)
                try expectEqual(harness.service.settings.calibrationByDisplay["monitor-A"], nil)
                try expectEqual(harness.settingsStore.load(), harness.service.settings)
            }
        },
        TestCase("TouchMappingService.oversizedApplyKeepsRuntimeAndStore") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                let before = harness.service.settings
                let oversized = before.updating(displaySelection: .stable(String(repeating: "x", count: 200_000)))
                harness.service.applySettings(oversized)
                try expectEqual(harness.service.settings, before)
                try expectEqual(harness.settingsStore.load(), before)
                harness.service.refresh()
                guard case .error = harness.service.status else { throw TestFailure(description: "save failure must survive refresh") }
                try expect(harness.service.applySettings(before), "valid correction must save successfully")
                try expectEqual(harness.service.settings, before)
                try expectEqual(harness.settingsStore.saveError, nil)
            }
        },
        TestCase("TouchMappingService.applySettingsReleasesDragAndDoesNotPrompt") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                primeActiveDrag(harness)
                let replacement = TouchMappingSettings(isEnabled: false)
                harness.service.applySettings(replacement)

                try expectEqual(harness.poster.events.last, .leftUp(CGPoint(x: 960, y: 540)))
                try expectEqual(harness.settingsStore.load(), replacement)
                try expectEqual(harness.accessibility.promptRequestCount, 0)
            }
        },
        TestCase("TouchMappingService.decodeFailureNeverPostsInput") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                harness.input.emitReport([1, 2, 3])

                try expectEqual(harness.poster.events, [])
            }
        },
        TestCase("TouchMappingService.postsDecodedGestureWhenEverySafetyGateIsOpen") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                let report = validTouchReport(x: 1_024, y: 2_048)
                harness.input.emitReport(report, timestamp: 1)

                try expectEqual(harness.service.latestFrame, nil)
                try expectEqual(harness.poster.events, [.move(CGPoint(x: 480, y: 540))])
            }
        },
        TestCase("TouchMappingService.singleFingerScrollsWhenEnabled") {
            try await MainActor.run {
                let harness = makeMappingHarness(
                    initialSettings: TouchMappingSettings(isEnabled: true, isSingleFingerScrollEnabled: true)
                )
                harness.service.start()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048), timestamp: 1)
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_150), timestamp: 1.1)

                try expect(!harness.poster.events.isEmpty, "events emitted")
                guard case .scroll? = harness.poster.events.last else {
                    throw TestFailure(description: "Expected scroll event, got \(harness.poster.events)")
                }
            }
        },
        TestCase("TouchMappingService.testingReadsContactsWithoutPostingOrPermission") {
            try await MainActor.run {
                let harness = makeMappingHarness(isEnabled: false, trusted: false)
                harness.service.start()
                harness.service.setTesting(true)
                let report = validTouchReport(x: 1_024, y: 2_048)

                harness.input.emitReport(report, timestamp: 2)

                try expectEqual(
                    harness.service.latestFrame,
                    try TouchReportDecoder().decode(report, timestamp: 2)
                )
                try expectEqual(harness.poster.events, [])
                try expectEqual(harness.accessibility.promptRequestCount, 0)
            }
        },
        TestCase("TouchMappingService.enteringTestingClearsStaleContact") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                harness.service.setTesting(true)
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))
                try expect(harness.service.latestFrame != nil, "testing captured a frame")
                harness.service.setTesting(false)

                harness.service.setTesting(true)

                try expectEqual(harness.service.latestFrame, nil)
            }
        },
        TestCase("TouchMappingService.exposesAndPersistsUISettings") {
            try await MainActor.run {
                let explicitDisplay = paperlikeDisplay(id: 22, name: "PaperLike Touch")
                let harness = makeMappingHarness(
                    isEnabled: false,
                    trusted: false,
                    displays: [paperlikeDisplay(), explicitDisplay]
                )
                harness.service.start()
                let calibration = TouchCalibration(
                    minX: 120,
                    maxX: 3_980,
                    minY: 160,
                    maxY: 3_940,
                    swapAxes: true,
                    flipY: true
                )!

                harness.service.setDisplaySelection(.display(explicitDisplay.id))
                harness.service.setCalibration(calibration)

                try expectEqual(harness.service.settings.displaySelection, .display(22))
                try expectEqual(harness.service.settings.calibration, calibration)
                try expectEqual(harness.service.availableDisplays, [paperlikeDisplay(), explicitDisplay])
                try expectEqual(harness.service.isTouchDeviceConnected, true)
                try expectEqual(harness.service.isAccessibilityTrusted, false)
                try expectEqual(harness.settingsStore.load(), harness.service.settings)
                try expectEqual(harness.service.targetDisplay, explicitDisplay)
            }
        },
        cancellationTest("TouchMappingService.disconnectCancelsActiveDrag") { harness in
            harness.input.setConnected(false)
        },
        cancellationTest("TouchMappingService.pauseCancelsActiveDrag") { harness in
            harness.service.pause()
        },
        TestCase("TouchMappingService.refreshAfterPauseDoesNotResumeMapping") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                harness.service.pause()
                let startCountAfterPause = harness.input.startCount

                harness.service.refresh()
                harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048))

                try expectEqual(harness.service.status, .stopped)
                try expectEqual(harness.input.startCount, startCountAfterPause)
                try expectEqual(harness.poster.events, [])
            }
        },
        TestCase("TouchMappingService.refreshRecognizesNewAccessibilityGrant") {
            try await MainActor.run {
                let harness = makeMappingHarness(isEnabled: true, trusted: false)
                harness.service.start()
                try expectEqual(harness.service.status, .accessibilityRequired)
                harness.accessibility.isTrusted = true
                harness.service.refresh()
                try expectEqual(harness.service.isAccessibilityTrusted, true)
                try expectEqual(harness.service.status, .ready)
            }
        },
        cancellationTest("TouchMappingService.displayRemovalCancelsActiveDrag") { harness in
            harness.displays.setDisplays([])
        },
        TestCase("TouchMappingService.targetDisplayReplacementCancelsActiveDragBeforeSwitch") {
            try await MainActor.run {
                let firstDisplay = paperlikeDisplay(id: 11)
                let replacementDisplay = paperlikeDisplay(id: 12)
                let harness = makeMappingHarness(displays: [firstDisplay])
                harness.service.start()
                primeActiveDrag(harness)
                let eventCountBeforeReplacement = harness.poster.events.count

                harness.displays.setDisplays([replacementDisplay])

                try expectEqual(harness.poster.events.count, eventCountBeforeReplacement + 1)
                try expectEqual(harness.poster.events.last, .leftUp(CGPoint(x: 960, y: 540)))
                try expectEqual(harness.service.targetDisplay, replacementDisplay)
            }
        },
        TestCase("TouchMappingService.targetDisplayBoundsChangeCancelsActiveDragBeforeSwitch") {
            try await MainActor.run {
                let firstDisplay = paperlikeDisplay(id: 11)
                let resizedDisplay = paperlikeDisplay(
                    id: 11,
                    bounds: CGRect(x: 0, y: 0, width: 3_840, height: 2_160)
                )
                let harness = makeMappingHarness(displays: [firstDisplay])
                harness.service.start()
                primeActiveDrag(harness)
                let eventCountBeforeResize = harness.poster.events.count

                harness.displays.setDisplays([resizedDisplay])

                try expectEqual(harness.poster.events.count, eventCountBeforeResize + 1)
                try expectEqual(harness.poster.events.last, .leftUp(CGPoint(x: 960, y: 540)))
                try expectEqual(harness.service.targetDisplay, resizedDisplay)
            }
        },
        cancellationTest("TouchMappingService.inputErrorCancelsActiveDrag") { harness in
            harness.input.emit(.failure("read failed"))
        },
        cancellationTest("TouchMappingService.restoreDefaultsCancelsActiveDrag") { harness in
            harness.service.restoreDefaults()
        },
        cancellationTest("TouchMappingService.shutdownCancelsActiveDrag") { harness in
            harness.service.shutdown()
        },
        TestCase("TouchMappingService.rejectsStaleInputCallbackAfterPauseAndRestart") {
            try await MainActor.run {
                let harness = makeMappingHarness()
                harness.service.start()
                let staleHandler = harness.input.eventHandler
                harness.service.pause()
                harness.service.start()
                let eventCountBeforeStaleCallback = harness.poster.events.count

                staleHandler?(.report(validTouchReport(x: 1_024, y: 2_048), timestamp: 1))

                try expectEqual(harness.poster.events.count, eventCountBeforeStaleCallback)
            }
        },
        TestCase("TouchMappingService.deinitCancelsActiveDrag") {
            try await MainActor.run {
                let input = FakeTouchInputSource(isConnected: true)
                let poster = FakeTouchEventPoster()
                let displayProvider = FakeTouchDisplayProvider(displays: [paperlikeDisplay()])
                let accessibility = FakeAccessibilityChecker(isTrusted: true)
                let suiteName = "PaperlikeTests.TouchMapping.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suiteName)!
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let settingsStore = TouchSettingsStore(defaults: defaults)
                settingsStore.save(TouchMappingSettings(isEnabled: true, isSingleFingerScrollEnabled: false))
                var service: TouchMappingService? = TouchMappingService(
                    inputSource: input,
                    eventPoster: poster,
                    displayProvider: displayProvider,
                    accessibility: accessibility,
                    settingsStore: settingsStore
                )
                service?.start()
                input.emitReport(validTouchReport(x: 1_024, y: 2_048), timestamp: 1)
                input.emitReport(validTouchReport(x: 2_048, y: 2_048), timestamp: 1.1)
                let eventCountBeforeDeinit = poster.events.count

                service = nil

                try expectEqual(poster.events.count, eventCountBeforeDeinit + 1)
                try expectEqual(poster.events.last, .leftUp(CGPoint(x: 960, y: 540)))
            }
        },
        TestCase("TouchMappingService.promptsForAccessibilityOnlyFromExplicitRequest") {
            try await MainActor.run {
                let harness = makeMappingHarness(trusted: false)
                harness.service.start()
                harness.service.setEnabled(true)
                harness.service.setTesting(true)

                try expectEqual(harness.accessibility.promptRequestCount, 0)
                harness.service.requestAccessibility()
                try expectEqual(harness.accessibility.promptRequestCount, 1)
            }
        }
    ]
}

private func cancellationTest(
    _ name: String,
    action: @escaping @MainActor (MappingHarness) -> Void
) -> TestCase {
    TestCase(name) {
        try await MainActor.run {
            let harness = makeMappingHarness()
            harness.service.start()
            primeActiveDrag(harness)
            let eventCountBeforeCancellation = harness.poster.events.count

            action(harness)

            try expectEqual(harness.poster.events.count, eventCountBeforeCancellation + 1)
            try expectEqual(harness.poster.events.last, .leftUp(CGPoint(x: 960, y: 540)))
        }
    }
}

@MainActor
private final class MappingHarness {
    let input: FakeTouchInputSource
    let poster: FakeTouchEventPoster
    let displays: FakeTouchDisplayProvider
    let accessibility: FakeAccessibilityChecker
    let service: TouchMappingService
    let settingsStore: TouchSettingsStore
    private let defaults: UserDefaults
    private let suiteName: String

    init(
        input: FakeTouchInputSource,
        poster: FakeTouchEventPoster,
        displays: FakeTouchDisplayProvider,
        accessibility: FakeAccessibilityChecker,
        service: TouchMappingService,
        settingsStore: TouchSettingsStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        self.input = input
        self.poster = poster
        self.displays = displays
        self.accessibility = accessibility
        self.service = service
        self.settingsStore = settingsStore
        self.defaults = defaults
        self.suiteName = suiteName
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makeMappingHarness(
    isEnabled: Bool = true,
    trusted: Bool = true,
    connected: Bool = true,
    displays: [TouchDisplay] = [paperlikeDisplay()],
    coordinateBounds: TouchCalibration? = nil,
    initialSettings: TouchMappingSettings? = nil,
    cursorManager: TouchCursorManager = .shared
) -> MappingHarness {
    let input = FakeTouchInputSource(isConnected: connected, coordinateBounds: coordinateBounds)
    let poster = FakeTouchEventPoster()
    let displayProvider = FakeTouchDisplayProvider(displays: displays)
    let accessibility = FakeAccessibilityChecker(isTrusted: trusted)
    let suiteName = "PaperlikeTests.TouchMapping.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settingsStore = TouchSettingsStore(defaults: defaults)
    settingsStore.save(initialSettings ?? TouchMappingSettings(isEnabled: isEnabled, isSingleFingerScrollEnabled: false))
    let service = TouchMappingService(
        inputSource: input,
        eventPoster: poster,
        displayProvider: displayProvider,
        accessibility: accessibility,
        settingsStore: settingsStore,
        cursorManager: cursorManager
    )
    return MappingHarness(
        input: input,
        poster: poster,
        displays: displayProvider,
        accessibility: accessibility,
        service: service,
        settingsStore: settingsStore,
        defaults: defaults,
        suiteName: suiteName
    )
}

@MainActor
private func primeActiveDrag(_ harness: MappingHarness) {
    harness.input.emitReport(validTouchReport(x: 1_024, y: 2_048), timestamp: 1)
    harness.input.emitReport(validTouchReport(x: 2_048, y: 2_048), timestamp: 1.1)
}

private func paperlikeDisplay(
    id: CGDirectDisplayID = 11,
    name: String = "Paperlike13K Color",
    bounds: CGRect = CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
    stableID: String? = nil
) -> TouchDisplay {
    TouchDisplay(
        id: id,
        name: name,
        bounds: bounds,
        stableID: stableID
    )
}

private func validTouchReport(x: UInt16, y: UInt16) -> [UInt8] {
    var report = Array(repeating: UInt8(0), count: 84)
    report[0] = 1
    report[1] = 1
    report[2] = 7
    report[3] = UInt8(truncatingIfNeeded: x)
    report[4] = UInt8(truncatingIfNeeded: x >> 8)
    report[5] = UInt8(truncatingIfNeeded: y)
    report[6] = UInt8(truncatingIfNeeded: y >> 8)
    report[7] = 20
    report[83] = 1
    return report
}

@MainActor
private final class FakeTouchInputSource: TouchInputSource {
    private(set) var isConnected: Bool
    let coordinateBounds: TouchCalibration?
    var eventHandler: ((TouchInputEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(isConnected: Bool, coordinateBounds: TouchCalibration? = nil) {
        self.isConnected = isConnected
        self.coordinateBounds = coordinateBounds
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        eventHandler?(connected ? .connected : .disconnected)
    }

    func emitReport(_ bytes: [UInt8], timestamp: TimeInterval = 1) {
        emit(.report(bytes, timestamp: timestamp))
    }

    func emit(_ event: TouchInputEvent) {
        eventHandler?(event)
    }
}

@MainActor
private final class FakeTouchEventPoster: TouchEventPosting {
    private(set) var events: [TouchOutputEvent] = []

    func post(_ event: TouchOutputEvent) {
        events.append(event)
    }
}

@MainActor
private final class FakeTouchDisplayProvider: TouchDisplayProviding {
    var displaysDidChange: (() -> Void)?
    private var currentDisplays: [TouchDisplay]

    init(displays: [TouchDisplay]) {
        currentDisplays = displays
    }

    func displays() -> [TouchDisplay] {
        currentDisplays
    }

    func startObserving() {}
    func stopObserving() {}

    func setDisplays(_ displays: [TouchDisplay]) {
        currentDisplays = displays
        displaysDidChange?()
    }
}

@MainActor
private final class FakeAccessibilityChecker: AccessibilityChecking {
    var isTrusted: Bool
    private(set) var checkCount = 0
    private(set) var promptRequestCount = 0

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
    }

    func checkIsTrusted() -> Bool {
        checkCount += 1
        return isTrusted
    }

    func requestTrustPrompt() -> Bool {
        promptRequestCount += 1
        return isTrusted
    }
}
