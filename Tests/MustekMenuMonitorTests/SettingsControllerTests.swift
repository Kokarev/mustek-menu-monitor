import XCTest
@testable import MustekMenuMonitor

/// Records upsc calls and answers them from a table; no process is started.
final class FakeExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var answers: [String: UpscOutcome] = [:]

    var execute: UpscExecutor {
        { [self] _, arguments, _ in
            lock.lock(); defer { lock.unlock() }
            calls.append(arguments)
            return answers[arguments.joined(separator: " ")] ?? .failed(1, "Error: Unknown UPS")
        }
    }
}

@MainActor final class SettingsControllerTests: XCTestCase {
    private var root: URL!
    private var upsc: String!
    private var backend: InMemoryDefaults!
    private var fake: FakeExecutor!
    private var applied: [Settings] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MustekSettingsUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("upsc")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        upsc = url.path
        backend = InMemoryDefaults()
        fake = FakeExecutor()
        fake.answers["-V"] = .output("Network UPS Tools upsc 2.8.5 release\n")
        applied = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func controller(current: Settings = Settings(), candidates: [String]? = nil) -> SettingsController {
        SettingsController(current: current, store: SettingsStore(defaults: backend),
                           locator: UpscLocator(candidates: candidates ?? [upsc]), execute: fake.execute) { [weak self] in
            self?.applied.append($0)
        }
    }

    private func draft(_ c: SettingsController, name: String = "mustek", host: String = "127.0.0.1",
                       port: String = "3493", path: String? = nil) throws -> Settings {
        try c.draft(upsName: name, host: host, port: port, upscPath: path).get()
    }

    // MARK: Drafts

    func testDraftFromFields() throws {
        let c = controller(current: Settings(upsName: "old", ratedWatts: 400))
        let d = try draft(c, name: "  mustek ", host: " nut.local ", port: " 3500 ")
        XCTAssertEqual(d, Settings(upsName: "mustek", host: "nut.local", port: 3500, ratedWatts: 400))
        XCTAssertNil(try draft(c, name: "  ").upsName)
        XCTAssertEqual(c.draft(upsName: "x", host: "h", port: "34a", upscPath: nil), .failure(.invalid([.portOutOfRange])))
    }

    func testEveryIssueHasAMessage() {
        let issues: [SettingsIssue] = [.upsNameEmpty, .upsNameInvalidCharacters, .upsNameLeadingHyphen, .hostEmpty,
                                       .hostInvalidCharacters, .hostLeadingHyphen, .hostIPv6NotSupported, .portOutOfRange,
                                       .upscPathNotAbsolute, .upscPathNotFound, .upscPathNotExecutable,
                                       .ratedWattsNotFinite, .ratedWattsOutOfRange, .storedValueCorrupted(.port)]
        XCTAssertTrue(issues.allSatisfy { !$0.message.isEmpty })
        XCTAssertTrue(SettingsCheckFailure.upsc(.notFound(searched: [])).message.contains("brew install nut"))
    }

    // MARK: Discovery

    func testDiscoveryListsValidNames() async throws {
        fake.answers["-l 127.0.0.1:3493"] = .output("mustek\nbad name\n\nups2\n")
        let c = controller()
        let result = await c.discover(try draft(c, name: ""))
        XCTAssertEqual(result, .success(["mustek", "ups2"]))
        XCTAssertEqual(fake.calls, [["-l", "127.0.0.1:3493"]])
    }

    func testDiscoveryFailures() async throws {
        fake.answers["-l 127.0.0.1:3493"] = .failed(1, "Error: Connection failure: Connection refused")
        let c = controller()
        let refused = await c.discover(try draft(c))
        XCTAssertEqual(refused, .failure(.connection(L10n.tr("upsd unavailable"))))
        let badHost = await c.discover(try draft(c, host: "-x"))
        XCTAssertEqual(badHost, .failure(.invalid([.hostLeadingHyphen])))
        let noUpsc = await controller(candidates: []).discover(try draft(c))
        XCTAssertEqual(noUpsc, .failure(.upsc(.notFound(searched: []))))
        XCTAssertEqual(fake.calls.count, 1, "invalid input and missing upsc never run anything")
    }

    // MARK: Check

    func testSuccessfulCheckReportsReadingAndVersion() async throws {
        fake.answers["mustek@127.0.0.1:3493"] = .output(sampleOL)
        let c = controller()
        let result = await c.check(try draft(c))
        XCTAssertEqual(result, .success(SettingsCheckReport(upscPath: upsc, target: "mustek@127.0.0.1:3493", status: "OL",
                                                            input: 230, load: 5,
                                                            version: "Network UPS Tools upsc 2.8.5 release")))
        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(backend.object(forKey: SettingsStore.Key.upsName.rawValue), "a check never saves")
    }

    func testFailedChecks() async throws {
        let c = controller()
        let unknown = await c.check(try draft(c))
        XCTAssertEqual(unknown, .failure(.connection(L10n.tr("UPS not found in upsd"))))
        let noName = await c.check(try draft(c, name: ""))
        XCTAssertEqual(noName, .failure(.noUpsName))
        fake.answers["mustek@127.0.0.1:3493"] = .output("ups.status: OL\n")
        let partial = await c.check(try draft(c))
        XCTAssertEqual(partial, .failure(.invalidResponse))
        fake.answers["mustek@127.0.0.1:3493"] = .timedOut
        let slow = await c.check(try draft(c))
        XCTAssertEqual(slow, .failure(.connection(L10n.tr("timeout"))))
        let badPath = await c.check(try draft(c, path: root.appendingPathComponent("absent").path))
        XCTAssertEqual(badPath, .failure(.invalid([.upscPathNotFound])))
    }

