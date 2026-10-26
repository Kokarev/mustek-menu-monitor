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

/// Read-only access to NUT through the installed `upsc` client.
enum Upsc {
    /// TEMPORARY (until automatic discovery, M3): used when Settings.upscPath is nil.
    /// Homebrew's location on Apple Silicon only.
    static let fallbackPath = "/opt/homebrew/opt/nut/bin/upsc"
    static let timeout: TimeInterval = 3

    /// Runs upsc on a background queue; the main thread never waits for it.
    /// `target` is passed as a single argument, never through a shell.
    static func run(path: String, target: String, timeout: TimeInterval = timeout) async -> UpscOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = [target]
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
