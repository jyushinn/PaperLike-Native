@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class TouchCursorManager {
    public static let shared = TouchCursorManager()
    public static let touchEventUserData: Int64 = 0x5041504552 // "PAPER"

    public var isEnabled: Bool = true {
        didSet {
            if !isEnabled && isCursorHidden {
                showCursor()
            }
        }
    }

    public private(set) var isCursorHidden: Bool = false
    private var globalMonitor: Any?

    public init() {
        setupMonitor()
    }

    private func setupMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isCursorHidden else { return }
                let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
                if userData != Self.touchEventUserData {
                    self.showCursor()
                }
            }
        }
    }

    public func hideCursor() {
        guard isEnabled, !isCursorHidden else { return }
        CGDisplayHideCursor(kCGNullDirectDisplay)
        isCursorHidden = true
    }

    public func showCursor() {
        guard isCursorHidden else { return }
        CGDisplayShowCursor(kCGNullDirectDisplay)
        isCursorHidden = false
    }

    isolated deinit {
        if isCursorHidden {
            CGDisplayShowCursor(kCGNullDirectDisplay)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}
