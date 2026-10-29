import Foundation

/// Exclusive `flock(2)` lock on a file in the data directory, held for the life of the process.
/// The kernel drops it when the descriptor closes, so it is released on a normal quit and on a
/// crash or kill alike; a leftover `.lock` file never blocks a later start.
final class InstanceLock {
    enum Result {
        case acquired(InstanceLock)
        /// Another process (or another open of the file) holds the lock.
        case heldElsewhere
        /// The lock file could not be opened or locked; `errno` value.
        case unavailable(Int32)
    }

    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    static func acquire(at url: URL) -> Result {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .unavailable(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            return error == EWOULDBLOCK ? .heldElsewhere : .unavailable(error)
        }
        // The PID is informational only; the lock itself is what excludes other instances.
        let pid = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return .acquired(InstanceLock(fd: fd))
    }
}
