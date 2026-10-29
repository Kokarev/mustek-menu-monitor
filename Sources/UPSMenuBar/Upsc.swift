import Foundation

/// Result of one `upsc` invocation, produced off the main thread.
enum UpscOutcome: Sendable {
    case output(String)
    case failed(Int32, String)
    case timedOut
    case launchError(String)
}

/// Set once by the timeout handler, read by the worker after the process exits.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Remembers, per upsc path, whether `-j` can be used. Shared by every monitor in the process;
/// a path is only ever switched from JSON to plain output, never back, until restart. Only an
/// upsc that does not know `-j` is switched; damaged JSON falls back for one poll only.
enum JSONSupport {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var disabled: Set<String> = []
        func isEnabled(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !disabled.contains(path) }
        func disable(_ path: String) { lock.lock(); disabled.insert(path); lock.unlock() }
        func reset() { lock.lock(); disabled = []; lock.unlock() }
    }
    private static let store = Store()

    static func isEnabled(_ path: String) -> Bool { store.isEnabled(path) }
    static func disable(_ path: String) { store.disable(path) }
    /// Forgets every decision; for tests.
    static func reset() { store.reset() }

    /// True when `raw` begins like a JSON object, so a failed parse means damaged JSON
    /// rather than an upsc that ignored `-j` and printed usage or plain lines.
    static func looksLikeJSON(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    /// True for the message of an upsc that rejects `-j` (getopt wording varies by libc),
    /// false for anything else, e.g. "Connection failure: Connection refused".
    static func isOptionError(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("invalid option") || text.contains("illegal option")
            || text.contains("unknown option") || text.contains("unrecognized option")
            || text.contains("usage:")
    }
}

/// Read-only access to NUT through the installed `upsc` client.
enum Upsc {
    static let timeout: TimeInterval = 3

    /// Queries one UPS. `target` is passed as a single argument, never through a shell.
    ///
    /// `upsc -j` (JSON output, NUT 2.8.x) is preferred because its values are escaped
    /// unambiguously. An upsc that does not know `-j` (prints its usage or other non-JSON text
    /// with exit 0, or an option error) switches this upsc path to plain `key: value` output for
    /// the rest of the process. JSON that cannot be read is retried as plain output for this call
    /// only. A connection failure is reported as is and does not switch.
    static func run(path: String, target: String, timeout: TimeInterval = timeout) async -> UpscOutcome {
        if JSONSupport.isEnabled(path) {
            let outcome = await execute(path: path, arguments: ["-j", target], timeout: timeout)
            switch outcome {
            case .output(let raw):
                if Reading.jsonObject(raw) != nil { return outcome }
                // Output that starts as JSON but does not parse is treated as a passing fault:
                // plain output for this poll only, -j again on the next one.
                if !JSONSupport.looksLikeJSON(raw) { JSONSupport.disable(path) }
            case .failed(_, let message):
                guard JSONSupport.isOptionError(message) else { return outcome }
                JSONSupport.disable(path)
            case .timedOut, .launchError:
                return outcome
            }
        }
        return await execute(path: path, arguments: [target], timeout: timeout)
    }

    /// Runs upsc on a background queue; the main thread never waits for it.
    static func execute(path: String, arguments: [String], timeout: TimeInterval = timeout) async -> UpscOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .launchError(error.localizedDescription)); return
                }
                // The upsc process is local and usually exits immediately; timeout guards against hangs.
                let timedOut = TimeoutFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                // Reading until EOF before waiting avoids a full-pipe deadlock on large output.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if timedOut.isSet {
                    continuation.resume(returning: .timedOut)
                } else if process.terminationStatus != 0 {
                    let message = String(data: errorData, encoding: .utf8) ?? ""
                    continuation.resume(returning: .failed(process.terminationStatus, message))
                } else {
                    continuation.resume(returning: .output(String(data: data, encoding: .utf8) ?? ""))
                }
            }
        }
    }
}
