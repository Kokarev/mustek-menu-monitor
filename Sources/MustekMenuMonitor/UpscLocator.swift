import Foundation

/// Why no upsc executable can be used.
enum UpscLocatorError: Error, Equatable {
    /// The path chosen by the user is unusable; no other upsc is tried in its place.
    case userPathUnusable(path: String, issue: SettingsIssue)
    /// No standard location holds an executable upsc.
    case notFound(searched: [String])
}

/// Finds the upsc executable by checking fixed locations. PATH is not consulted, because a
/// GUI app does not inherit the Terminal's. Files are only inspected, never run.
struct UpscLocator {
    /// Homebrew (Apple Silicon, then Intel) and MacPorts, in search order.
    static let standardPaths = [
        "/opt/homebrew/bin/upsc",
        "/opt/homebrew/opt/nut/bin/upsc",
        "/usr/local/bin/upsc",
        "/usr/local/opt/nut/bin/upsc",
        "/opt/local/bin/upsc",
    ]

    let candidates: [String]
    let fileManager: FileManager

    init(candidates: [String] = UpscLocator.standardPaths, fileManager: FileManager = .default) {
        self.candidates = candidates
        self.fileManager = fileManager
    }

    /// The user's path if set (and usable), otherwise the first usable standard location.
    /// The returned path is not resolved, so a Homebrew symlink keeps working across upgrades.
    func locate(userPath: String?) -> Result<String, UpscLocatorError> {
        if let userPath {
            if let issue = Self.problem(at: userPath, fileManager: fileManager) {
                return .failure(.userPathUnusable(path: userPath, issue: issue))
            }
            return .success(userPath)
        }
        if let path = candidates.first(where: { Self.problem(at: $0, fileManager: fileManager) == nil }) {
            return .success(path)
        }
        return .failure(.notFound(searched: candidates))
    }

    /// nil for an absolute path to an executable regular file; symlinks are followed,
    /// so a dangling one counts as missing and one to a directory as not executable.
    static func problem(at path: String, fileManager: FileManager = .default) -> SettingsIssue? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .upscPathNotAbsolute }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .upscPathNotFound }
        // A directory also passes isExecutableFile, so it is rejected explicitly.
        guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: path) else { return .upscPathNotExecutable }
        return nil
    }
}

/// Diagnostic only: asks upsc for its version with `upsc -V`. Not part of polling.
struct UpscVersionProbe {
    enum Failure: Error, Equatable {
        case launchError(String)
        case timedOut
        case failed(status: Int32, message: String)
        /// upsc answered, but not with a version line.
        case unrecognized(String)
    }

    typealias Runner = @Sendable (_ path: String, _ arguments: [String], _ timeout: TimeInterval) async -> UpscOutcome

    let timeout: TimeInterval
    let run: Runner

    init(timeout: TimeInterval = Upsc.timeout,
         run: @escaping Runner = { await Upsc.execute(path: $0, arguments: $1, timeout: $2) }) {
        self.timeout = timeout
        self.run = run
    }

    /// The version line, e.g. "Network UPS Tools upsc 2.8.5 release".
    func version(path: String) async -> Result<String, Failure> {
        switch await run(path, ["-V"], timeout) {
        case .launchError(let message): return .failure(.launchError(message))
        case .timedOut: return .failure(.timedOut)
        case .failed(let status, let message): return .failure(.failed(status: status, message: message))
        case .output(let text):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Network UPS Tools") else { return .failure(.unrecognized(trimmed)) }
            return .success(trimmed)
        }
    }
}
