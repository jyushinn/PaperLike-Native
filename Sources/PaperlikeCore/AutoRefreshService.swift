public actor AutoRefreshService {
    public typealias Predicate = @Sendable () async -> Bool
    public typealias RefreshAction = @Sendable () async throws -> Void
    public typealias SleepAction = @Sendable (Int) async throws -> Void

    private let isConnected: Predicate
    private let isIdle: Predicate
    private let refresh: RefreshAction
    private let sleep: SleepAction
    private var task: Task<Void, Never>?

    public init(
        isConnected: @escaping Predicate,
        isIdle: @escaping Predicate,
        refresh: @escaping RefreshAction,
        sleep: @escaping SleepAction = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.isConnected = isConnected
        self.isIdle = isIdle
        self.refresh = refresh
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    public func start(intervalSeconds: Int) {
        stop()
        let interval = max(30, intervalSeconds)
        task = Task {
            while !Task.isCancelled {
                await runOneCycle(intervalSeconds: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func runOneCycle(intervalSeconds: Int) async {
        do {
            try await sleep(max(30, intervalSeconds))
            guard !Task.isCancelled,
                  await isConnected(),
                  await isIdle(),
                  !Task.isCancelled
            else {
                return
            }
            try await refresh()
        } catch {
            return
        }
    }
}
