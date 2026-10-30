import PaperlikeLocalization
import Darwin
import Foundation

/// Run outside the main thread. Timeout and cancellation also stop the child process.
public struct AppleScriptRunner: Sendable {
    private static let queue = DispatchQueue(label: "org.paperlike.native.system-settings")
    private let timeout: TimeInterval
    private let executableURL: URL
    private let arguments: [String]?

    public init(timeout: TimeInterval = 15) {
        self.init(timeout: timeout, executableURL: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: nil)
    }

    // An executable boundary allows deterministic process tests without changing system settings.
    init(timeout: TimeInterval, executableURL: URL, arguments: [String]?) {
        self.timeout = timeout.isFinite ? max(0.01, timeout) : 15
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func run(_ source: String) async throws {
        let state = ScriptProcessState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard state.install(continuation, timeout: timeout) else { return }
                Self.queue.async {
                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = arguments ?? ["-e", source]
                    process.standardOutput = FileHandle.nullDevice
                    // A child may inherit stderr after its parent exits. A private file avoids waiting for pipe EOF.
                    let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("paperlike-script-\(UUID().uuidString).stderr")
                    do {
                        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        defer { try? FileManager.default.removeItem(at: errorURL) }
                        let output = try FileHandle(forWritingTo: errorURL)
                        defer { try? output.close() }
                        process.standardError = output
                        guard try state.launch(process) else { return }
                        process.waitUntilExit()
                        let input = try FileHandle(forReadingFrom: errorURL)
                        defer { try? input.close() }
                        let detail = try input.read(upToCount: 65_536) ?? Data()
                        if process.terminationStatus == 0 { state.finish(.success(())) }
                        else {
                            state.finish(.failure(NSError(domain: "PaperLikeNative.AppleScript", code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: String(decoding: detail, as: UTF8.self)])))
                        }
                    } catch { state.finish(.failure(error)) }
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()), stopProcess: true)
        }
    }
}

/// The lock owns launch, completion and cancellation, including cancellation before launch.
private final class ScriptProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var deadline: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(NSError(domain: "PaperLikeNative.AppleScript", code: -1001,
                userInfo: [NSLocalizedDescriptionKey: L("系统设置操作超时，已请求停止子进程，请重试。")])), stopProcess: true)
        }
        self.deadline = deadline
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        return true
    }

    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return false }
        try process.run()
        self.process = process
        return true
    }

    func finish(_ result: Result<Void, Error>, stopProcess: Bool = false) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        let process = self.process
        lock.unlock()
        if stopProcess, let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        continuation?.resume(with: result)
    }
}
