@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import AppKit

@MainActor
public protocol TouchEventPosting: AnyObject {
    func post(_ event: TouchOutputEvent)
}

@MainActor
public protocol AccessibilityChecking: AnyObject {
    func checkIsTrusted() -> Bool
    func requestTrustPrompt() -> Bool
}

@MainActor
public final class TouchAccessibilityChecker: AccessibilityChecking {
    public init() {}

    public func checkIsTrusted() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func requestTrustPrompt() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
public final class TouchEventPoster: TouchEventPosting {
    private var lastClickTime: TimeInterval?
    private var lastClickPoint: CGPoint = .zero
    private var currentClickCount: Int64 = 1
    private let eventSink: (CGEvent) -> Void
    private let clock: () -> TimeInterval
    private let doubleClickInterval: () -> TimeInterval
    private var zoomRemainder: CGFloat = 0

    public init(
        eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        doubleClickInterval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval }
    ) {
        self.eventSink = eventSink
        self.clock = clock
        self.doubleClickInterval = doubleClickInterval
    }

    public func post(_ event: TouchOutputEvent) {
        let cgEvent: CGEvent?
        switch event {
        case let .move(point):
            cgEvent = mouseEvent(type: .mouseMoved, point: point, button: .left, clickCount: 0)
        case let .leftDown(point):
            let now = clock()
            let distance = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y)
            if let lastClickTime, now - lastClickTime >= 0,
               now - lastClickTime <= doubleClickInterval(), distance < 10 {
                currentClickCount = currentClickCount == 1 ? 2 : 1
            } else {
                currentClickCount = 1
            }
            lastClickTime = now
            lastClickPoint = point
            cgEvent = mouseEvent(type: .leftMouseDown, point: point, button: .left, clickCount: currentClickCount)
        case let .leftDragged(point):
            cgEvent = mouseEvent(type: .leftMouseDragged, point: point, button: .left, clickCount: currentClickCount)
        case let .leftUp(point):
            cgEvent = mouseEvent(type: .leftMouseUp, point: point, button: .left, clickCount: currentClickCount)
        case let .rightDown(point):
            cgEvent = mouseEvent(type: .rightMouseDown, point: point, button: .right, clickCount: 1)
        case let .rightUp(point):
            cgEvent = mouseEvent(type: .rightMouseUp, point: point, button: .right, clickCount: 1)
        case let .scroll(deltaX, deltaY, at):
            cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(deltaY.rounded())),
                wheel2: Int32(clamping: Int(deltaX.rounded())),
                wheel3: 0
            )
            cgEvent?.location = at
        case let .zoom(delta, at):
            // Command+Wheel is application-dependent zoom emulation, not a system magnify event.
            guard delta.isFinite else { return }
            zoomRemainder += delta
            guard zoomRemainder.isFinite else { zoomRemainder = 0; return }
            let integral = (zoomRemainder > 0 ? zoomRemainder.nextUp : zoomRemainder.nextDown).rounded(.towardZero)
            let wheel = Int32(max(CGFloat(Int32.min), min(CGFloat(Int32.max), integral)))
            guard wheel != 0 else { return }
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: wheel,
                wheel2: 0,
                wheel3: 0
            ) else { return }
            zoomRemainder -= CGFloat(wheel)
            event.location = at
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: TouchCursorManager.touchEventUserData)
            eventSink(event)
            return
        case .zoomEnded:
            zoomRemainder = 0
            return
        }
        cgEvent?.setIntegerValueField(.eventSourceUserData, value: TouchCursorManager.touchEventUserData)
        if let cgEvent { eventSink(cgEvent) }
    }

    private func mouseEvent(
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        clickCount: Int64 = 1
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return nil }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        return event
    }
}
