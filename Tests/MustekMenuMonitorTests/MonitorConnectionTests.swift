import XCTest
@testable import MustekMenuMonitor

/// Runner whose calls stay pending until the test answers them, to reproduce late responses.
final class ControlledRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(target: String, continuation: CheckedContinuation<UpscOutcome, Never>)] = []
    private(set) var targets: [String] = []

    var run: UpscRunner {
        { [self] _, target in
            await withCheckedContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                pending.append((target, continuation))
                targets.append(target)
            }
        }
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    /// Answers the oldest pending call for `target`.
    func answer(_ target: String, with outcome: UpscOutcome) {
        lock.lock()
        let index = pending.firstIndex { $0.target == target }!
        let call = pending.remove(at: index)
        lock.unlock()
        call.continuation.resume(returning: outcome)
    }
}

@MainActor final class MonitorConnectionTests: XCTestCase {
    private var directory: URL!
    private var tools: URL!
    private var locator: UpscLocator!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MustekConnectionTests-\(UUID().uuidString)", isDirectory: true)
        directory = base.appendingPathComponent("data", isDirectory: true)
        tools = base.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        // Automatic search sees only this placeholder, never the machine's real upsc.
        let auto = tools.appendingPathComponent("auto-upsc")
        try "#!/bin/sh\nexit 0\n".write(to: auto, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: auto.path)
        locator = UpscLocator(candidates: [auto.path])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tools.deletingLastPathComponent())
    }

    // MARK: Helpers

    private func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0) }
    }

    /// Fake upsc: logs its argument count and arguments, then behaves as `mode` says
    /// (ok, refused, unknown). The mode file can be changed between polls.
    private func fakeUpsc(mode: String = "ok", output: String = sampleOL) throws -> String {
        try output.write(to: tools.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        setMode(mode)
        let dir = tools.path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$#" "$@" >> '\(dir)/calls.log'
        case "$(cat '\(dir)/mode')" in
          ok) cat '\(dir)/sample.txt' ;;
          refused) echo 'Error: Connection failure: Connection refused' >&2; exit 1 ;;
          unknown) echo 'Error: Unknown UPS' >&2; exit 1 ;;
        esac
        """
        let url = tools.appendingPathComponent("upsc")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func setMode(_ mode: String) {
        try? mode.write(to: tools.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    private var calls: [String] {
        let text = (try? String(contentsOf: tools.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0) }
    }

    private func waitForPending(_ runner: ControlledRunner, count: Int) async {
        for _ in 0..<2000 where runner.pendingCount < count { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(runner.pendingCount, count)
    }

    private func configured(_ name: String = "mustek", path: String? = nil) -> Settings {
        Settings(upsName: name, upscPath: path, ratedWatts: 400)
    }

    // MARK: Connection from settings

    func testConnectionFromSettings() {
        XCTAssertNil(UpscConnection(Settings()))
        XCTAssertNil(UpscConnection(Settings(upsName: "bad name")))
        // A bad upsc path does not make the UPS "not configured"; the poll reports it.
        XCTAssertEqual(UpscConnection(Settings(upsName: "ups", upscPath: "relative/upsc"))?.userPath, "relative/upsc")
        let auto = UpscConnection(Settings(upsName: "ups", host: "nut.example.org", port: 3500))
        XCTAssertNil(auto?.userPath)
        XCTAssertEqual(auto?.target, "ups@nut.example.org:3500")
        XCTAssertNotEqual(auto, UpscConnection(Settings(upsName: "ups", host: "nut.example.org", port: 3500,
                                                        upscPath: "/usr/local/bin/upsc")))
    }

    // MARK: Real process (fake upsc executable)

    func testPollUsesTargetFromSettingsAsOneArgument() async throws {
        let path = try fakeUpsc()
        let monitor = Monitor(settings: Settings(upsName: "mustek", host: "127.0.0.1", port: 3493, upscPath: path),
                              historyDirectory: directory, locator: locator)
        XCTAssertEqual(monitor.link, .waiting)
        await monitor.poll()?.value
        XCTAssertEqual(calls, ["1", "mustek@127.0.0.1:3493"])
        XCTAssertEqual(monitor.link, .ok)
        let rows = lines("history.csv")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0] + "\n", Monitor.historyHeader)
        XCTAssertEqual(rows[1].split(separator: ",", omittingEmptySubsequences: false).count, 8)
    }

    func testNotConfiguredNeverRunsUpscOrWritesHistory() async throws {
        let path = try fakeUpsc()
        let monitor = Monitor(settings: Settings(upscPath: path), historyDirectory: directory, locator: locator)
        XCTAssertEqual(monitor.link, .notConfigured)
        XCTAssertNil(monitor.poll())
        XCTAssertNil(monitor.poll())
        XCTAssertEqual(calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.csv").path))
        let model = MenuModel.make(monitor.snapshot())
        XCTAssertEqual(model.header, "MUSTEK \(L10n.tr("UPS")) — ⚙️ \(L10n.tr("UPS not configured"))")
        XCTAssertEqual(model.statusBarTitle, "⚠️ \(L10n.tr("UPS")) —")
        XCTAssertEqual(model.sections.flatMap(\.rows).first { $0.label == "NUT" }?.value, L10n.tr("not configured"))

        // Configuring later starts monitoring.
        monitor.apply(configured(path: path))
        XCTAssertEqual(monitor.link, .waiting)
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(lines("history.csv").count, 2)
    }

    func testUnconfiguringStopsPollingAndHistory() async throws {
        let path = try fakeUpsc()
        let monitor = Monitor(settings: configured(path: path), historyDirectory: directory, locator: locator)
        await monitor.poll()?.value
        XCTAssertEqual(lines("history.csv").count, 2)
        monitor.apply(Settings(upscPath: path))
        XCTAssertEqual(monitor.link, .notConfigured)
        XCTAssertNil(monitor.reading)
        XCTAssertNil(monitor.poll())
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(lines("history.csv").count, 2)
    }

    func testUnavailableServerAndUnknownUps() async throws {
        let path = try fakeUpsc(mode: "refused")
        let monitor = Monitor(settings: configured(path: path), historyDirectory: directory, locator: locator)
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("upsd unavailable")))
        setMode("unknown")
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("UPS not found in upsd")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.csv").path))
    }

    func testRecoversAfterErrorWithSameAndWithNewSettings() async throws {
        let path = try fakeUpsc(mode: "refused")
        let monitor = Monitor(settings: configured(path: path), historyDirectory: directory, locator: locator)
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("upsd unavailable")))
        setMode("ok")
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .ok)

        setMode("unknown")
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("UPS not found in upsd")))
        setMode("ok")
        monitor.apply(configured("other", path: path))
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(calls.suffix(2), ["1", "other@127.0.0.1:3493"])
    }

    func testMissingUpscExecutable() async {
        let monitor = Monitor(settings: configured(path: tools.appendingPathComponent("absent").path),
                              historyDirectory: directory, locator: locator)
        XCTAssertNil(monitor.poll())
        XCTAssertEqual(monitor.link, .noResponse(L10n.tr("selected upsc unavailable")))
    }

    func testHungUpscIsStillTerminated() async throws {
        // Ignores SIGTERM from its first line, so only the SIGKILL fallback can end it.
        let url = tools.appendingPathComponent("upsc-hang")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(tools.path)/pid'\nwhile :; do :; done\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let outcome = await Upsc.run(path: url.path, target: "mustek@127.0.0.1:3493", timeout: 1)
        guard case .timedOut = outcome else { return XCTFail("expected timeout, got \(outcome)") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: tools.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "fake upsc must not survive the timeout")
    }

    // MARK: Changing settings while running

    func testApplyResetsIntegrationPoint() {
        let monitor = Monitor(settings: configured(), historyDirectory: directory, locator: locator)
        let t0 = Date()
        monitor.handle(.output(sample(load: 6)), at: t0)
        monitor.handle(.output(sample(load: 6)), at: t0.addingTimeInterval(5))
        let before = monitor.todayWh
        XCTAssertGreaterThan(before, 0)

        monitor.apply(configured("other"))
        XCTAssertEqual(monitor.link, .waiting)
        XCTAssertNil(monitor.reading)
        XCTAssertNil(monitor.lastSuccess)
        monitor.handle(.output(sample(load: 50)), at: t0.addingTimeInterval(10))
        // The first sample after the change starts a new chain: no energy bridged across it.
        XCTAssertEqual(lines("history.csv").last?.split(separator: ",", omittingEmptySubsequences: false)[6], "")
        XCTAssertEqual(monitor.todayWh, before)
        // Existing rows are untouched and the format is unchanged.
        let rows = lines("history.csv")
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 8 })
    }

    func testApplyWithSameConnectionKeepsState() {
        let monitor = Monitor(settings: configured(), historyDirectory: directory, locator: locator)
        monitor.handle(.output(sampleOL), at: Date())
        let generation = monitor.generation
        var settings = configured()
        settings.ratedWatts = 600
        monitor.apply(settings)
        XCTAssertEqual(monitor.generation, generation)
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertNotNil(monitor.reading)
        XCTAssertEqual(monitor.settings.ratedWatts, 600)
    }

    func testLateAnswerFromOldUpsIsDiscarded() async {
        let runner = ControlledRunner()
        let monitor = Monitor(settings: configured("old"), historyDirectory: directory, locator: locator, runUpsc: runner.run)
        let oldPoll = monitor.poll()
        await waitForPending(runner, count: 1)

        monitor.apply(configured("new"))
        let newPoll = monitor.poll()
        XCTAssertNotNil(newPoll, "a pending old poll must not block the new connection")
        await waitForPending(runner, count: 2)

        // The old UPS answers last-minute with a very different reading, then fails.
        runner.answer("old@127.0.0.1:3493", with: .output(sample(status: "OB", input: 0, load: 90, battery: 11)))
        await oldPoll?.value
        XCTAssertEqual(monitor.link, .waiting)
        XCTAssertNil(monitor.reading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.csv").path))
        XCTAssertNil(monitor.currentOutage)

        runner.answer("new@127.0.0.1:3493", with: .output(sample(load: 7)))
        await newPoll?.value
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(monitor.reading?.load, 7)
        XCTAssertEqual(lines("history.csv").count, 2)
        XCTAssertEqual(runner.targets, ["old@127.0.0.1:3493", "new@127.0.0.1:3493"])
    }

    func testLateFailureFromOldUpsIsDiscarded() async {
        let runner = ControlledRunner()
        let monitor = Monitor(settings: configured("old"), historyDirectory: directory, locator: locator, runUpsc: runner.run)
        let oldPoll = monitor.poll()
        await waitForPending(runner, count: 1)
        monitor.apply(configured("new"))
        let newPoll = monitor.poll()
        await waitForPending(runner, count: 2)
        runner.answer("new@127.0.0.1:3493", with: .output(sampleOL))
        await newPoll?.value
        XCTAssertEqual(monitor.link, .ok)

        runner.answer("old@127.0.0.1:3493", with: .failed(1, "Error: Unknown UPS"))
        await oldPoll?.value
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(monitor.reading?.load, 5)
    }

    func testLateAnswerAfterUnconfiguringIsDiscarded() async {
        let runner = ControlledRunner()
        let monitor = Monitor(settings: configured(), historyDirectory: directory, locator: locator, runUpsc: runner.run)
        let poll = monitor.poll()
        await waitForPending(runner, count: 1)
        monitor.apply(Settings())
        runner.answer("mustek@127.0.0.1:3493", with: .output(sampleOL))
        await poll?.value
        XCTAssertEqual(monitor.link, .notConfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.csv").path))
    }

    func testOverlappingPollsAreStillPreventedWithinOneConnection() async {
        let runner = ControlledRunner()
        let monitor = Monitor(settings: configured(), historyDirectory: directory, locator: locator, runUpsc: runner.run)
        let first = monitor.poll()
        await waitForPending(runner, count: 1)
        XCTAssertNil(monitor.poll())
        runner.answer("mustek@127.0.0.1:3493", with: .output(sampleOL))
        await first?.value
        let second = monitor.poll()
        XCTAssertNotNil(second)
        await waitForPending(runner, count: 1)
        runner.answer("mustek@127.0.0.1:3493", with: .output(sampleOL))
        await second?.value
    }

    // MARK: Production domain

    func testMonitorDoesNotTouchProductionDefaults() async throws {
        let before = UserDefaults.standard.persistentDomain(forName: SettingsStoreTests.productionDomain) as NSDictionary?
        let path = try fakeUpsc()
        let monitor = Monitor(settings: configured(path: path), historyDirectory: directory, locator: locator)
        await monitor.poll()?.value
        monitor.apply(configured("other", path: path))
        monitor.apply(Settings())
        let after = UserDefaults.standard.persistentDomain(forName: SettingsStoreTests.productionDomain) as NSDictionary?
        XCTAssertEqual(after, before)
    }
}
