import Foundation

public enum LightingControl: Hashable, Sendable {
    case brightness
    case temperature
}

public struct LightingCommand: Equatable, Sendable {
    public let control: LightingControl
    public let value: Int

    public init(control: LightingControl, value: Int) {
        self.control = control
        self.value = value
    }
}

public enum LightingCommandOutcome: Equatable, Sendable {
    case success(LightingCommand)
    case failure(LightingCommand)
}

public enum LightingCommandEvent: Equatable, Sendable {
    case activityChanged(Bool, generation: UInt64)
    case completed(
        LightingCommandOutcome,
        generation: UInt64,
        revision: UInt64
    )
}

public actor DebouncedLightingCommandCoordinator {
    public nonisolated let events: AsyncStream<LightingCommandEvent>

    public typealias Execute = @Sendable (LightingCommand) async throws -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let debounce: Duration
    private let execute: Execute
    private let sleep: Sleep
    private nonisolated let eventContinuation:
        AsyncStream<LightingCommandEvent>.Continuation
    private struct PendingCommand {
        let submission: LightingCommandSubmission
    }

    private var generation: UInt64 = 0
    private var revisions: [LightingControl: UInt64] = [:]
    private var debounceTasks: [LightingControl: Task<Void, Never>] = [:]
    private var pending: [LightingControl: PendingCommand] = [:]
    private var isDraining = false
    private var publishedActivity = false
    private var publishedGeneration: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        debounce: Duration = .milliseconds(140),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        execute: @escaping Execute
    ) {
        self.debounce = debounce
        self.sleep = sleep
        self.execute = execute
        let pair = AsyncStream<LightingCommandEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    deinit {
        for task in debounceTasks.values {
            task.cancel()
        }
        for waiter in idleWaiters {
            waiter.resume()
        }
        eventContinuation.finish()
    }

    @discardableResult
    public func submit(
        _ submission: LightingCommandSubmission
    ) -> Bool {
        let command = submission.command
        guard submission.generation == generation,
              submission.revision > (revisions[command.control] ?? 0)
        else {
            return false
        }
        debounceTasks[command.control]?.cancel()
        revisions[command.control] = submission.revision
        let delay = debounce
        let sleeper = sleep
        debounceTasks[command.control] = Task { [weak self] in
            do {
                try await sleeper(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.debounceFinished(
                submission
            )
        }
        publishActivityIfNeeded()
        return true
    }

    public func reset(to generation: UInt64) {
        guard generation != self.generation else { return }
        self.generation = generation
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        pending.removeAll()
        revisions.removeAll()
        publishActivityIfNeeded(force: true)
    }

    public func hasActiveWork() -> Bool {
        isActive
    }

    public func waitUntilIdle() async {
        guard isActive else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private var isActive: Bool {
        !debounceTasks.isEmpty || !pending.isEmpty || isDraining
    }

    private func debounceFinished(
        _ submission: LightingCommandSubmission
    ) async {
        let command = submission.command
        guard submission.generation == generation,
              revisions[command.control] == submission.revision
        else {
            return
        }
        debounceTasks[command.control] = nil
        pending[command.control] = PendingCommand(
            submission: submission
        )
        guard !isDraining else { return }
        isDraining = true
        publishActivityIfNeeded()

        while let item = pending.values.first {
            let submission = item.submission
            let command = submission.command
            pending[command.control] = nil
            do {
                try await execute(command)
                if submission.generation == generation {
                    eventContinuation.yield(
                        .completed(
                            .success(command),
                            generation: submission.generation,
                            revision: submission.revision
                        )
                    )
                }
            } catch {
                if submission.generation == generation {
                    eventContinuation.yield(
                        .completed(
                            .failure(command),
                            generation: submission.generation,
                            revision: submission.revision
                        )
                    )
                }
            }
        }

        isDraining = false
        publishActivityIfNeeded()
    }

    private func publishActivityIfNeeded(force: Bool = false) {
        let active = isActive
        guard force
                || active != publishedActivity
                || generation != publishedGeneration
        else {
            return
        }
        publishedActivity = active
        publishedGeneration = generation
        eventContinuation.yield(
            .activityChanged(active, generation: generation)
        )
        if !active {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
