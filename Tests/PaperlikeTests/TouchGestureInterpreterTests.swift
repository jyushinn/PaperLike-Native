import CoreGraphics
import Foundation
import PaperlikeTouch
import AppKit

func touchGestureInterpreterTests() -> [TestCase] {
    [
        TestCase("TouchGestureInterpreter.staggeredLongHoldDoesNotRightClick") {
            let interpreter = TouchGestureInterpreter()
            _ = interpreter.consume(twoTouchFrame(timestamp: 0), map: mapTouchContact)
            let partial = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 10, y: 10))], timestamp: 0.5), map: mapTouchContact)
            let final = interpreter.consume(touchFrame([], timestamp: 0.51), map: mapTouchContact)
            try expectEqual(partial + final, [])
        },
        TestCase("TouchGestureInterpreter.duplicateTimestampDoesNotGenerateFlingVelocity") {
            let interpreter = TouchGestureInterpreter()
            var triggered = false
            interpreter.onInertiaTriggered = { _, _, _ in triggered = true }
            _ = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 100, y: 100))], timestamp: 1), map: mapTouchContact)
            _ = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 120, y: 100))], timestamp: 1), map: mapTouchContact)
            _ = interpreter.consume(touchFrame([], timestamp: 1.01), map: mapTouchContact)
            try expect(!triggered, "zero time must not become a physical fling velocity")
        },
        TestCase("TouchGestureInterpreter.secondFingerDuringScrollOnlyRebasesGesture") {
            let interpreter = TouchGestureInterpreter()
            _ = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 100, y: 100))], timestamp: 0), map: mapTouchContact)
            _ = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 110, y: 100))], timestamp: 0.1), map: mapTouchContact)
            let events = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 110, y: 100)), touchContact(id: 2, point: CGPoint(x: 150, y: 100))], timestamp: 0.2), map: mapTouchContact)
            try expectEqual(events, [])
            let continued = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 120, y: 100)), touchContact(id: 2, point: CGPoint(x: 160, y: 100))], timestamp: 0.3), map: mapTouchContact)
            try expectEqual(continued, [.scroll(deltaX: 10, deltaY: 0, at: CGPoint(x: 100, y: 100))])
        },
        TestCase("TouchGestureInterpreter.staggeredTwoFingerReleaseClicksExactlyOnce") {
            let interpreter = TouchGestureInterpreter()
            _ = interpreter.consume(twoTouchFrame(timestamp: 0), map: mapTouchContact)
            let partial = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 10, y: 10))], timestamp: 0.19), map: mapTouchContact)
            let final = interpreter.consume(touchFrame([], timestamp: 0.2), map: mapTouchContact)
            try expectEqual(partial + final, [.rightDown(CGPoint(x: 20, y: 10)), .rightUp(CGPoint(x: 20, y: 10))])
        },
        TestCase("TouchGestureInterpreter.inertiaVelocityDoesNotDependOnReportRate") {
            func fling(hz: Int) -> CGFloat {
                let interpreter = TouchGestureInterpreter()
                var velocity: CGFloat = 0
                interpreter.onInertiaTriggered = { x, _, _ in velocity = x }
                for sample in 0...hz {
                    _ = interpreter.consume(touchFrame([touchContact(id: 1, point: CGPoint(x: 100 + sample * 120 / hz, y: 100))], timestamp: Double(sample) / Double(hz)), map: mapTouchContact)
                }
                _ = interpreter.consume(touchFrame([], timestamp: 1.001), map: mapTouchContact)
                return velocity
            }
            try expect(abs(fling(hz: 30) - fling(hz: 120)) < 0.001, "same physical motion must have the same fling velocity")
        },
        TestCase("TouchGestureInterpreter.twoFingerScrollPostsAtTouchTarget") {
            try await MainActor.run {
                let interpreter = TouchGestureInterpreter()
                var events: [CGEvent] = []
                let poster = TouchEventPoster(eventSink: { events.append($0) })
                let start = touchFrame([touchContact(id: 1, point: CGPoint(x: 1010, y: 900)), touchContact(id: 2, point: CGPoint(x: 1050, y: 900))], timestamp: 0)
                let moved = touchFrame([touchContact(id: 1, point: CGPoint(x: 1020, y: 900)), touchContact(id: 2, point: CGPoint(x: 1060, y: 900))], timestamp: 0.1)
                (interpreter.consume(start, map: mapTouchContact) + interpreter.consume(moved, map: mapTouchContact)).forEach(poster.post)
                guard let scroll = events.last(where: { $0.type == .scrollWheel }) else { throw TestFailure(description: "no scroll") }
                try expectEqual(scroll.location, CGPoint(x: 1030, y: 900))
            }
        },
        TestCase("TouchEventPoster.accumulatesFractionalZoomAndResetsAtGestureEnd") {
            try await MainActor.run {
                var values: [Int64] = []
                var commandFlags: [Bool] = []
                let poster = TouchEventPoster(eventSink: { event in
                    commandFlags.append(event.flags.contains(.maskCommand))
                    values.append(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                })
                for _ in 0..<10 { poster.post(.zoom(delta: 0.1, at: .zero)) }
                try expectEqual(values, [1])
                poster.post(.zoom(delta: 0.4, at: .zero))
                poster.post(.zoomEnded)
                poster.post(.zoom(delta: 0.6, at: .zero))
                try expectEqual(values, [1])
                poster.post(.zoom(delta: 0.4, at: .zero))
                try expectEqual(values, [1, 1])
                poster.post(.zoomEnded)
                for _ in 0..<4 { poster.post(.zoom(delta: -0.25, at: .zero)) }
                try expectEqual(values, [1, 1, -1])
                try expect(commandFlags.allSatisfy { $0 }, "zoom uses Command+Wheel emulation")
            }
        },
        TestCase("TouchEventPoster.respectsSystemDoubleClickInterval") {
            try await MainActor.run {
                var now = 10.0
                var counts: [Int64] = []
                let poster = TouchEventPoster(eventSink: { event in
                    counts.append(event.getIntegerValueField(.mouseEventClickState))
                }, clock: { now }, doubleClickInterval: { 0.8 })
                poster.post(.leftDown(.zero))
                now += 0.6
                poster.post(.leftDown(.zero))
                try expectEqual(counts, [1, 2])
                now += 0.9
                poster.post(.leftDown(.zero))
                try expectEqual(counts, [1, 2, 1])
            }
        },
        TestCase("TouchInertiaEngine.decaysUsingElapsedTimeAndIntegratesDisplacement") {
            try await MainActor.run {
                for frames in [0.5, 1, 1.5, 2, 6] {
                    var now = 0.0
                    var displacement: CGFloat = 0
                    let engine = TouchInertiaEngine(clock: { now })
                    engine.start(vx: 10, vy: 0) { dx, _ in displacement += dx }
                    defer { engine.stop() }
                    now = frames / 60
                    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                    let decay = pow(CGFloat(0.92), CGFloat(frames))
                    try expect(abs(engine.currentVelocity.x - 10 * decay) < 0.00001, "velocity decay follows \(frames) real frames")
                    let expectedDistance = 10 * 0.92 * (1 - decay) / (1 - 0.92)
                    try expect(abs(displacement - expectedDistance) < 0.00001, "displacement integrates elapsed frames, including missed ticks")
                    let velocity = engine.currentVelocity
                    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                    try expectEqual(engine.currentVelocity, velocity)
                }
            }
        },
        TestCase("TouchGestureInterpreterTests.pinchEndAndCancelResetZoomState") {
            for ending in 0..<3 {
                let interpreter = TouchGestureInterpreter()
                _ = interpreter.consume(twoTouchFrame(timestamp: 0), map: mapTouchContact)
                _ = interpreter.consume(touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 5, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 35, y: 10))
                ], timestamp: 0.1), map: mapTouchContact)
                let events: [TouchOutputEvent]
                if ending == 0 {
                    events = interpreter.cancel()
                } else {
                    events = interpreter.consume(touchFrame(ending == 1 ? [] : [
                        touchContact(id: 1, point: CGPoint(x: 5, y: 10))
                    ], timestamp: 0.2), map: mapTouchContact)
                }
                try expectEqual(events, [.zoomEnded])
                try expectEqual(interpreter.cancel(), [])
            }
        },
        TestCase("TouchGestureInterpreterTests.stationaryPinchDoesNotRepeatInitialZoom") {
            let interpreter = TouchGestureInterpreter()
            _ = interpreter.consume(twoTouchFrame(timestamp: 0), map: mapTouchContact)
            let spread = touchFrame([
                touchContact(id: 1, point: CGPoint(x: 5, y: 10)),
                touchContact(id: 2, point: CGPoint(x: 35, y: 10))
            ], timestamp: 0.1)
            _ = interpreter.consume(spread, map: mapTouchContact)
            try expectEqual(interpreter.consume(spread, map: mapTouchContact), [])
        },
        TestCase("TouchGestureInterpreterTests.emitsClickForShortSingleFingerRelease") {
            let interpreter = TouchGestureInterpreter()
            let point = CGPoint(x: 20, y: 30)

            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 1),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([], timestamp: 1.2),
                map: mapTouchContact
            )

            try expectEqual(events, [
                .move(point),
                .leftDown(point),
                .leftUp(point)
            ])
        },
        TestCase("TouchGestureInterpreterTests.startsScrollAfterSingleFingerMovesPastThreshold") {
            let interpreter = TouchGestureInterpreter()
            let start = CGPoint(x: 20, y: 30)
            let current = CGPoint(x: 29, y: 30)

            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 1),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([touchContact(id: 1, point: current)], timestamp: 1.1),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([], timestamp: 1.2),
                map: mapTouchContact
            )

            try expectEqual(events, [
                .move(start),
                .scroll(deltaX: 9, deltaY: 0, at: start)
            ])
        },
        TestCase("TouchGestureInterpreterTests.startsDragAfterSingleFingerLongPress") {
            let interpreter = TouchGestureInterpreter()
            let start = CGPoint(x: 20, y: 30)
            let dragged = CGPoint(x: 29, y: 30)

            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 1),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 1.45),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([touchContact(id: 1, point: dragged)], timestamp: 1.5),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([], timestamp: 1.6),
                map: mapTouchContact
            )

            try expectEqual(events, [
                .move(start),
                .leftDown(start),
                .leftDragged(start),
                .leftDragged(dragged),
                .leftUp(dragged)
            ])
        },
        TestCase("TouchGestureInterpreterTests.cancelReleasesActiveDragAtLastPoint") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let lastPoint = CGPoint(x: 29, y: 30)

            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 1),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: lastPoint)], timestamp: 1.1),
                map: mapTouchContact
            )

            try expectEqual(interpreter.cancel(), [.leftUp(lastPoint)])
        },
        TestCase("TouchGestureInterpreterTests.scrollsUsingTwoFingerCentroidDelta") {
            let interpreter = TouchGestureInterpreter()

            _ = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 10, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 30, y: 10))
                ], timestamp: 1),
                map: mapTouchContact
            )
            let events = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 20, y: 20)),
                    touchContact(id: 2, point: CGPoint(x: 40, y: 20))
                ], timestamp: 1.1),
                map: mapTouchContact
            )

            try expectEqual(events, [.scroll(deltaX: 10, deltaY: 10, at: CGPoint(x: 20, y: 10))])
        },
        TestCase("TouchGestureInterpreterTests.emitsRightClickForShortStationaryTwoFingerRelease") {
            let interpreter = TouchGestureInterpreter()
            let centroid = CGPoint(x: 20, y: 10)

            _ = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 10, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 30, y: 10))
                ], timestamp: 1),
                map: mapTouchContact
            )
            let events = interpreter.consume(
                touchFrame([], timestamp: 1.2),
                map: mapTouchContact
            )

            try expectEqual(events, [.rightDown(centroid), .rightUp(centroid)])
        },
        TestCase("TouchGestureInterpreterTests.releasesActiveDragWhenASecondFingerArrives") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let lastPoint = CGPoint(x: 29, y: 30)

            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 1),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: lastPoint)], timestamp: 1.1),
                map: mapTouchContact
            )
            let events = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: lastPoint),
                    touchContact(id: 2, point: CGPoint(x: 49, y: 30))
                ], timestamp: 1.2),
                map: mapTouchContact
            )

            try expectEqual(events, [.leftUp(lastPoint)])
        },
        TestCase("TouchGestureInterpreterTests.ignoresThreeOrMoreContacts") {
            let interpreter = TouchGestureInterpreter()

            let events = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 10, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 20, y: 10)),
                    touchContact(id: 3, point: CGPoint(x: 30, y: 10))
                ], timestamp: 1),
                map: mapTouchContact
            )

            try expectEqual(events, [])
        },
        TestCase("TouchGestureInterpreterTests.resetsIgnoredStateOnlyAfterZeroContactFrame") {
            let interpreter = TouchGestureInterpreter()
            let point = CGPoint(x: 20, y: 30)

            _ = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 10, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 20, y: 10)),
                    touchContact(id: 3, point: CGPoint(x: 30, y: 10))
                ], timestamp: 1),
                map: mapTouchContact
            )
            let ignoredEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 1.1),
                map: mapTouchContact
            )
            _ = interpreter.consume(touchFrame([], timestamp: 1.2), map: mapTouchContact)
            let resetEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 1.3),
                map: mapTouchContact
            )

            try expectEqual(ignoredEvents, [])
            try expectEqual(resetEvents, [.move(point)])
        },
        TestCase("TouchGestureInterpreterTests.acceptsExactClickDurationAndDistanceThresholds") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let boundary = CGPoint(x: 28, y: 30)

            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 0),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([touchContact(id: 1, point: boundary)], timestamp: 0.1),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([], timestamp: 0.35),
                map: mapTouchContact
            )

            try expectEqual(events, [
                .move(start),
                .move(boundary),
                .leftDown(boundary),
                .leftUp(boundary)
            ])
        },
        TestCase("TouchGestureInterpreterTests.startsDragOnExactHoldDuration") {
            let interpreter = TouchGestureInterpreter()
            let point = CGPoint(x: 20, y: 30)

            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0),
                map: mapTouchContact
            )
            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0.45),
                map: mapTouchContact
            )

            try expectEqual(events, [.leftDown(point), .leftDragged(point)])
        },
        TestCase("TouchGestureInterpreterTests.startsScrollingOnlyPastExactFivePointThreshold") {
            let interpreter = TouchGestureInterpreter()

            _ = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 10, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 30, y: 10))
                ], timestamp: 0),
                map: mapTouchContact
            )
            let exactThresholdEvents = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 15, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 35, y: 10))
                ], timestamp: 0.1),
                map: mapTouchContact
            )
            let pastThresholdEvents = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: CGPoint(x: 16, y: 10)),
                    touchContact(id: 2, point: CGPoint(x: 36, y: 10))
                ], timestamp: 0.2),
                map: mapTouchContact
            )

            try expectEqual(exactThresholdEvents, [])
            try expectEqual(pastThresholdEvents, [.scroll(deltaX: 6, deltaY: 0, at: CGPoint(x: 20, y: 10))])
        },
        TestCase("TouchGestureInterpreterTests.emitsContinuousPointerMotionBelowDragThreshold") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let first = CGPoint(x: 23, y: 30)
            let second = CGPoint(x: 27, y: 30)

            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 0),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([touchContact(id: 1, point: first)], timestamp: 0.1),
                map: mapTouchContact
            ) + interpreter.consume(
                touchFrame([touchContact(id: 1, point: second)], timestamp: 0.2),
                map: mapTouchContact
            )

            try expectEqual(events, [.move(start), .move(first), .move(second)])
        },
        TestCase("TouchGestureInterpreterTests.releasesDraggedPrimaryAtLatestPositionWhenSecondFingerArrives") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let dragged = CGPoint(x: 29, y: 30)
            let latest = CGPoint(x: 35, y: 30)

            _ = interpreter.consume(
                touchFrame([touchContact(id: 7, point: start)], timestamp: 0),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 7, point: dragged)], timestamp: 0.1),
                map: mapTouchContact
            )
            let events = interpreter.consume(
                touchFrame([
                    touchContact(id: 7, point: latest),
                    touchContact(id: 8, point: CGPoint(x: 55, y: 30))
                ], timestamp: 0.2),
                map: mapTouchContact
            )

            try expectEqual(events, [.leftUp(latest)])
        },
        TestCase("TouchGestureInterpreterTests.releasesDraggedPrimaryAtLatestPositionWhenThirdFingerArrives") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let dragged = CGPoint(x: 29, y: 30)
            let latest = CGPoint(x: 35, y: 30)

            _ = interpreter.consume(
                touchFrame([touchContact(id: 7, point: start)], timestamp: 0),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 7, point: dragged)], timestamp: 0.1),
                map: mapTouchContact
            )
            let events = interpreter.consume(
                touchFrame([
                    touchContact(id: 7, point: latest),
                    touchContact(id: 8, point: CGPoint(x: 55, y: 30)),
                    touchContact(id: 9, point: CGPoint(x: 65, y: 30))
                ], timestamp: 0.2),
                map: mapTouchContact
            )

            try expectEqual(events, [.leftUp(latest)])
        },
        TestCase("TouchGestureInterpreterTests.ignoresFrameWhenAContactCannotBeMapped") {
            let interpreter = TouchGestureInterpreter()
            let point = CGPoint(x: 20, y: 30)

            let unmappedEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0),
                map: { _ in nil }
            )
            _ = interpreter.consume(touchFrame([], timestamp: 0.1), map: mapTouchContact)
            let recoveredEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0.2),
                map: mapTouchContact
            )

            try expectEqual(unmappedEvents, [])
            try expectEqual(recoveredEvents, [.move(point)])
        },
        TestCase("TouchGestureInterpreterTests.cancelIsIdempotent") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isSingleFingerScrollEnabled: false)
            )
            let start = CGPoint(x: 20, y: 30)
            let lastPoint = CGPoint(x: 29, y: 30)

            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: start)], timestamp: 0),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: lastPoint)], timestamp: 0.1),
                map: mapTouchContact
            )

            try expectEqual(interpreter.cancel(), [.leftUp(lastPoint)])
            try expectEqual(interpreter.cancel(), [])
        },
        TestCase("TouchGestureInterpreterTests.twoToOneTransitionRecoversOnlyAfterClearFrame") {
            let interpreter = TouchGestureInterpreter()
            let point = CGPoint(x: 20, y: 30)

            _ = interpreter.consume(twoTouchFrame(timestamp: 0), map: mapTouchContact)
            let transitionEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0.1),
                map: mapTouchContact
            )
            _ = interpreter.consume(touchFrame([], timestamp: 0.2), map: mapTouchContact)
            let recoveredEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0.3),
                map: mapTouchContact
            )

            try expectEqual(transitionEvents, [])
            try expectEqual(recoveredEvents, [.move(point)])
        },
        TestCase("TouchGestureInterpreterTests.twoToThreeTransitionRecoversOnlyAfterClearFrame") {
            let interpreter = TouchGestureInterpreter()
            let point = CGPoint(x: 20, y: 30)

            _ = interpreter.consume(twoTouchFrame(timestamp: 0), map: mapTouchContact)
            let transitionEvents = interpreter.consume(
                touchFrame([
                    touchContact(id: 1, point: point),
                    touchContact(id: 2, point: CGPoint(x: 30, y: 30)),
                    touchContact(id: 3, point: CGPoint(x: 40, y: 30))
                ], timestamp: 0.1),
                map: mapTouchContact
            )
            _ = interpreter.consume(touchFrame([], timestamp: 0.2), map: mapTouchContact)
            let recoveredEvents = interpreter.consume(
                touchFrame([touchContact(id: 1, point: point)], timestamp: 0.3),
                map: mapTouchContact
            )

            try expectEqual(transitionEvents, [])
            try expectEqual(recoveredEvents, [.move(point)])
        },
        TestCase("TouchGestureInterpreterTests.pinchToZoomDetectsDistanceChangeAndEmitsZoom") {
            let interpreter = TouchGestureInterpreter()
            let c1Start = CGPoint(x: 100, y: 100)
            let c2Start = CGPoint(x: 150, y: 100)
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: c1Start), touchContact(id: 2, point: c2Start)], timestamp: 0),
                map: mapTouchContact
            )

            // Spread fingers apart horizontally (initial distance 50 -> 80)
            let c1Spread = CGPoint(x: 85, y: 100)
            let c2Spread = CGPoint(x: 165, y: 100)
            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: c1Spread), touchContact(id: 2, point: c2Spread)], timestamp: 0.05),
                map: mapTouchContact
            )

            guard case let .zoom(delta, at)? = events.first else {
                throw TestFailure(description: "Expected .zoom event, got \(events)")
            }
            try expect(delta > 0, "Expected delta > 0")
            try expectEqual(at, CGPoint(x: 125, y: 100))
        },
        TestCase("TouchGestureInterpreterTests.traditionalScrollingInvertsDelta") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isNaturalScrolling: false)
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 100)), touchContact(id: 2, point: CGPoint(x: 110, y: 100))], timestamp: 0),
                map: mapTouchContact
            )

            // Move centroid down by 10 points
            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 110)), touchContact(id: 2, point: CGPoint(x: 110, y: 110))], timestamp: 0.05),
                map: mapTouchContact
            )

            try expectEqual(events, [.scroll(deltaX: 0, deltaY: -10, at: CGPoint(x: 100, y: 100))])
        },
        TestCase("TouchGestureInterpreterTests.scrollSpeedMultipliesDelta") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isNaturalScrolling: true, scrollSpeed: 2.0)
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 100)), touchContact(id: 2, point: CGPoint(x: 110, y: 100))], timestamp: 0),
                map: mapTouchContact
            )

            // Move centroid right by 10 points
            let events = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 100, y: 100)), touchContact(id: 2, point: CGPoint(x: 120, y: 100))], timestamp: 0.05),
                map: mapTouchContact
            )

            try expectEqual(events, [.scroll(deltaX: 20, deltaY: 0, at: CGPoint(x: 100, y: 100))])
        },
        TestCase("TouchGestureInterpreterTests.inertiaTriggeredOnRelease") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isInertialScrollEnabled: true)
            )
            var triggeredVelocity: (CGFloat, CGFloat)?
            interpreter.onInertiaTriggered = { vx, vy, _ in
                triggeredVelocity = (vx, vy)
            }

            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 100)), touchContact(id: 2, point: CGPoint(x: 110, y: 100))], timestamp: 0),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 120)), touchContact(id: 2, point: CGPoint(x: 110, y: 120))], timestamp: 0.02),
                map: mapTouchContact
            )
            _ = interpreter.consume(touchFrame([], timestamp: 0.04), map: mapTouchContact)

            try expect(triggeredVelocity != nil, "Expected inertia to trigger on release")
        },
        TestCase("TouchGestureInterpreterTests.inertiaTriggeredOnTwoToOneLiftoffTransition") {
            let interpreter = TouchGestureInterpreter(
                configuration: TouchGestureConfiguration(isInertialScrollEnabled: true)
            )
            var triggeredVelocity: (CGFloat, CGFloat)?
            interpreter.onInertiaTriggered = { vx, vy, _ in
                triggeredVelocity = (vx, vy)
            }

            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 100)), touchContact(id: 2, point: CGPoint(x: 110, y: 100))], timestamp: 0),
                map: mapTouchContact
            )
            _ = interpreter.consume(
                touchFrame([touchContact(id: 1, point: CGPoint(x: 90, y: 120)), touchContact(id: 2, point: CGPoint(x: 110, y: 120))], timestamp: 0.02),
                map: mapTouchContact
            )
            // One finger lifted off first
            _ = interpreter.consume(
                touchFrame([touchContact(id: 2, point: CGPoint(x: 110, y: 120))], timestamp: 0.03),
                map: mapTouchContact
            )

            try expect(triggeredVelocity != nil, "Expected inertia to trigger on 2->1 liftoff transition")
        }
    ]
}

private func twoTouchFrame(timestamp: TimeInterval) -> TouchFrame {
    touchFrame([
        touchContact(id: 1, point: CGPoint(x: 10, y: 10)),
        touchContact(id: 2, point: CGPoint(x: 30, y: 10))
    ], timestamp: timestamp)
}

private func touchFrame(_ contacts: [TouchContact], timestamp: TimeInterval) -> TouchFrame {
    TouchFrame(contacts: contacts, scanTime: 0, timestamp: timestamp)
}

private func touchContact(id: UInt8, point: CGPoint) -> TouchContact {
    TouchContact(
        id: id,
        x: UInt16(point.x),
        y: UInt16(point.y),
        width: 20,
        isTouching: true
    )
}

private func mapTouchContact(_ contact: TouchContact) -> CGPoint? {
    CGPoint(x: CGFloat(contact.x), y: CGFloat(contact.y))
}
