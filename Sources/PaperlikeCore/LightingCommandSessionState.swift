public struct LightingCommandSubmission: Equatable, Sendable {
    public let command: LightingCommand
    public let generation: UInt64
    public let revision: UInt64

    public init(
        command: LightingCommand,
        generation: UInt64,
        revision: UInt64
    ) {
        self.command = command
        self.generation = generation
        self.revision = revision
    }
}

public enum LightingCommandSessionEffect: Equatable, Sendable {
    case ignored
    case activityChanged(Bool)
    case succeeded(LightingCommand)
    case failed(LightingCommand)
}

public struct LightingCommandSessionState: Sendable {
    private struct Pending: Sendable {
        let value: Int
        let revision: UInt64
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var acceptsCommands = false
    public private(set) var coordinatorActive = false
    private var nextRevision: UInt64 = 0
    private var pending: [LightingControl: Pending] = [:]

    public init() {}

    public var hasPendingCommands: Bool {
        !pending.isEmpty
    }

    public func hasPendingCommand(for control: LightingControl) -> Bool {
        pending[control] != nil
    }

    public var isBusy: Bool {
        coordinatorActive || hasPendingCommands
    }

    public mutating func connectionDidBecomeAvailable() {
        acceptsCommands = true
    }

    @discardableResult
    public mutating func beginConnectionReset() -> UInt64 {
        acceptsCommands = false
        generation &+= 1
        pending.removeAll()
        return generation
    }

    public mutating func submit(
        control: LightingControl,
        value: Int
    ) -> LightingCommandSubmission? {
        guard acceptsCommands else { return nil }
        nextRevision &+= 1
        pending[control] = Pending(value: value, revision: nextRevision)
        return LightingCommandSubmission(
            command: LightingCommand(control: control, value: value),
            generation: generation,
            revision: nextRevision
        )
    }

    public mutating func submissionRejected(
        _ submission: LightingCommandSubmission
    ) {
        guard submission.generation == generation,
              let current = pending[submission.command.control],
              current.value == submission.command.value,
              current.revision == submission.revision
        else {
            return
        }
        pending[submission.command.control] = nil
    }

    public mutating func handle(
        _ event: LightingCommandEvent
    ) -> LightingCommandSessionEffect {
        switch event {
        case let .activityChanged(active, eventGeneration):
            guard eventGeneration == generation else { return .ignored }
            coordinatorActive = active
            return .activityChanged(active)
        case let .completed(
            outcome,
            eventGeneration,
            eventRevision
        ):
            let command: LightingCommand
            let succeeded: Bool
            switch outcome {
            case let .success(value):
                command = value
                succeeded = true
            case let .failure(value):
                command = value
                succeeded = false
            }
            guard eventGeneration == generation,
                  let current = pending[command.control],
                  current.value == command.value,
                  current.revision == eventRevision
            else {
                return .ignored
            }
            pending[command.control] = nil
            return succeeded ? .succeeded(command) : .failed(command)
        }
    }
}
