import PaperlikeLocalization
import Combine
import CoreGraphics
import Foundation

public enum TouchMappingStatus: Equatable, Sendable {
    case stopped
    case disabled
    case accessibilityRequired
    case deviceUnavailable
    case displaySelectionRequired
    case ready
    case testing
    case error(String)
}

public enum TouchCalibrationSource: Equatable, Sendable {
    case manual
    case automaticHID
    case automaticFallback
}

@MainActor
public final class TouchMappingService: ObservableObject {
    @Published public private(set) var status: TouchMappingStatus = .stopped
    @Published public private(set) var latestFrame: TouchFrame?
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isTesting = false
    @Published public private(set) var targetDisplay: TouchDisplay?
    @Published public private(set) var availableDisplays: [TouchDisplay] = []
    @Published public private(set) var isTouchDeviceConnected = false
    @Published public private(set) var isAccessibilityTrusted = false
    @Published public private(set) var settings: TouchMappingSettings
    public private(set) var isDiagnosticsEnabled = false
    public private(set) var recoveredCorruptSettings = false
    public var touchDiagnostics: TouchDiagnosticsSnapshot {
        var diag = interpreter.latestDiagnostics
        let velocity = inertiaEngine.currentVelocity
        diag.isInertiaActive = inertiaEngine.isRunning
        diag.inertiaVelocity = velocity
        if inertiaEngine.isRunning {
            diag.gestureState = L("物理惯性滑行中")
            diag.speed = hypot(velocity.x, velocity.y)
            diag.lastAction = String(format: L("惯性滑行 (Vx: %+.1f, Vy: %+.1f)"), velocity.x, velocity.y)
        }
        return diag
    }
    public let touchDiagnosticsSubject = PassthroughSubject<TouchDiagnosticsSnapshot, Never>()

    public var calibrationSource: TouchCalibrationSource {
        if let stableID = targetDisplay?.stableID,
           settings.calibrationByDisplay[stableID] != nil { return .manual }
        if settings.isManualCalibration && (targetDisplay?.stableID == nil || settings.calibrationByDisplay.isEmpty) { return .manual }
        return validatedHIDBounds == nil ? .automaticFallback : .automaticHID
    }

    public var effectiveCalibration: TouchCalibration {
        if let stableID = targetDisplay?.stableID,
           let manual = settings.calibrationByDisplay[stableID] { return manual }
        if settings.isManualCalibration && (targetDisplay?.stableID == nil || settings.calibrationByDisplay.isEmpty) { return settings.calibration }
        return validatedHIDBounds ?? .default
    }

    private let inputSource: any TouchInputSource
    private let eventPoster: any TouchEventPosting
    private let displayProvider: any TouchDisplayProviding
    private let accessibility: any AccessibilityChecking
    private let settingsStore: TouchSettingsStore
    private let decoder: TouchReportDecoder
    private let interpreter: TouchGestureInterpreter
    private let inertiaEngine = TouchInertiaEngine()
    private let cursorManager: TouchCursorManager

    private var isRunning = false
    private var isPaused = false
    private var wasProcessing = false
    private var callbackGeneration: UInt64 = 0
    private var diagnosticsTimer: Timer?

    private var validatedHIDBounds: TouchCalibration? {
        guard let bounds = inputSource.coordinateBounds,
              bounds.minX >= 0, bounds.minY >= 0,
              bounds.maxX <= Double(UInt16.max), bounds.maxY <= Double(UInt16.max) else { return nil }
        return TouchCalibration.hidLogicalBounds(
            minX: Int(bounds.minX), maxX: Int(bounds.maxX),
            minY: Int(bounds.minY), maxY: Int(bounds.maxY)
        )
    }

    public convenience init() {
        self.init(
            inputSource: TouchHIDService(),
            eventPoster: TouchEventPoster(),
            displayProvider: TouchDisplayProvider(),
            accessibility: TouchAccessibilityChecker(),
            settingsStore: TouchSettingsStore()
        )
    }

