import Foundation
import PaperlikeCore

func debouncedLightingCommandCoordinatorTests() -> [TestCase] {
    [
        TestCase("LightingCoordinator.deliversLatestValueForEachControl") {
            let recorder = LightingCommandRecorder()
            let sleeper = LightingDebounceGate()
            var registrations = sleeper.registrations.makeAsyncIterator()
            let coordinator = DebouncedLightingCommandCoordinator(
                sleep: { duration in
                    try await sleeper.wait(duration)
                },
                execute: { command in
                    try await recorder.append(command)
                }
            )

            let firstAccepted = await coordinator.submit(
                .init(
                    command: .init(control: .brightness, value: 10),
                    generation: 0,
                    revision: 1
                )
            )
            _ = await registrations.next()
            let secondAccepted = await coordinator.submit(
                .init(
                    command: .init(control: .brightness, value: 42),
                    generation: 0,
                    revision: 2
                )
            )
            _ = await registrations.next()
            let thirdAccepted = await coordinator.submit(
                .init(
                    command: .init(control: .temperature, value: 77),
                    generation: 0,
                    revision: 3
                )
            )
            _ = await registrations.next()
            try expect(firstAccepted && secondAccepted && thirdAccepted,
                       "current generation accepts commands")
            let activeAfterSubmit = await coordinator.hasActiveWork()
            try expect(activeAfterSubmit,
                       "accepted debounce work is immediately active")

            await sleeper.releaseAll()
            await coordinator.waitUntilIdle()

            let commands = await recorder.commands
            try expectEqual(
                commands.filter { $0.control == .brightness },
                [.init(control: .brightness, value: 42)]
            )
            try expectEqual(
                commands.filter { $0.control == .temperature },
                [.init(control: .temperature, value: 77)]
            )
        },
        TestCase("LightingCoordinator.reportsFailureAndContinues") {
            let recorder = LightingCommandRecorder(failing: .brightness)
            let sleeper = LightingDebounceGate()
            var registrations = sleeper.registrations.makeAsyncIterator()
            let coordinator = DebouncedLightingCommandCoordinator(
                sleep: { duration in
                    try await sleeper.wait(duration)
                },
                execute: { command in
                    try await recorder.append(command)
                }
            )
            let events = coordinator.events

            _ = await coordinator.submit(
                .init(
                    command: .init(control: .brightness, value: 20),
                    generation: 0,
                    revision: 1
                )
            )
            _ = await coordinator.submit(
                .init(
                    command: .init(control: .temperature, value: 80),
                    generation: 0,
                    revision: 2
                )
            )
            _ = await registrations.next()
            _ = await registrations.next()
            await sleeper.releaseAll()

            var outcomes: [LightingCommandOutcome] = []
            var generations: [UInt64] = []
            var revisions: Set<UInt64> = []
            for await event in events {
                if case let .completed(outcome, generation, revision) = event,
                   generation == 0 {
                    outcomes.append(outcome)
                    generations.append(generation)
                    revisions.insert(revision)
                    if outcomes.count == 2 { break }
                }
            }

            try expect(outcomes.contains(.failure(.init(
                control: .brightness,
                value: 20
            ))), "brightness failure is reported")
            try expect(outcomes.contains(.success(.init(
                control: .temperature,
                value: 80
            ))), "temperature still executes")
            try expectEqual(generations, [0, 0])
            try expectEqual(revisions, Set([1, 2]))
        },
        TestCase("LightingCoordinator.cancelsPreviousGeneration") {
            let recorder = LightingCommandRecorder()
            let sleeper = LightingDebounceGate()
            var registrations = sleeper.registrations.makeAsyncIterator()
            let coordinator = DebouncedLightingCommandCoordinator(
                sleep: { duration in
                    try await sleeper.wait(duration)
                },
                execute: { command in
                    try await recorder.append(command)
                }
            )
            var events = coordinator.events.makeAsyncIterator()

            let oldAccepted = await coordinator.submit(
                .init(
                    command: .init(control: .brightness, value: 15),
                    generation: 0,
                    revision: 1
                )
            )
            try expect(oldAccepted, "initial generation accepts work")
            try expectEqual(
                await events.next(),
                .activityChanged(true, generation: 0)
            )
            _ = await registrations.next()

            await coordinator.reset(to: 1)
            try expectEqual(
                await events.next(),
                .activityChanged(false, generation: 1)
            )
            await sleeper.releaseAll()

            let staleAccepted = await coordinator.submit(
                .init(
                    command: .init(control: .brightness, value: 15),
                    generation: 0,
                    revision: 2
                )
            )
            try expect(!staleAccepted, "stale generation is rejected")

            let newAccepted = await coordinator.submit(
                .init(
                    command: .init(control: .temperature, value: 85),
                    generation: 1,
                    revision: 3
                )
            )
            try expect(newAccepted, "new generation accepts work")
            _ = await registrations.next()
            await sleeper.releaseAll()
            await coordinator.waitUntilIdle()

            let recordedCommands = await recorder.commands
            try expectEqual(
                recordedCommands,
                [.init(control: .temperature, value: 85)]
            )
        }
    ]
}

private actor LightingDebounceGate {
    nonisolated let registrations: AsyncStream<Duration>
    private nonisolated let registrationContinuation:
        AsyncStream<Duration>.Continuation
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let pair = AsyncStream<Duration>.makeStream()
        registrations = pair.stream
        registrationContinuation = pair.continuation
    }

    func wait(_ duration: Duration) async throws {
        registrationContinuation.yield(duration)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.resume()
        }
    }
}

private enum LightingTestError: Error {
    case expected
}

private actor LightingCommandRecorder {
    private(set) var commands: [LightingCommand] = []
    private let failing: LightingControl?

    init(failing: LightingControl? = nil) {
        self.failing = failing
    }

    func append(_ command: LightingCommand) throws {
        commands.append(command)
        if command.control == failing {
            throw LightingTestError.expected
        }
    }
}
