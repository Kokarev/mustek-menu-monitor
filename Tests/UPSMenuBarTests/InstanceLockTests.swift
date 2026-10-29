import XCTest
@testable import UPSMenuBar

final class InstanceLockTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL { directory.appendingPathComponent(".lock") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func isAcquired(_ result: InstanceLock.Result) -> Bool {
        if case .acquired = result { return true }
        return false
    }

    private func isHeldElsewhere(_ result: InstanceLock.Result) -> Bool {
        if case .heldElsewhere = result { return true }
        return false
    }

    func testSecondInstanceIsRefusedUntilFirstReleases() {
        var first: InstanceLock.Result? = InstanceLock.acquire(at: lockURL)
        XCTAssertTrue(isAcquired(first!))
        XCTAssertTrue(isHeldElsewhere(InstanceLock.acquire(at: lockURL)), "second open of the lock must be refused")
        first = nil
        XCTAssertTrue(isAcquired(InstanceLock.acquire(at: lockURL)), "lock is free after the holder is released")
    }

    func testLockFileRecordsHolderPid() throws {
        let result = InstanceLock.acquire(at: lockURL)
        XCTAssertTrue(isAcquired(result))
        let text = try String(contentsOf: lockURL, encoding: .utf8)
        XCTAssertEqual(text, "\(getpid())\n")
    }

    func testLeftoverLockFileDoesNotBlockStart() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "99999\n".write(to: lockURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(isAcquired(InstanceLock.acquire(at: lockURL)), "a file without a live holder is not a lock")
    }

    func testUnwritableLocationIsReportedNotIgnored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notADirectory = directory.appendingPathComponent("file")
        try "x".write(to: notADirectory, atomically: true, encoding: .utf8)
        guard case .unavailable = InstanceLock.acquire(at: notADirectory.appendingPathComponent(".lock")) else {
            return XCTFail("expected .unavailable")
        }
    }

    func testLockHeldByAnotherProcessIsReleasedOnNormalExit() throws {
        let holder = try startHolder()
        XCTAssertTrue(isHeldElsewhere(InstanceLock.acquire(at: lockURL)))
        holder.terminate()                    // SIGTERM
        holder.waitUntilExit()
        XCTAssertTrue(isAcquired(InstanceLock.acquire(at: lockURL)))
    }

    func testLockHeldByAnotherProcessIsReleasedOnCrash() throws {
        let holder = try startHolder()
        XCTAssertTrue(isHeldElsewhere(InstanceLock.acquire(at: lockURL)))
        kill(holder.processIdentifier, SIGKILL) // no cleanup code runs
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationReason, .uncaughtSignal)
        XCTAssertTrue(isAcquired(InstanceLock.acquire(at: lockURL)))
    }

    /// A separate process that holds flock(2) on the lock file until it is signalled.
    private func startHolder() throws -> Process {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", """
            import fcntl, sys, time
            f = open(sys.argv[1], "a")
            fcntl.flock(f, fcntl.LOCK_EX)
            print("locked", flush=True)
            time.sleep(60)
            """, lockURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        XCTAssertEqual(line.trimmingCharacters(in: .whitespacesAndNewlines), "locked")
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        return process
    }
}
