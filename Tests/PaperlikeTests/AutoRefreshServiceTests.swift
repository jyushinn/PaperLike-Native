import PaperlikeCore

private actor RefreshProbe {
    var refreshCount = 0
    var sleepSeconds: [Int] = []

    func slept(seconds: Int) {
        sleepSeconds.append(seconds)
    }

    func refreshed() {
        refreshCount += 1
    }
}

private actor RefreshPredicateGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}

func autoRefreshServiceTests() -> [TestCase] {
    [
        TestCase("AutoRefreshServiceTests.refreshesWhenReady") {
            let probe = RefreshProbe()
            let service = AutoRefreshService(
                isConnected: { true },
                isIdle: { true },
                refresh: { await probe.refreshed() },
                sleep: { seconds in await probe.slept(seconds: seconds) }
            )

            await service.runOneCycle(intervalSeconds: 30)

            try expectEqual(await probe.sleepSeconds, [30])
            try expectEqual(await probe.refreshCount, 1)
        },
        TestCase("AutoRefreshServiceTests.cancelDuringPredicatePreventsRefresh") {
            for gateConnected in [true, false] {
                let gate = RefreshPredicateGate()
                let probe = RefreshProbe()
                let service = AutoRefreshService(
                    isConnected: { gateConnected ? await gate.wait() : true },
                    isIdle: { gateConnected ? true : await gate.wait() },
                    refresh: { await probe.refreshed() },
                    sleep: { _ in }
                )
                let task = Task { await service.runOneCycle(intervalSeconds: 30) }
                let deadline = ContinuousClock.now + .seconds(2)
                while !(await gate.isWaiting), ContinuousClock.now < deadline {
                    await Task.yield()
                }
                let waiting = await gate.isWaiting
                task.cancel()
                await gate.resume()
                await task.value
                try expectEqual(waiting, true)
                try expectEqual(await probe.refreshCount, 0)
            }
        },
        TestCase("AutoRefreshServiceTests.defersWhileBusy") {
            let probe = RefreshProbe()
            let service = AutoRefreshService(
                isConnected: { true },
                isIdle: { false },
                refresh: { await probe.refreshed() },
                sleep: { seconds in await probe.slept(seconds: seconds) }
            )

            await service.runOneCycle(intervalSeconds: 45)

            try expectEqual(await probe.sleepSeconds, [45])
            try expectEqual(await probe.refreshCount, 0)
        }
    ]
}
