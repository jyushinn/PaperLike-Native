import PaperlikeCore

func lightingCommandSessionStateTests() -> [TestCase] {
    [
        TestCase("LightingSession.closesBeforeAsynchronousReset") {
            var session = LightingCommandSessionState()
            session.connectionDidBecomeAvailable()
            let first = session.submit(control: .brightness, value: 30)
            try expect(first != nil, "connected session accepts commands")

            let generation = session.beginConnectionReset()

            try expectEqual(generation, 1)
            try expect(
                session.submit(control: .temperature, value: 70) == nil,
                "resetting session rejects commands synchronously"
            )
            try expect(!session.hasPendingCommands, "old drafts are cleared")
        },
        TestCase("LightingSession.ignoresBufferedOldGenerationEvents") {
            var session = LightingCommandSessionState()
            session.connectionDidBecomeAvailable()
            let old = session.submit(control: .brightness, value: 42)!
            _ = session.handle(.activityChanged(true, generation: 0))

            _ = session.beginConnectionReset()
            session.connectionDidBecomeAvailable()
            let current = session.submit(control: .brightness, value: 42)!
            _ = session.handle(.activityChanged(true, generation: 1))

            let oldCompletion = session.handle(.completed(
                .success(old.command),
                generation: old.generation,
                revision: old.revision
            ))
            let oldActivity = session.handle(
                .activityChanged(false, generation: 0)
            )

            try expectEqual(oldCompletion, .ignored)
            try expectEqual(oldActivity, .ignored)
            try expect(session.hasPendingCommands, "current same-value draft remains")
            try expect(session.isBusy, "old activity cannot unlock current work")

            let currentCompletion = session.handle(.completed(
                .success(current.command),
                generation: current.generation,
                revision: current.revision
            ))
            try expectEqual(currentCompletion, .succeeded(current.command))
            try expect(!session.hasPendingCommands, "current completion clears draft")
        }
    ]
}