    public init(
        inputSource: any TouchInputSource,
        eventPoster: any TouchEventPosting,
        displayProvider: any TouchDisplayProviding,
        accessibility: any AccessibilityChecking,
        settingsStore: TouchSettingsStore,
        decoder: TouchReportDecoder = TouchReportDecoder(),
        interpreter: TouchGestureInterpreter = TouchGestureInterpreter(),
        cursorManager: TouchCursorManager = TouchCursorManager.shared
    ) {
        self.inputSource = inputSource
        self.eventPoster = eventPoster
        self.displayProvider = displayProvider
        self.accessibility = accessibility
        self.settingsStore = settingsStore
        self.decoder = decoder
        self.interpreter = interpreter
        self.cursorManager = cursorManager
        let loadedSettings = settingsStore.load()
        recoveredCorruptSettings = settingsStore.recoveredCorruptData
        settings = loadedSettings
        isEnabled = loadedSettings.isEnabled

        cursorManager.isEnabled = loadedSettings.isCursorHiddenOnTouch
        inertiaEngine.friction = CGFloat(loadedSettings.inertiaFriction)
        interpreter.configuration = TouchGestureConfiguration(
            isNaturalScrolling: loadedSettings.isNaturalScrolling,
            scrollSpeed: loadedSettings.scrollSpeed,
            isInertialScrollEnabled: loadedSettings.isInertialScrollEnabled,
            isPinchToZoomEnabled: loadedSettings.isPinchToZoomEnabled,
            isTwoFingerRightClickEnabled: loadedSettings.isTwoFingerRightClickEnabled,
            isSingleFingerScrollEnabled: loadedSettings.isSingleFingerScrollEnabled,
            inertiaFriction: loadedSettings.inertiaFriction
        )
        interpreter.onInertiaTriggered = { [weak self] vx, vy, target in
            guard let self, self.wasProcessing else { return }
            self.inertiaEngine.start(vx: vx, vy: vy) { [weak self] dx, dy in
                guard let self, self.wasProcessing else { return }
                self.eventPoster.post(.scroll(deltaX: dx, deltaY: dy, at: target))
            }
        }
    }

    public func start() {
        guard !isRunning else {
            refreshState()
            return
        }
        isRunning = true
        isPaused = false
        callbackGeneration &+= 1
        let generation = callbackGeneration
        inputSource.eventHandler = { [weak self] event in
            guard let self, self.callbackGeneration == generation else {
                return
            }
            self.handle(event)
        }
        displayProvider.displaysDidChange = { [weak self] in
            guard let self, self.callbackGeneration == generation else {
                return
            }
            self.refreshState()
        }
        displayProvider.startObserving()
        inputSource.start()
        refreshState()
    }

    public func setEnabled(_ enabled: Bool) {
        let replacement = settings.updating(isEnabled: enabled)
        guard persistSettings(replacement) else {
            if !enabled {
                pause()
                status = .error(settingsStore.saveError ?? L("触控设置未保存。"))
            }
            return
        }
        if !enabled {
            cancelInterpreter()
            wasProcessing = false
        }
        isEnabled = enabled
        settings = replacement
        refreshState()
    }

    public func setTesting(_ testing: Bool) {
        if testing && !isTesting {
            latestFrame = nil
        }
        if testing && wasProcessing {
            cancelInterpreter()
            wasProcessing = false
        }
        isTesting = testing
        refreshState()
    }

