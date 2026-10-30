import PaperlikeLocalization
import Foundation

public struct LightingAutomationStatus: Equatable, Sendable {
    public let activeRule: LightingScheduleRule?
    public let nextBoundary: Date?
    public let isPaused: Bool
    public let isApplied: Bool
    public let failureMessage: String?

    public init(
        activeRule: LightingScheduleRule?,
        nextBoundary: Date?,
        isPaused: Bool,
        isApplied: Bool = false,
        failureMessage: String? = nil
    ) {
        self.activeRule = activeRule
        self.nextBoundary = nextBoundary
        self.isPaused = isPaused
        self.isApplied = isApplied
        self.failureMessage = failureMessage
    }

    public static let inactive = LightingAutomationStatus(
        activeRule: nil,
        nextBoundary: nil,
        isPaused: false
    )
}

public actor LightingAutomationService {
    public nonisolated let events: AsyncStream<LightingAutomationStatus>

    public typealias NowProvider = @Sendable () -> Date
    public typealias CalendarProvider = @Sendable () -> Calendar
    public typealias SleepUntil = @Sendable (Date) async throws -> Void
    public typealias Apply = @Sendable (LightingConfiguration) async throws ->
        Void

    public typealias CurrentConfigProvider = @Sendable () async -> LightingConfiguration?

    private let nowProvider: NowProvider
    private let calendarProvider: CalendarProvider
    private let sleepUntil: SleepUntil
    private let currentConfigProvider: CurrentConfigProvider
    private let apply: Apply
    private nonisolated let eventContinuation:
        AsyncStream<LightingAutomationStatus>.Continuation

    private var settings = LightingAutomationSettings()
    private var isConnected = false
    private var pauseUntil: Date?
    private var lastAppliedRuleID: UUID?
    private var preAutomationConfig: LightingConfiguration?
    private var status = LightingAutomationStatus.inactive
    private var waitTask: Task<Void, Never>?
    private var scheduledWake: Date?
    private var revision = 0
    private var isStopped = false
    private var isSuspended = false
    private var isEvaluating = false
    private var pendingEvaluation = false
    private var pendingApply = false
    private var pendingForce = false

    public init(
        now: @escaping NowProvider = { Date() },
        calendar: @escaping CalendarProvider = { Calendar.autoupdatingCurrent },
        sleepUntil: @escaping SleepUntil = { date in
            let duration = max(0, date.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(duration))
        },
        currentConfig: @escaping CurrentConfigProvider = { nil },
        apply: @escaping Apply
    ) {
        nowProvider = now
        calendarProvider = calendar
        self.sleepUntil = sleepUntil
        self.currentConfigProvider = currentConfig
        self.apply = apply
        let pair = AsyncStream<LightingAutomationStatus>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        pair.continuation.yield(.inactive)
    }

    deinit {
        waitTask?.cancel()
        eventContinuation.finish()
    }

    public func update(
        settings: LightingAutomationSettings,
        isConnected: Bool,
        applyImmediately: Bool
    ) async {
        revision += 1
        isStopped = false
        let changed = settings != self.settings
        self.settings = settings
        self.isConnected = isConnected
        if changed {
            if settings.isEnabled { lastAppliedRuleID = nil }
        }
        await reevaluate(
            applyImmediately: applyImmediately,
            forceApply: false
        )
    }

    public func connectionChanged(isConnected: Bool) async {
        guard isConnected != self.isConnected else {
            return
        }
        revision += 1
        let reconnected = isConnected && !self.isConnected
        self.isConnected = isConnected
        if reconnected {
            lastAppliedRuleID = nil
        }
        await reevaluate(
            applyImmediately: reconnected,
            forceApply: reconnected
        )
    }

    public func noteManualOverride() async {
        guard settings.isEnabled else {
            return
        }
        let decision = decision(at: nowProvider())
        // A manual adjustment must not shorten an explicit longer pause.
        await pause(until: max(pauseUntil ?? .distantPast, decision.nextBoundary ?? .distantFuture))
    }

    public func pause(until date: Date) async {
        revision += 1
        pauseUntil = date
        lastAppliedRuleID = nil
        preAutomationConfig = nil
        await reevaluate(applyImmediately: false, forceApply: false)
    }

    public func resume() async {
        revision += 1
        pauseUntil = nil
        lastAppliedRuleID = nil
        await reevaluate(applyImmediately: true, forceApply: true)
    }

    public func setSuspended(_ suspended: Bool) async {
        guard suspended != isSuspended else { return }
        revision += 1
        isSuspended = suspended
        lastAppliedRuleID = nil
        await reevaluate(applyImmediately: !suspended, forceApply: !suspended)
    }

    public func refreshNow(forceApply: Bool = false) async {
        await reevaluate(
            applyImmediately: true,
            forceApply: forceApply
        )
    }

    public func currentStatus() -> LightingAutomationStatus {
        status
    }

    public func stop() {
        revision += 1
        isStopped = true
        waitTask?.cancel()
        waitTask = nil
        scheduledWake = nil
        publish(.inactive)
    }

    private func reevaluate(
        applyImmediately: Bool,
        forceApply: Bool
    ) async {
        pendingEvaluation = true
        pendingApply = pendingApply || applyImmediately
        pendingForce = pendingForce || forceApply
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        while pendingEvaluation {
            let apply = pendingApply
            let force = pendingForce
            pendingEvaluation = false
            pendingApply = false
            pendingForce = false
            await evaluateOnce(applyImmediately: apply, forceApply: force)
        }
    }

    private func evaluateOnce(applyImmediately: Bool, forceApply: Bool) async {
        waitTask?.cancel()
        waitTask = nil
        let evaluationRevision = revision

        guard !isStopped else {
            publish(.inactive)
            return
        }

        if isSuspended {
            publish(LightingAutomationStatus(activeRule: nil, nextBoundary: nil, isPaused: true))
            return
        }

        guard settings.isEnabled else {
            publish(.inactive)
            if preAutomationConfig != nil && (!isConnected || !applyImmediately) { return }
            if let restoreConfig = preAutomationConfig {
                do {
                    try await apply(restoreConfig)
                } catch {
                    guard evaluationRevision == revision else { return }
                    publish(LightingAutomationStatus(activeRule: nil, nextBoundary: nil, isPaused: false,
                        failureMessage: L("恢复前光未完成，30 秒后重试。")))
                    scheduleBoundary(nil, retry: true)
                    return
                }
            }
            guard evaluationRevision == revision else { return }
            preAutomationConfig = nil
            lastAppliedRuleID = nil
            return
        }

        let current = nowProvider()
        if let pauseUntil, current >= pauseUntil {
            self.pauseUntil = nil
        }
        let decision = decision(at: current)
        let isPaused = pauseUntil.map { current < $0 } ?? false
        publish(LightingAutomationStatus(
            activeRule: decision.activeRule,
            nextBoundary: decision.nextBoundary,
            isPaused: isPaused,
            isApplied: isConnected && !isPaused && decision.activeRule?.id == lastAppliedRuleID && lastAppliedRuleID != nil
        ))

        if isConnected,
           applyImmediately,
           !isPaused,
           let rule = decision.activeRule,
           forceApply || rule.id != lastAppliedRuleID {

            if lastAppliedRuleID == nil && preAutomationConfig == nil {
                let original = await currentConfigProvider()
                guard evaluationRevision == revision, !isStopped else { return }
                preAutomationConfig = original
            }
            guard evaluationRevision == revision, !isStopped else { return }

            let succeeded: Bool
            var failure: String?
            do {
                try await apply(rule.configuration)
                succeeded = true
            } catch {
                succeeded = false
                failure = L("执行未完成，部分设置可能已生效；30 秒后重试。")
            }
            guard evaluationRevision == revision else {
                await reevaluate(
                    applyImmediately: true,
                    forceApply: false
                )
                return
            }
            if succeeded {
                lastAppliedRuleID = rule.id
            } else {
                lastAppliedRuleID = nil
            }
            publish(LightingAutomationStatus(
                activeRule: rule,
                nextBoundary: decision.nextBoundary,
                isPaused: false,
                isApplied: succeeded,
                failureMessage: failure
            ))
            if !succeeded {
                scheduleBoundary(decision.nextBoundary, retry: true)
                return
            }
        } else if decision.activeRule == nil || isPaused {
            if preAutomationConfig != nil && (!isConnected || !applyImmediately) {
                scheduleBoundary(decision.nextBoundary)
                return
            }
            if let restoreConfig = preAutomationConfig {
                do {
                    try await apply(restoreConfig)
                } catch {
                    guard evaluationRevision == revision else { return }
                    publish(LightingAutomationStatus(activeRule: nil, nextBoundary: decision.nextBoundary,
                        isPaused: isPaused, failureMessage: L("恢复前光未完成，30 秒后重试。")))
                    scheduleBoundary(decision.nextBoundary, retry: true)
                    return
                }
            }
            guard evaluationRevision == revision else { return }
            preAutomationConfig = nil
            lastAppliedRuleID = nil
        }

        scheduleBoundary(decision.nextBoundary)
    }

    private func decision(at date: Date) -> LightingScheduleDecision {
        LightingScheduleEngine.evaluate(
            rules: settings.rules,
            at: date,
            calendar: calendarProvider()
        )
    }

    private func scheduleBoundary(_ nextBoundary: Date?, retry: Bool = false) {
        let pausedBoundary = pauseUntil.flatMap { $0 > nowProvider() && $0 != .distantFuture ? $0 : nil }
        let next = [nextBoundary, pausedBoundary].compactMap { $0 }.min()
        let boundary = retry ? min(next ?? .distantFuture, nowProvider().addingTimeInterval(30)) : next
        scheduledWake = boundary
        guard let boundary else {
            return
        }
        let sleeper = sleepUntil
        waitTask = Task { [weak self] in
            do {
                try await sleeper(boundary)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.boundaryReached(boundary)
        }
    }

    private func boundaryReached(_ boundary: Date) async {
        guard !isStopped, scheduledWake == boundary,
              nowProvider() >= boundary
        else {
            return
        }
        // Do not cancel the task currently applying the boundary's commands.
        waitTask = nil
        revision += 1
        await reevaluate(applyImmediately: true, forceApply: false)
    }

    private func publish(_ value: LightingAutomationStatus) {
        guard status != value else { return }
        status = value
        eventContinuation.yield(value)
    }
}
