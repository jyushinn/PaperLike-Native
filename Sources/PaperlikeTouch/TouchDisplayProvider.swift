import AppKit
import CoreGraphics
import Foundation

public struct TouchDisplay: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let bounds: CGRect
    public let stableID: String?
    public let rotation: Int

    public init(id: CGDirectDisplayID, name: String, bounds: CGRect, stableID: String? = nil, rotation: Int = 0) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.stableID = stableID
        self.rotation = rotation
    }
}

@MainActor
public protocol TouchDisplayProviding: AnyObject {
    var displaysDidChange: (() -> Void)? { get set }
    func displays() -> [TouchDisplay]
    func startObserving()
    func stopObserving()
    func invalidateCache()
}

public extension TouchDisplayProviding {
    func invalidateCache() {}
}

@MainActor
public final class TouchDisplayProvider: TouchDisplayProviding {
    public var displaysDidChange: (() -> Void)?

    private var observer: NSObjectProtocol?
    private var cachedDisplays: [TouchDisplay]?

    public init() {}

    public func invalidateCache() {
        cachedDisplays = nil
    }

    public func displays() -> [TouchDisplay] {
        if let cachedDisplays { return cachedDisplays }
        let displays = NSScreen.screens.compactMap { screen -> TouchDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return TouchDisplay(
                id: displayID,
                name: screen.localizedName,
                bounds: CGDisplayBounds(displayID),
                stableID: CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String },
                rotation: Int(CGDisplayRotation(displayID))
            )
        }
        cachedDisplays = displays
        return displays
    }

    public func startObserving() {
        guard observer == nil else {
            return
        }
        cachedDisplays = nil
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cachedDisplays = nil
                self?.displaysDidChange?()
            }
        }
    }

    public func stopObserving() {
        guard let observer else {
            return
        }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