    public func setDiagnosticsEnabled(_ enabled: Bool) {
        guard isDiagnosticsEnabled != enabled else { return }
        isDiagnosticsEnabled = enabled
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        guard enabled else { return }
        touchDiagnosticsSubject.send(touchDiagnostics)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDiagnosticsEnabled else { return }
                self.touchDiagnosticsSubject.send(self.touchDiagnostics)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    public func setDisplaySelection(_ selection: TouchDisplaySelection) {
        let resolvedSelection: TouchDisplaySelection
        if case let .display(id) = selection,
           let display = availableDisplays.first(where: { $0.id == id }),
           let stableID = display.stableID {
            resolvedSelection = .stable(stableID)
        } else {
            resolvedSelection = selection
        }
        let replacement = settings.updating(displaySelection: resolvedSelection)
        guard persistSettings(replacement) else { return }
        if settings.displaySelection != resolvedSelection {
            cancelInterpreter()
            wasProcessing = false
        }
        settings = replacement
        refreshState()
    }

    public func setCalibration(_ calibration: TouchCalibration) {
        var byDisplay = settings.calibrationByDisplay
        if let stableID = targetDisplay?.stableID { byDisplay[stableID] = calibration }
        let replacement = settings.updating(
            calibration: calibration,
            calibrationByDisplay: byDisplay,
            isManualCalibration: targetDisplay?.stableID == nil
        )
        guard persistSettings(replacement) else { return }
        cancelInterpreter()
        wasProcessing = false
        settings = replacement
        refreshState()
    }

    public func useAutomaticCalibration() {
        guard let targetDisplay else { return }
        var byDisplay = settings.calibrationByDisplay
        if let stableID = targetDisplay.stableID { byDisplay.removeValue(forKey: stableID) }
        let replacement = settings.updating(
            calibration: .default,
            calibrationByDisplay: byDisplay,
            isManualCalibration: false
        )
        guard persistSettings(replacement) else { return }
        cancelInterpreter()
        wasProcessing = false
        settings = replacement
        refreshState()
    }

    public func updateGestureSettings(
        isNaturalScrolling: Bool? = nil,
        scrollSpeed: Double? = nil,
        isInertialScrollEnabled: Bool? = nil,
        inertiaFriction: Double? = nil,
        isPinchToZoomEnabled: Bool? = nil,
        isTwoFingerRightClickEnabled: Bool? = nil,
        isSingleFingerScrollEnabled: Bool? = nil,
        isCursorHiddenOnTouch: Bool? = nil
    ) {
        let updated = settings.updating(
            isNaturalScrolling: isNaturalScrolling,
            scrollSpeed: scrollSpeed,
            isInertialScrollEnabled: isInertialScrollEnabled,
            inertiaFriction: inertiaFriction,
            isPinchToZoomEnabled: isPinchToZoomEnabled,
            isTwoFingerRightClickEnabled: isTwoFingerRightClickEnabled,
            isSingleFingerScrollEnabled: isSingleFingerScrollEnabled,
            isCursorHiddenOnTouch: isCursorHiddenOnTouch
        )
        applySettings(updated)
    }

    @discardableResult
    public func applySettings(_ replacement: TouchMappingSettings) -> Bool {
        guard persistSettings(replacement) else { return false }
        cancelInterpreter()
        wasProcessing = false
        settings = replacement
        isEnabled = replacement.isEnabled
        isTesting = false
        cursorManager.isEnabled = replacement.isCursorHiddenOnTouch
        inertiaEngine.friction = CGFloat(replacement.inertiaFriction)
        interpreter.configuration = TouchGestureConfiguration(
            isNaturalScrolling: replacement.isNaturalScrolling,
            scrollSpeed: replacement.scrollSpeed,
            isInertialScrollEnabled: replacement.isInertialScrollEnabled,
            isPinchToZoomEnabled: replacement.isPinchToZoomEnabled,
            isTwoFingerRightClickEnabled: replacement.isTwoFingerRightClickEnabled,
            isSingleFingerScrollEnabled: replacement.isSingleFingerScrollEnabled,
            inertiaFriction: replacement.inertiaFriction
        )
        refreshState()
        return true
    }

    private func persistSettings(_ replacement: TouchMappingSettings) -> Bool {
        guard settingsStore.save(replacement) else {
            status = .error(settingsStore.saveError ?? L("触控设置未保存。"))
            return false
        }
        return true
    }

    public func requestAccessibility() {
        _ = accessibility.requestTrustPrompt()
        refreshState()
    }

    public func refresh() {
        displayProvider.invalidateCache()
        if isRunning && !isPaused && !inputSource.isConnected {
            inputSource.start()
        }
        refreshState()
    }

    public func pause() {
        cancelInterpreter()
        wasProcessing = false
        isPaused = true
        isRunning = false
        callbackGeneration &+= 1
        inputSource.eventHandler = nil
        displayProvider.displaysDidChange = nil
        inputSource.stop()
        displayProvider.stopObserving()
        status = .stopped
    }

    public func restoreDefaults() {
        applySettings(.default)
    }

    public func shutdown() {
        cancelInterpreter()
        wasProcessing = false
        isPaused = true
        isRunning = false
        isTesting = false
        callbackGeneration &+= 1
        inputSource.eventHandler = nil
        displayProvider.displaysDidChange = nil
        inputSource.stop()
        displayProvider.stopObserving()
        targetDisplay = nil
        status = .stopped
    }

    isolated deinit {
        diagnosticsTimer?.invalidate()
        cancelInterpreter()
        inputSource.eventHandler = nil
        displayProvider.displaysDidChange = nil
        inputSource.stop()
        displayProvider.stopObserving()
    }

    private func handle(_ event: TouchInputEvent) {
        switch event {
        case .connected, .disconnected:
            refreshState()
        case let .report(bytes, timestamp):
            handleReport(bytes, timestamp: timestamp)
        case let .failure(message):
            print("[TouchMappingService] HID input event failure: \(message)")
            cancelInterpreter()
            wasProcessing = false
            status = .error(message)
        }
    }

    private func handleReport(_ bytes: [UInt8], timestamp: TimeInterval) {
        // Recheck a missed connection transition without putting AX/display queries on every report.
        if isTouchDeviceConnected != inputSource.isConnected { refreshState() }
        let shouldDecode = isRunning
            && !isPaused
            && inputSource.isConnected
            && (isTesting || isEnabled)
        guard shouldDecode else {
            return
        }

        do {
            let coordinateMaximum = UInt16(validatedHIDBounds.map { max($0.maxX, $0.maxY) } ?? Double(TouchDeviceDescriptor.paperLike13KColor.coordinateMaximum))
            let frame = try decoder.decode(bytes, timestamp: timestamp, coordinateMaximum: coordinateMaximum)
            if case .error = status { refreshState(checkAccessibility: false) }
            if frame.contacts.contains(where: \.isTouching) {
                inertiaEngine.stop()
                if wasProcessing && settings.isCursorHiddenOnTouch {
                    cursorManager.hideCursor()
                }
            }
            if isTesting { latestFrame = frame }
            let mappedDisplay = TouchTargetDisplay(
                bounds: targetDisplay?.bounds ?? .zero,
                rotation: calibrationSource == .manual ? 0 : (targetDisplay?.rotation ?? 0)
            )
            let calibration = effectiveCalibration
            if wasProcessing, targetDisplay != nil {
                let events = interpreter.consume(frame) { contact in
                    TouchCoordinateMapper.map(
                        contact,
                        calibration: calibration,
                        display: mappedDisplay
                    )
                }
                events.forEach(eventPoster.post)
            } else {
                interpreter.inspectDiagnostics(frame) { contact in
                    TouchCoordinateMapper.map(
                        contact,
                        calibration: calibration,
                        display: mappedDisplay
                    )
                }
            }
        } catch {
            print("[TouchMappingService] Decode/Map report error: \(error)")
            cancelInterpreter()
            wasProcessing = false
            status = .error(String(describing: error))
        }
    }

    private func refreshState(checkAccessibility: Bool = true) {
        let displays = displayProvider.displays()
        if case let .display(id) = settings.displaySelection {
            let matches = displays.filter { $0.id == id }
            if matches.count == 1, let stableID = matches[0].stableID {
                var byDisplay = settings.calibrationByDisplay
                if settings.isManualCalibration { byDisplay[stableID] = settings.calibration }
                let replacement = settings.updating(
                    displaySelection: .stable(stableID),
                    calibrationByDisplay: byDisplay,
                    isManualCalibration: false
                )
                if persistSettings(replacement) { settings = replacement }
            }
        }
        if availableDisplays != displays { availableDisplays = displays }
        if isTouchDeviceConnected != inputSource.isConnected {
            isTouchDeviceConnected = inputSource.isConnected
        }
        let trusted = checkAccessibility ? accessibility.checkIsTrusted() : isAccessibilityTrusted
        if isAccessibilityTrusted != trusted { isAccessibilityTrusted = trusted }
        let resolvedDisplay = resolveDisplay(
            selection: settings.displaySelection,
            displays: displays
        )
        let shouldProcess = isRunning
            && !isPaused
            && isEnabled
            && !isTesting
            && isAccessibilityTrusted
            && inputSource.isConnected
            && resolvedDisplay != nil
        let targetChanged = targetDisplay != resolvedDisplay

        if wasProcessing && (!shouldProcess || targetChanged) {
            cancelInterpreter()
        }

        if targetChanged { targetDisplay = resolvedDisplay }
        wasProcessing = shouldProcess
        let newStatus: TouchMappingStatus
        if let error = settingsStore.saveError {
            newStatus = .error(error)
        } else if !isRunning || isPaused {
            newStatus = .stopped
        } else if !inputSource.isConnected {
            newStatus = .deviceUnavailable
        } else if isTesting {
            newStatus = .testing
        } else if !isEnabled {
            newStatus = .disabled
        } else if !isAccessibilityTrusted {
            newStatus = .accessibilityRequired
        } else if resolvedDisplay == nil {
            newStatus = .displaySelectionRequired
        } else {
            newStatus = .ready
        }
        if status != newStatus { status = newStatus }
    }

    private func resolveDisplay(
        selection: TouchDisplaySelection,
        displays: [TouchDisplay]
    ) -> TouchDisplay? {
        switch selection {
        case .automatic:
            let candidates = displays.filter { display in
                let normalized = normalizedDisplayName(display.name)
                return normalized.contains("paperlike") || normalized.contains("dasung")
            }
            if candidates.count == 1 {
                return candidates[0]
            }
            if candidates.count > 1 {
                let specific = candidates.filter {
                    let normalized = normalizedDisplayName($0.name)
                    return normalized.contains("paperlike13k") || normalized.contains("paperlike133k")
                }
                if specific.count == 1 {
                    return specific[0]
                }
            }
            return nil
        case let .display(displayID):
            let matches = displays.filter { $0.id == displayID }
            return matches.count == 1 ? matches[0] : nil
        case let .stable(stableID):
            let matches = displays.filter { $0.stableID == stableID }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func normalizedDisplayName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
        .lowercased()
    }

    private func cancelInterpreter() {
        inertiaEngine.stop()
        cursorManager.showCursor()
        interpreter.cancel().forEach(eventPoster.post)
    }
}
