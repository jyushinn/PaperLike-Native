import CoreGraphics
import Foundation

@MainActor
public final class TouchInertiaEngine {
    private var timer: Timer?
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    public var friction: CGFloat = 0.92
    private var postHandler: ((CGFloat, CGFloat) -> Void)?
    private let clock: () -> TimeInterval
    private var lastTickTime: TimeInterval = 0

    public private(set) var isRunning: Bool = false
    public var currentVelocity: CGPoint { CGPoint(x: velocityX, y: velocityY) }
    public var onUpdate: ((Bool, CGPoint) -> Void)?

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    public func start(vx: CGFloat, vy: CGFloat, post: @escaping (CGFloat, CGFloat) -> Void) {
        stop()
        velocityX = vx
        velocityY = vy
        lastTickTime = clock()
        isRunning = true
        postHandler = post
        onUpdate?(true, currentVelocity)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        guard isRunning || timer != nil else { return }
        timer?.invalidate()
        timer = nil
        velocityX = 0
        velocityY = 0
        isRunning = false
        postHandler = nil
        onUpdate?(false, .zero)
    }

    private func tick() {
        let now = clock()
        let elapsed = now - lastTickTime
        guard elapsed.isFinite, elapsed > 0 else { return }
        lastTickTime = now
        guard friction.isFinite, friction > 0, friction <= 1 else { stop(); return }
        let frames = CGFloat(elapsed * 60)
        let decay = pow(friction, frames)
        // Integrate the nominal 60Hz decay so a delayed tick preserves both time and distance.
        let distanceScale = friction == 1 ? frames : friction * (1 - decay) / (1 - friction)
        let deltaX = velocityX * distanceScale
        let deltaY = velocityY * distanceScale
        velocityX *= decay
        velocityY *= decay
        if abs(velocityX) < 0.3 && abs(velocityY) < 0.3 {
            postHandler?(deltaX, deltaY)
            stop()
            return
        }
        onUpdate?(true, currentVelocity)
        postHandler?(deltaX, deltaY)
    }

    isolated deinit {
        timer?.invalidate()
    }
}
