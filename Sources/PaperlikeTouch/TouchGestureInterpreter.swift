import CoreGraphics
import Foundation

public enum TouchOutputEvent: Equatable, Sendable {
    case move(CGPoint)
    case leftDown(CGPoint)
    case leftDragged(CGPoint)
    case leftUp(CGPoint)
    case rightDown(CGPoint)
    case rightUp(CGPoint)
    case scroll(deltaX: CGFloat, deltaY: CGFloat, at: CGPoint)
    case zoom(delta: CGFloat, at: CGPoint)
    case zoomEnded
}

public struct TouchGestureConfiguration: Equatable, Sendable {
    public var isNaturalScrolling: Bool
    public var scrollSpeed: Double
    public var isInertialScrollEnabled: Bool
    public var isPinchToZoomEnabled: Bool
    public var isTwoFingerRightClickEnabled: Bool
    public var isSingleFingerScrollEnabled: Bool
    public var inertiaFriction: Double

    public init(
        isNaturalScrolling: Bool = true,
        scrollSpeed: Double = 1.0,
        isInertialScrollEnabled: Bool = true,
        isPinchToZoomEnabled: Bool = true,
        isTwoFingerRightClickEnabled: Bool = true,
        isSingleFingerScrollEnabled: Bool = true,
        inertiaFriction: Double = 0.92
    ) {
        self.isNaturalScrolling = isNaturalScrolling
        self.scrollSpeed = scrollSpeed
        self.isInertialScrollEnabled = isInertialScrollEnabled
        self.isPinchToZoomEnabled = isPinchToZoomEnabled
        self.isTwoFingerRightClickEnabled = isTwoFingerRightClickEnabled
        self.isSingleFingerScrollEnabled = isSingleFingerScrollEnabled
        self.inertiaFriction = inertiaFriction
    }
}

public final class TouchGestureInterpreter {
    private enum State {
        case idle
        case oneFingerPending(primaryID: UInt8, start: CGPoint, last: CGPoint, startedAt: TimeInterval)
        case dragging(primaryID: UInt8, last: CGPoint)
        case twoFingerPending(start: CGPoint, last: CGPoint, initialDistance: CGFloat, lastDistance: CGFloat, lastContacts: [MappedContact], startedAt: TimeInterval)
        case scrolling(last: CGPoint, lastDistance: CGFloat?, velocity: CGPoint, lastTimestamp: TimeInterval, target: CGPoint)
        case pinching(lastDistance: CGFloat, centroid: CGPoint)
        case ignoredUntilClear
    }

    private struct MappedContact {
        let id: UInt8
        let point: CGPoint
        let rawContact: TouchContact
    }

    private enum Input {
        case none
        case one(MappedContact)
        case two(centroid: CGPoint, contacts: [MappedContact])
        case ignored([MappedContact])
    }

    public var configuration: TouchGestureConfiguration
    public var onInertiaTriggered: ((CGFloat, CGFloat, CGPoint) -> Void)?
    private var diagnosticsSnapshot = TouchDiagnosticsSnapshot()
    private var diagnosticsFrame: TouchFrame?
    private var diagnosticsInput: Input?
    private var lastOutputEvent: TouchOutputEvent?
    public var latestDiagnostics: TouchDiagnosticsSnapshot {
        if let frame = diagnosticsFrame, let input = diagnosticsInput {
            updateDiagnostics(from: frame, input: input, events: lastOutputEvent.map { [$0] } ?? [])
        }
        return diagnosticsSnapshot
    }

    private let clickDuration: TimeInterval = 0.35
    private let dragHoldDuration: TimeInterval = 0.40
    private let dragDistance: CGFloat = 8
    private let scrollDistance: CGFloat = 5
    private var state = State.idle

    public init(configuration: TouchGestureConfiguration = TouchGestureConfiguration()) {
        self.configuration = configuration
    }

    public func consume(
        _ frame: TouchFrame,
        map: (TouchContact) -> CGPoint?
    ) -> [TouchOutputEvent] {
        let input = makeInput(from: frame.contacts, map: map)
        let events = processInput(input, frame: frame)
        diagnosticsFrame = frame
        diagnosticsInput = input
        if let event = events.last { lastOutputEvent = event }
        return events
    }

