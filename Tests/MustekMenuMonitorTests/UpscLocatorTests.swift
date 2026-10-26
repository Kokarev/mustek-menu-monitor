import XCTest
@testable import MustekMenuMonitor

@MainActor final class UpscLocatorTests: XCTestCase {
    private var root: URL!
    private var tools: URL!
    private var directory: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MustekLocatorTests-\(UUID().uuidString)", isDirectory: true)
        tools = root.appendingPathComponent("tools", isDirectory: true)
        directory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func path(_ name: String) -> String { tools.appendingPathComponent(name).path }

    @discardableResult
    private func script(_ name: String, _ body: String, mode: Int = 0o755) throws -> String {
        let url = tools.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    private func symlink(_ name: String, to destination: String) throws -> String {
        try FileManager.default.createSymbolicLink(atPath: path(name), withDestinationPath: destination)
        return path(name)
    }

    private func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0) }
    }

    // MARK: Search

    func testStandardPathsAndOrder() {
        XCTAssertEqual(UpscLocator.standardPaths, [
            "/opt/homebrew/bin/upsc",
            "/opt/homebrew/opt/nut/bin/upsc",
            "/usr/local/bin/upsc",
            "/usr/local/opt/nut/bin/upsc",
            "/opt/local/bin/upsc",
        ])
    }

    func testUserPathHasPriority() throws {
        let user = try script("user-upsc", "exit 0")
        let standard = try script("upsc", "exit 0")
        let locator = UpscLocator(candidates: [standard])
        XCTAssertEqual(locator.locate(userPath: user), .success(user))
        XCTAssertEqual(locator.locate(userPath: nil), .success(standard))
    }

    func testFirstUsableCandidateWinsInOrder() throws {
        let second = try script("second", "exit 0")
        let third = try script("third", "exit 0")
        let locator = UpscLocator(candidates: [path("missing"), second, third])
        XCTAssertEqual(locator.locate(userPath: nil), .success(second))
        XCTAssertEqual(UpscLocator(candidates: [third, second]).locate(userPath: nil), .success(third))
    }

    func testNothingFound() {
        let candidates = [path("a"), path("b")]
        XCTAssertEqual(UpscLocator(candidates: candidates).locate(userPath: nil), .failure(.notFound(searched: candidates)))
        XCTAssertEqual(UpscLocator(candidates: []).locate(userPath: nil), .failure(.notFound(searched: [])))
    }

    func testUnusableCandidatesAreSkipped() throws {
        let plain = try script("plain", "exit 0", mode: 0o644)
        let folder = tools.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dangling = try symlink("dangling", to: path("nowhere"))
        let toFolder = try symlink("to-folder", to: folder.path)
        let good = try script("good", "exit 0")
        let locator = UpscLocator(candidates: [plain, folder.path, dangling, toFolder, "relative/upsc", good])
        XCTAssertEqual(locator.locate(userPath: nil), .success(good))
    }

    func testSymlinkToExecutableIsUsedUnresolved() throws {
        let real = try script("real-upsc", "exit 0")
        let link = try symlink("upsc", to: real)
        XCTAssertEqual(UpscLocator(candidates: [link]).locate(userPath: nil), .success(link))
        XCTAssertEqual(UpscLocator(candidates: []).locate(userPath: link), .success(link))
    }

    func testUnusableUserPathIsReportedWithoutFallback() throws {
        let standard = try script("upsc", "exit 0")
        let locator = UpscLocator(candidates: [standard])
        let plain = try script("plain", "exit 0", mode: 0o644)
        let dangling = try symlink("dangling", to: path("nowhere"))
        let cases: [(String, SettingsIssue)] = [
            (path("absent"), .upscPathNotFound),
            (plain, .upscPathNotExecutable),
            (tools.path, .upscPathNotExecutable),
            (dangling, .upscPathNotFound),
            ("bin/upsc", .upscPathNotAbsolute),
            ("", .upscPathNotAbsolute),
        ]
        for (userPath, issue) in cases {
            XCTAssertEqual(locator.locate(userPath: userPath), .failure(.userPathUnusable(path: userPath, issue: issue)), userPath)
        }
    }

    func testSearchNeverRunsTheFile() throws {
        let marker = path("ran")
        let candidate = try script("upsc", "touch '\(marker)'")
        XCTAssertEqual(UpscLocator(candidates: [candidate]).locate(userPath: nil), .success(candidate))
        XCTAssertEqual(UpscLocator(candidates: []).locate(userPath: candidate), .success(candidate))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testSettingsValidationUsesTheSameRules() throws {
        let link = try symlink("upsc", to: try script("real", "exit 0"))
        XCTAssertEqual(Settings(upscPath: link).validate(), [])
        XCTAssertEqual(Settings(upscPath: try symlink("dangling", to: path("x"))).validate(), [.upscPathNotFound])
    }

    // MARK: Version (`upsc -V`)

    func testVersionFromFakeExecutable() async throws {
        let fake = try script("upsc", "printf '%s\\n' \"$@\" > '\(path("args"))'\necho 'Network UPS Tools upsc 2.8.5 release'")
        let result = await UpscVersionProbe().version(path: fake)
        XCTAssertEqual(result, .success("Network UPS Tools upsc 2.8.5 release"))
        XCTAssertEqual(try String(contentsOfFile: path("args"), encoding: .utf8), "-V\n")
    }

    func testVersionTimeout() async throws {
        let fake = try script("upsc", "while :; do :; done")
        let started = Date()
        let result = await UpscVersionProbe(timeout: 0.5).version(path: fake)
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testVersionLaunchErrorNonZeroExitAndUnrecognizedOutput() async throws {
        let plain = try script("plain", "exit 0", mode: 0o644)
        guard case .failure(.launchError) = await UpscVersionProbe().version(path: plain) else {
            return XCTFail("expected launch error")
        }
        let failing = try script("failing", "echo 'boom' >&2\nexit 3")
        let failed = await UpscVersionProbe().version(path: failing)
        XCTAssertEqual(failed, .failure(.failed(status: 3, message: "boom\n")))
        let odd = try script("odd", "echo 'usage: something else'")
        let unrecognized = await UpscVersionProbe().version(path: odd)
        XCTAssertEqual(unrecognized, .failure(.unrecognized("usage: something else")))
    }

    func testVersionProbeRunnerIsInjected() async {
        let probe = UpscVersionProbe(timeout: 7) { path, arguments, timeout in
            XCTAssertEqual(path, "/x/upsc")
            XCTAssertEqual(arguments, ["-V"])
            XCTAssertEqual(timeout, 7)
            return .output("\n  Network UPS Tools upsc 2.7.4  \nextra\n")
        }
        let result = await probe.version(path: "/x/upsc")
        XCTAssertEqual(result, .success("Network UPS Tools upsc 2.7.4"))
        let timedOut = await UpscVersionProbe { _, _, _ in .timedOut }.version(path: "/x")
        XCTAssertEqual(timedOut, .failure(.timedOut))
    }

    // MARK: Monitor integration

    func testMonitoringStartsOnceUpscAppears() async throws {
        let expected = path("upsc")
        let monitor = Monitor(settings: Settings(upsName: "mustek"), historyDirectory: directory,
                              locator: UpscLocator(candidates: [expected]))
        XCTAssertNil(monitor.poll())
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("upsc not found")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.csv").path))

        try "\(sampleOL)\n".write(to: tools.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try script("upsc", "cat '\(path("sample.txt"))'")
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(lines("history.csv").count, 2)
    }

    func testUnavailableUpscLeavesHistoryAndOutageUntouched() async throws {
        let sampleFile = tools.appendingPathComponent("sample.txt")
        try sample(status: "OB", input: 0, battery: 12.8).write(to: sampleFile, atomically: true, encoding: .utf8)
        let upsc = try script("upsc", "cat '\(sampleFile.path)'")
        let monitor = Monitor(settings: Settings(upsName: "mustek"), historyDirectory: directory,
                              locator: UpscLocator(candidates: [upsc]))
        await monitor.poll()?.value
        XCTAssertNotNil(monitor.currentOutage)
        let history = try Data(contentsOf: directory.appendingPathComponent("history.csv"))
        let events = try Data(contentsOf: directory.appendingPathComponent("power_events.csv"))

        try FileManager.default.removeItem(atPath: upsc)
        for _ in 0..<3 { XCTAssertNil(monitor.poll()) }
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("upsc not found")))
        XCTAssertNotNil(monitor.currentOutage)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("history.csv")), history)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("power_events.csv")), events)
    }

    func testUnusableUserPathDoesNotFallBackInMonitor() throws {
        let standard = try script("upsc", "touch '\(path("ran"))'")
        let monitor = Monitor(settings: Settings(upsName: "mustek", upscPath: path("absent")), historyDirectory: directory,
                              locator: UpscLocator(candidates: [standard]))
        XCTAssertNil(monitor.poll())
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("selected upsc unavailable")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("ran")))
    }

    func testChangingUserPathDiscardsLateAnswer() async throws {
        let first = try script("first", "exit 0")
        let second = try script("second", "exit 0")
        let runner = ControlledRunner()
        let monitor = Monitor(settings: Settings(upsName: "mustek", upscPath: first), historyDirectory: directory,
                              locator: UpscLocator(candidates: []), runUpsc: runner.run)
        let oldPoll = monitor.poll()
        for _ in 0..<2000 where runner.pendingCount < 1 { try? await Task.sleep(nanoseconds: 1_000_000) }
        let generation = monitor.generation
        monitor.apply(Settings(upsName: "mustek", upscPath: second))
        XCTAssertEqual(monitor.generation, generation + 1)
        XCTAssertEqual(monitor.link, .waiting)

        runner.answer("mustek@127.0.0.1:3493", with: .output(sampleOL))
        await oldPoll?.value
        XCTAssertEqual(monitor.link, .waiting)
        XCTAssertNil(monitor.reading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.csv").path))
    }
}