    func testVersionFailureDoesNotFailTheCheck() async throws {
        fake.answers["-V"] = .timedOut
        fake.answers["mustek@127.0.0.1:3493"] = .output(sampleOL)
        let c = controller()
        let result = await c.check(try draft(c))
        XCTAssertNil(try result.get().version)
    }

    // MARK: Save

    func testSaveStoresAndAppliesOnlyAfterSuccessfulCheck() async throws {
        fake.answers["mustek@127.0.0.1:3493"] = .output(sampleOL)
        let c = controller()
        let d = try draft(c)
        _ = try await c.save(d).get()
        XCTAssertEqual(applied, [d])
        XCTAssertEqual(c.current, d)
        // Reloads as saved.
        XCTAssertEqual(SettingsStore(defaults: backend).load().settings, d)
    }

    func testFailedSaveKeepsSettingsInEffect() async throws {
        fake.answers["mustek@127.0.0.1:3493"] = .output(sampleOL)
        let c = controller()
        let working = try draft(c)
        _ = try await c.save(working).get()

        let broken = try draft(c, name: "other")
        let result = await c.save(broken)
        XCTAssertEqual(result, .failure(.connection(L10n.tr("UPS not found in upsd"))))
        XCTAssertEqual(c.current, working)
        XCTAssertEqual(applied, [working])
        XCTAssertEqual(SettingsStore(defaults: backend).load().settings, working)

        let invalid = await c.save(try draft(c, host: "bad host"))
        XCTAssertEqual(invalid, .failure(.invalid([.hostInvalidCharacters])))
        XCTAssertEqual(SettingsStore(defaults: backend).load().settings, working)
    }

    func testSavingAnotherUpsSwitchesMonitorWithoutMixingOutages() async throws {
        let data = root.appendingPathComponent("data", isDirectory: true)
        let monitor = Monitor(settings: Settings(upsName: "upsA"), historyDirectory: data,
                              locator: UpscLocator(candidates: []))
        monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.6)), at: Date())
        let c = SettingsController(current: monitor.settings, store: SettingsStore(defaults: backend),
                                   locator: UpscLocator(candidates: [upsc]), execute: fake.execute) { monitor.apply($0) }
        fake.answers["upsB@127.0.0.1:3493"] = .output(sampleOL)
        _ = try await c.save(try draft(c, name: "upsB")).get()
        XCTAssertEqual(monitor.connection?.target, "upsB@127.0.0.1:3493")
        XCTAssertNil(monitor.currentOutage)
        monitor.handle(.output(sampleOL), at: Date())
        let events = try String(contentsOf: data.appendingPathComponent("power_events.csv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false)[1] }
        XCTAssertEqual(events, ["OB", "CFG"])
    }
    func testRatedPowerFieldValidationSaveAndClear() async throws {
        let c = controller(current: Settings(upsName: "mustek", ratedWatts: 400))
        func powerDraft(_ text: String) -> Result<Settings, SettingsCheckFailure> {
            c.draft(upsName: "mustek", host: "127.0.0.1", port: "3493", upscPath: nil, ratedWatts: text)
        }
        XCTAssertEqual(try powerDraft(" 650,5 ").get().ratedWatts, 650.5)
        XCTAssertNil(try powerDraft("").get().ratedWatts)
        for text in ["0", "-1", "100001"] {
            XCTAssertEqual(powerDraft(text), .failure(.invalid([.ratedWattsOutOfRange])))
        }
        for text in ["nan", "inf", "not-a-number"] {
            XCTAssertEqual(powerDraft(text), .failure(.invalid([.ratedWattsNotFinite])))
        }
        fake.answers["mustek@127.0.0.1:3493"] = .output(sampleOL)
        _ = try await c.save(try powerDraft("600").get()).get()
        XCTAssertEqual(SettingsStore(defaults: backend).load().settings.ratedWatts, 600)
        XCTAssertEqual(applied.last?.ratedWatts, 600)
        _ = try await c.save(try powerDraft("").get()).get()
        XCTAssertNil(SettingsStore(defaults: backend).load().settings.ratedWatts)
        XCTAssertNil(applied.last?.ratedWatts)
    }
}

final class AppIdentityTests: XCTestCase {
    func testBuildIdentity() {
        let directory = Monitor.defaultDirectory.path
        #if MUSTEK_QA
        XCTAssertTrue(AppIdentity.isQA)
        XCTAssertEqual(AppIdentity.dataDirectoryName, "MustekMenuMonitor-QA")
        XCTAssertEqual(AppIdentity.settingsSuite, "local.mustek.menumanager.qa.settings")
        XCTAssertEqual(AppIdentity.titlePrefix, "QA · ")
        XCTAssertTrue(directory.hasSuffix("/Library/Application Support/MustekMenuMonitor-QA"))
        #else
        XCTAssertFalse(AppIdentity.isQA)
        XCTAssertEqual(AppIdentity.dataDirectoryName, "MustekMenuMonitor")
        XCTAssertNil(AppIdentity.settingsSuite)
        XCTAssertEqual(AppIdentity.titlePrefix, "")
        XCTAssertTrue(directory.hasSuffix("/Library/Application Support/MustekMenuMonitor"))
        #endif
    }
}