    public func inspectDiagnostics(
        _ frame: TouchFrame,
        map: (TouchContact) -> CGPoint?
    ) {
        let input = makeInput(from: frame.contacts, map: map)
        diagnosticsFrame = frame
        diagnosticsInput = input
    }

    private func processInput(_ input: Input, frame: TouchFrame) -> [TouchOutputEvent] {
        switch (state, input) {
        case (.idle, .none):
            return []
        case (.idle, .one(let contact)):
            state = .oneFingerPending(
                primaryID: contact.id,
                start: contact.point,
                last: contact.point,
                startedAt: frame.timestamp
            )
            return [.move(contact.point)]
        case (.idle, .two(let point, let contacts)):
            let dist = distance(from: contacts[0].point, to: contacts[1].point)
            state = .twoFingerPending(start: point, last: point, initialDistance: dist, lastDistance: dist, lastContacts: contacts, startedAt: frame.timestamp)
            return []
        case (.idle, .ignored):
            state = .ignoredUntilClear
            return []

        case (.oneFingerPending(_, let start, let last, let startedAt), .none):
            state = .idle
            guard frame.timestamp - startedAt <= clickDuration,
                  distance(from: start, to: last) <= dragDistance else {
                return []
            }
            return [.leftDown(last), .leftUp(last)]
        case (.oneFingerPending(let primaryID, let start, _, let startedAt), .one(let contact)):
            guard contact.id == primaryID else {
                state = .ignoredUntilClear
                return []
            }
            let dist = distance(from: start, to: contact.point)
            let duration = frame.timestamp - startedAt

            if configuration.isSingleFingerScrollEnabled {
                // If held in place for >= dragHoldDuration (0.40s) without moving: LONG PRESS -> dragging / text selection!
                if duration >= dragHoldDuration && dist <= dragDistance {
                    state = .dragging(primaryID: primaryID, last: contact.point)
                    return [.leftDown(contact.point), .leftDragged(contact.point)]
                }
                // If moved beyond threshold before long-press: SCROLL!
                if dist > scrollDistance {
                    let sign: CGFloat = configuration.isNaturalScrolling ? 1.0 : -1.0
                    let speed = CGFloat(configuration.scrollSpeed)
                    let deltaX = (contact.point.x - start.x) * sign * speed
                    let deltaY = (contact.point.y - start.y) * sign * speed
                    state = .scrolling(
                        last: contact.point,
                        lastDistance: nil,
                        velocity: scrollVelocity(deltaX: deltaX, deltaY: deltaY, elapsed: frame.timestamp - startedAt),
                        lastTimestamp: frame.timestamp, target: start
                    )
                    return [.scroll(deltaX: deltaX, deltaY: deltaY, at: start)]
                }
                state = .oneFingerPending(
                    primaryID: primaryID,
                    start: start,
                    last: contact.point,
                    startedAt: startedAt
                )
                return []
            } else {
                if dist > dragDistance || duration >= dragHoldDuration {
                    state = .dragging(primaryID: primaryID, last: contact.point)
                    return [.leftDown(contact.point), .leftDragged(contact.point)]
                }
                state = .oneFingerPending(
                    primaryID: primaryID,
                    start: start,
                    last: contact.point,
                    startedAt: startedAt
                )
                return [.move(contact.point)]
            }
        case (.oneFingerPending(_, _, _, _), .two(let point, let contacts)):
            let dist = distance(from: contacts[0].point, to: contacts[1].point)
            state = .twoFingerPending(start: point, last: point, initialDistance: dist, lastDistance: dist, lastContacts: contacts, startedAt: frame.timestamp)
            return []
        case (.oneFingerPending, .ignored):
            state = .ignoredUntilClear
            return []

        case (.dragging(_, let last), .none):
            state = .idle
            return [.leftUp(last)]
        case (.dragging(let primaryID, let last), .one(let contact)):
            guard contact.id == primaryID else {
                state = .ignoredUntilClear
                return [.leftUp(last)]
            }
            state = .dragging(primaryID: primaryID, last: contact.point)
            return [.leftDragged(contact.point)]
        case (.dragging(let primaryID, let last), .two(let point, let contacts)):
            let dist = distance(from: contacts[0].point, to: contacts[1].point)
            state = .twoFingerPending(start: point, last: point, initialDistance: dist, lastDistance: dist, lastContacts: contacts, startedAt: frame.timestamp)
            return [.leftUp(contacts.first { $0.id == primaryID }?.point ?? last)]
        case (.dragging(let primaryID, let last), .ignored(let contacts)):
            state = .ignoredUntilClear
            return [.leftUp(contacts.first { $0.id == primaryID }?.point ?? last)]

        case (.twoFingerPending(let start, let last, _, _, _, let startedAt), .none):
            state = .idle
            guard frame.timestamp - startedAt <= clickDuration,
                  distance(from: start, to: last) <= scrollDistance else {
                return []
            }
            guard configuration.isTwoFingerRightClickEnabled else { return [] }
            return [.rightDown(last), .rightUp(last)]
        case (.twoFingerPending(let start, let last, _, _, let contacts, let startedAt), .one(let contact)):
            state = .ignoredUntilClear
            guard configuration.isTwoFingerRightClickEnabled,
                  let previous = contacts.first(where: { $0.id == contact.id }),
                  distance(from: previous.point, to: contact.point) <= scrollDistance,
                  frame.timestamp - startedAt <= clickDuration,
                  distance(from: start, to: last) <= scrollDistance else { return [] }
            return [.rightDown(last), .rightUp(last)]
        case (.twoFingerPending(let start, _, let initialDistance, _, _, let startedAt), .two(let point, let contacts)):
            let currentDistance = distance(from: contacts[0].point, to: contacts[1].point)
            let distanceChange = currentDistance - initialDistance
            let absDistChange = abs(distanceChange)
            let centroidDistance = distance(from: start, to: point)

            if configuration.isPinchToZoomEnabled && absDistChange > 8 && absDistChange > centroidDistance * 0.7 {
                state = .pinching(lastDistance: currentDistance, centroid: point)
                return [.zoom(delta: distanceChange / 10, at: point)]
            } else if centroidDistance > scrollDistance {
                let sign: CGFloat = configuration.isNaturalScrolling ? 1.0 : -1.0
                let speed = CGFloat(configuration.scrollSpeed)
                let deltaX = (point.x - start.x) * sign * speed
                let deltaY = (point.y - start.y) * sign * speed
                state = .scrolling(last: point, lastDistance: currentDistance, velocity: scrollVelocity(deltaX: deltaX, deltaY: deltaY, elapsed: frame.timestamp - startedAt), lastTimestamp: frame.timestamp, target: start)
                return [.scroll(deltaX: deltaX, deltaY: deltaY, at: start)]
            } else {
                state = .twoFingerPending(start: start, last: point, initialDistance: initialDistance, lastDistance: currentDistance, lastContacts: contacts, startedAt: startedAt)
                return []
            }

        case (.scrolling(let last, let lastDistance, let velocity, let lastTimestamp, let target), .two(let point, let contacts)):
            let currentDistance = distance(from: contacts[0].point, to: contacts[1].point)
            guard let lastDistance else {
                state = .scrolling(last: point, lastDistance: currentDistance, velocity: .zero, lastTimestamp: frame.timestamp, target: target)
                return []
            }
            let distChange = currentDistance - lastDistance
            let absDistChange = abs(distChange)
            let centroidDelta = distance(from: last, to: point)

            if configuration.isPinchToZoomEnabled && absDistChange > 14 && absDistChange > centroidDelta * 1.2 {
                state = .pinching(lastDistance: currentDistance, centroid: point)
                return [.zoom(delta: distChange / 10, at: point)]
            }

            let sign: CGFloat = configuration.isNaturalScrolling ? 1.0 : -1.0
            let speed = CGFloat(configuration.scrollSpeed)
            let deltaX = (point.x - last.x) * sign * speed
            let deltaY = (point.y - last.y) * sign * speed
            let newVel = scrollVelocity(deltaX: deltaX, deltaY: deltaY, elapsed: frame.timestamp - lastTimestamp, previous: velocity)
            state = .scrolling(last: point, lastDistance: currentDistance, velocity: newVel, lastTimestamp: frame.timestamp, target: target)
            guard deltaX != 0 || deltaY != 0 else { return [] }
            return [.scroll(deltaX: deltaX, deltaY: deltaY, at: target)]

        case (.scrolling(_, let lastDistance, let velocity, _, let target), .one) where lastDistance != nil:
            // 2 fingers were scrolling, and 1 finger just lifted off!
            state = .ignoredUntilClear
            if configuration.isInertialScrollEnabled && hypot(velocity.x, velocity.y) > 0.8 {
                onInertiaTriggered?(velocity.x, velocity.y, target)
            }
            return []

        case (.scrolling(let last, _, let velocity, let lastTimestamp, let target), .one(let contact)):
            // Single finger continuous scrolling
            let sign: CGFloat = configuration.isNaturalScrolling ? 1.0 : -1.0
            let speed = CGFloat(configuration.scrollSpeed)
            let deltaX = (contact.point.x - last.x) * sign * speed
            let deltaY = (contact.point.y - last.y) * sign * speed
            let newVel = scrollVelocity(deltaX: deltaX, deltaY: deltaY, elapsed: frame.timestamp - lastTimestamp, previous: velocity)
            state = .scrolling(last: contact.point, lastDistance: nil, velocity: newVel, lastTimestamp: frame.timestamp, target: target)
            guard deltaX != 0 || deltaY != 0 else { return [] }
            return [.scroll(deltaX: deltaX, deltaY: deltaY, at: target)]

        case (.scrolling(_, _, let velocity, _, let target), .none):
            state = .idle
            if configuration.isInertialScrollEnabled && hypot(velocity.x, velocity.y) > 0.8 {
                onInertiaTriggered?(velocity.x, velocity.y, target)
            }
            return []

        case (.pinching(let lastDist, _), .two(let point, let contacts)):
            let currentDistance = distance(from: contacts[0].point, to: contacts[1].point)
            let step = currentDistance - lastDist
            state = .pinching(lastDistance: currentDistance, centroid: point)
            return step == 0 ? [] : [.zoom(delta: step / 10, at: point)]

        case (.pinching, .none):
            state = .idle
            return [.zoomEnded]

        case (.pinching, .one), (.pinching, .ignored):
            state = .ignoredUntilClear
            return [.zoomEnded]

        case (.twoFingerPending, _), (.scrolling, _):
            state = .ignoredUntilClear
            return []

        case (.ignoredUntilClear, .none):
            state = .idle
            return []
        case (.ignoredUntilClear, _):
            return []
        }
    }

    public func cancel() -> [TouchOutputEvent] {
        let events: [TouchOutputEvent]
        switch state {
        case .dragging(_, let point): events = [.leftUp(point)]
        case .pinching: events = [.zoomEnded]
        default: events = []
        }
        state = .idle
        diagnosticsFrame = TouchFrame(contacts: [], scanTime: 0, timestamp: diagnosticsFrame?.timestamp ?? 0)
        diagnosticsInput = Input.none
        if let event = events.last { lastOutputEvent = event }
        return events
    }

    private func makeInput(
        from contacts: [TouchContact],
        map: (TouchContact) -> CGPoint?
    ) -> Input {
        let activeContacts = contacts.filter(\.isTouching)
        let mappedContacts = activeContacts.compactMap { contact in
            map(contact).map { MappedContact(id: contact.id, point: $0, rawContact: contact) }
        }
        switch activeContacts.count {
        case 0:
            return .none
        case 1:
            guard let contact = mappedContacts.first else { return .ignored(mappedContacts) }
            return .one(contact)
        case 2:
            guard mappedContacts.count == 2 else {
                return .ignored(mappedContacts)
            }
            let first = mappedContacts[0].point
            let second = mappedContacts[1].point
            return .two(
                centroid: CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2),
                contacts: mappedContacts
            )
        default:
            return .ignored(mappedContacts)
        }
    }

    private func updateDiagnostics(from frame: TouchFrame, input: Input, events: [TouchOutputEvent]) {
        let activeContacts = frame.contacts.filter(\.isTouching)
        let contactDesc: String
        if activeContacts.isEmpty {
            contactDesc = "未检测到触点 (空闲)"
        } else {
            contactDesc = activeContacts.map { c in
                "#\(c.id): 原始坐标(\(c.x), \(c.y)) 触控面宽:\(c.width)"
            }.joined(separator: "\n")
        }

        let stateStr: String
        let twoDist: CGFloat
        let cent: CGPoint
        let vel: CGPoint

        switch state {
        case .idle:
            stateStr = "空闲"
            twoDist = 0
            cent = .zero
            vel = .zero
        case .oneFingerPending(_, _, let last, _):
            stateStr = "单指轻触预备"
            twoDist = 0
            cent = last
            vel = .zero
        case .dragging(_, let last):
            stateStr = "单指长按拖拽选中中"
            twoDist = 0
            cent = last
            vel = .zero
        case .twoFingerPending(let start, let last, _, let d, _, _):
            stateStr = "双指手势预备"
            twoDist = d
            cent = last
            vel = CGPoint(x: last.x - start.x, y: last.y - start.y)
        case .scrolling(let last, let d, let v, _, _):
            stateStr = d != nil ? "双指物理滚动中" : "单指物理滚动中"
            twoDist = d ?? 0
            cent = last
            vel = v
        case .pinching(let d, let c):
            stateStr = "双指捏合缩放中"
            twoDist = d
            cent = c
            vel = .zero
        case .ignoredUntilClear:
            stateStr = "等待所有手指离屏复位"
            twoDist = 0
            cent = .zero
            vel = .zero
        }

        var actionDesc = diagnosticsSnapshot.lastAction
        if let ev = events.last {
            switch ev {
            case .move(let pt):
                actionDesc = "移动 (\(Int(pt.x)), \(Int(pt.y)))"
            case .leftDown:
                actionDesc = "单指点击按下"
            case .leftDragged(let pt):
                actionDesc = "拖拽移动 (\(Int(pt.x)), \(Int(pt.y)))"
            case .leftUp:
                actionDesc = "单指抬起"
            case .rightDown:
                actionDesc = "双指右键触发"
            case .rightUp:
                actionDesc = "双指右键释放"
            case .scroll(let dx, let dy, _):
                actionDesc = String(format: "滚动 (dx: %+.1f, dy: %+.1f)", dx, dy)
            case .zoom(let d, _):
                actionDesc = String(format: "Command+滚轮缩放 (%@, tick: %+.1f)", d > 0 ? "放大" : "缩小", d)
            case .zoomEnded:
                actionDesc = "缩放手势结束"
            }
        }

        diagnosticsSnapshot = TouchDiagnosticsSnapshot(
            gestureState: stateStr,
            contactCount: activeContacts.count,
            contactsDescription: contactDesc,
            twoFingerDistance: twoDist,
            centroid: cent,
            velocity: vel,
            speed: hypot(vel.x, vel.y),
            isInertiaActive: diagnosticsSnapshot.isInertiaActive,
            inertiaVelocity: diagnosticsSnapshot.inertiaVelocity,
            lastAction: actionDesc
        )
    }

    // The inertia engine integrates velocities expressed in points per nominal 60 Hz frame.
    private func scrollVelocity(deltaX: CGFloat, deltaY: CGFloat, elapsed: TimeInterval, previous: CGPoint? = nil) -> CGPoint {
        guard elapsed.isFinite, elapsed > 0 else { return .zero }
        let frames = CGFloat(elapsed * 60)
        let current = CGPoint(x: deltaX / frames, y: deltaY / frames)
        guard current.x.isFinite, current.y.isFinite else { return .zero }
        guard let previous else { return current }
        let retention = pow(CGFloat(0.3), frames)
        return CGPoint(x: previous.x * retention + current.x * (1 - retention), y: previous.y * retention + current.y * (1 - retention))
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}
