import XCTest
@testable import UPSMenuBar

final class SettingsValidationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustek-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, mode: Int) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    private func issues(_ change: (inout Settings) -> Void) -> [SettingsIssue] {
        var settings = Settings()
        change(&settings)
        return settings.validate()
    }

    func testDefaultsAreUnconfiguredAndValid() {
        let settings = Settings()
        XCTAssertNil(settings.upsName)
        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertEqual(settings.port, 3493)
        XCTAssertNil(settings.upscPath)
        XCTAssertNil(settings.ratedWatts)
        XCTAssertEqual(settings.validate(), [])
        XCTAssertEqual(settings.nutTarget(), .failure(.notConfigured))
    }

    func testUpsNames() {
        for name in ["mustek", "UPS_1", "a.b-c", "X", "0"] {
            XCTAssertEqual(issues { $0.upsName = name }, [], name)
        }
        XCTAssertEqual(issues { $0.upsName = "" }, [.upsNameEmpty])
        XCTAssertEqual(issues { $0.upsName = "-x" }, [.upsNameLeadingHyphen])
        for name in ["my ups", "ups@host", "ups:1", "ups/1", "ИБП", "ups\n", "ups\t1", "ups;rm"] {
            XCTAssertEqual(issues { $0.upsName = name }, [.upsNameInvalidCharacters], name)
        }
    }

    func testHosts() {
        for host in ["127.0.0.1", "localhost", "nut.example.org", "10.0.0.250", "ups-server"] {
            XCTAssertEqual(issues { $0.host = host }, [], host)
        }
        XCTAssertEqual(issues { $0.host = "" }, [.hostEmpty])
        XCTAssertEqual(issues { $0.host = "-h" }, [.hostLeadingHyphen])
        for host in ["my host", "host\n", "\u{7}host", "host/x", "user@host", "host_name"] {
            XCTAssertEqual(issues { $0.host = host }, [.hostInvalidCharacters], host)
        }
        for host in ["::1", "[::1]", "fe80::1%en0", "127.0.0.1:3493"] {
            XCTAssertEqual(issues { $0.host = host }, [.hostIPv6NotSupported], host)
        }
    }

    func testPortBounds() {
        for port in [1, 3493, 65535] { XCTAssertEqual(issues { $0.port = port }, [], "\(port)") }
        for port in [0, -1, 65536, Int.max, Int.min] {
            XCTAssertEqual(issues { $0.port = port }, [.portOutOfRange], "\(port)")
        }
    }

    func testUpscPath() throws {
        let executable = try file("upsc", mode: 0o755)
        let plain = try file("upsc-plain", mode: 0o644)
        XCTAssertEqual(issues { $0.upscPath = executable }, [])
        XCTAssertEqual(issues { $0.upscPath = plain }, [.upscPathNotExecutable])
        XCTAssertEqual(issues { $0.upscPath = self.directory.path }, [.upscPathNotExecutable])
        XCTAssertEqual(issues { $0.upscPath = self.directory.appendingPathComponent("absent").path }, [.upscPathNotFound])
        XCTAssertEqual(issues { $0.upscPath = "bin/upsc" }, [.upscPathNotAbsolute])
        XCTAssertEqual(issues { $0.upscPath = "upsc" }, [.upscPathNotAbsolute])
        XCTAssertEqual(issues { $0.upscPath = "" }, [.upscPathNotAbsolute])
        XCTAssertEqual(issues { $0.upscPath = "/bin/up\0sc" }, [.upscPathNotAbsolute])
    }

    func testUpscPathIsNotExecuted() throws {
        // A script that would leave a marker if validation ran it.
        let marker = directory.appendingPathComponent("ran")
        let url = directory.appendingPathComponent("upsc-marker")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        var settings = Settings()
        settings.upscPath = url.path
        XCTAssertEqual(settings.validate(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUpscPathFileChecksCanBeSkipped() {
        var settings = Settings()
        settings.upscPath = "/nonexistent/upsc"
        XCTAssertEqual(settings.validate(), [.upscPathNotFound])
        XCTAssertEqual(settings.validate(checkFileSystem: false), [])
        settings.upscPath = "relative/upsc"
        XCTAssertEqual(settings.validate(checkFileSystem: false), [.upscPathNotAbsolute])
    }

    func testRatedWatts() {
        for watts in [nil, 1, 400, 100_000, 0.5 + 0.5] as [Double?] {
            XCTAssertEqual(issues { $0.ratedWatts = watts }, [], "\(String(describing: watts))")
        }
        for watts in [0, -1, -400, 0.99, 100_000.01] as [Double] {
            XCTAssertEqual(issues { $0.ratedWatts = watts }, [.ratedWattsOutOfRange], "\(watts)")
        }
        for watts in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(issues { $0.ratedWatts = watts }, [.ratedWattsNotFinite], "\(watts)")
        }
    }

    func testAllProblemsAreReportedWithFields() {
        let settings = Settings(upsName: "-bad name", host: "", port: 0, upscPath: "rel", ratedWatts: .nan)
        let found = settings.validate()
        XCTAssertEqual(found, [.upsNameLeadingHyphen, .upsNameInvalidCharacters, .hostEmpty, .portOutOfRange,
                               .upscPathNotAbsolute, .ratedWattsNotFinite])
        XCTAssertEqual(Set(found.map(\.field)), Set(SettingsField.allCases))
    }

    func testNutTarget() {
        XCTAssertEqual(Settings(upsName: "mustek").nutTarget(), .success("mustek@127.0.0.1:3493"))
        XCTAssertEqual(Settings(upsName: "ups1", host: "nut.example.org", port: 3500).nutTarget(),
                       .success("ups1@nut.example.org:3500"))
        XCTAssertEqual(Settings(upsName: nil, host: "nut.example.org").nutTarget(), .failure(.notConfigured))
        XCTAssertEqual(Settings(upsName: "-x").nutTarget(), .failure(.invalid([.upsNameLeadingHyphen])))
        XCTAssertEqual(Settings(upsName: "ups", port: 70000).nutTarget(), .failure(.invalid([.portOutOfRange])))
        XCTAssertEqual(Settings(upsName: "ups", host: "::1").nutTarget(), .failure(.invalid([.hostIPv6NotSupported])))
        // An invalid host is reported even before a UPS name is set.
        XCTAssertEqual(Settings(host: "").nutTarget(), .failure(.invalid([.hostEmpty])))
        // The target depends only on connection fields, not on upsc or the rating.
        XCTAssertEqual(Settings(upsName: "ups", upscPath: "/absent/upsc", ratedWatts: .nan).nutTarget(),
                       .success("ups@127.0.0.1:3493"))
    }
}

/// In-memory backend. Uniquely named UserDefaults suites cannot be cleaned up reliably:
/// cfprefsd writes an empty plist for a removed domain after the test has finished.
final class InMemoryDefaults: SettingsBackend {
    private(set) var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
}

final class SettingsStoreTests: XCTestCase {
    /// The installed application's domain; tests must never write to it.
    static let productionDomain = "local.mustek.menumanager"

    /// The one real suite used by tests; a fixed name keeps at most one empty plist on disk.
    static let testSuite = "test.mustek.settings"

    private var defaults: InMemoryDefaults!
    private var store: SettingsStore!

    override func setUp() {
        defaults = InMemoryDefaults()
        store = SettingsStore(defaults: defaults)
    }

    func testRealUserDefaultsSuiteRoundTrip() throws {
        XCTAssertNotEqual(Self.testSuite, Self.productionDomain)
        let suite = try XCTUnwrap(UserDefaults(suiteName: Self.testSuite))
        suite.removePersistentDomain(forName: Self.testSuite)
        defer { suite.removePersistentDomain(forName: Self.testSuite) }
        let settings = Settings(upsName: "mustek", host: "nut.example.org", port: 3500,
                                upscPath: "/opt/homebrew/bin/upsc", ratedWatts: 650.5)
        try SettingsStore(defaults: suite).save(settings)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: Self.testSuite))
        let result = SettingsStore(defaults: reopened).load()
        XCTAssertEqual(result.settings, settings)
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.issues, [])
        suite.set(true, forKey: SettingsStore.Key.port.rawValue)
        XCTAssertEqual(SettingsStore(defaults: suite).load().issues, [.storedValueCorrupted(.port)])
    }

    func testEmptyStoreLoadsDefaultsAndReportsAllKeysMissing() {
        let result = store.load()
        XCTAssertEqual(result.settings, Settings())
        XCTAssertEqual(result.missing, Set(SettingsStore.Key.allCases))
        XCTAssertEqual(result.issues, [])
    }

    func testRoundTrip() throws {
        let settings = Settings(upsName: "mustek", host: "nut.example.org", port: 3500,
                                upscPath: "/opt/homebrew/bin/upsc", ratedWatts: 400)
        try store.save(settings)
        let result = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(result.settings, settings)
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.issues, [])
    }

    func testNilFieldsAreRemovedAndExplicitDefaultsAreStored() throws {
        try store.save(Settings(upsName: "ups", upscPath: "/usr/local/bin/upsc", ratedWatts: 600))
        try store.save(Settings(upsName: "ups"))
        let result = store.load()
        XCTAssertEqual(result.settings, Settings(upsName: "ups"))
        // Host and port were written explicitly even though they equal the defaults.
        XCTAssertEqual(result.missing, [.upscPath, .ratedWatts])
        XCTAssertEqual(defaults.string(forKey: SettingsStore.Key.host.rawValue), "127.0.0.1")
    }

    func testRatedWattsTypesSurviveRoundTrip() throws {
        for watts in [1, 400, 650.5, 100_000] as [Double] {
            try store.save(Settings(upsName: "ups", ratedWatts: watts))
            XCTAssertEqual(store.load().settings.ratedWatts, watts)
        }
    }

    func testInvalidSettingsAreNotSaved() throws {
        try store.save(Settings(upsName: "good", ratedWatts: 400))
        XCTAssertThrowsError(try store.save(Settings(upsName: "bad name", port: 0))) { error in
            XCTAssertEqual(error as? SettingsStore.SaveError, .invalid([.upsNameInvalidCharacters, .portOutOfRange]))
        }
        // Nothing of the rejected settings was written.
        XCTAssertEqual(store.load().settings, Settings(upsName: "good", ratedWatts: 400))
    }

    func testSaveDoesNotRequireUpscToExist() throws {
        try store.save(Settings(upsName: "ups", upscPath: "/absent/upsc"))
        let result = store.load()
        XCTAssertEqual(result.settings.upscPath, "/absent/upsc")
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.settings.validate(), [.upscPathNotFound])
    }

    func testWrongTypesFallBackToDefaults() {
        defaults.set(42, forKey: SettingsStore.Key.upsName.rawValue)
        defaults.set(["a"], forKey: SettingsStore.Key.host.rawValue)
        defaults.set("3493", forKey: SettingsStore.Key.port.rawValue)
        defaults.set(Data([1, 2]), forKey: SettingsStore.Key.upscPath.rawValue)
        defaults.set("400", forKey: SettingsStore.Key.ratedWatts.rawValue)
        let result = store.load()
        XCTAssertEqual(result.settings, Settings())
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.issues, SettingsField.allCases.map { .storedValueCorrupted($0) })
    }

    func testBooleansAndFractionsAreNotNumbers() {
        defaults.set(true, forKey: SettingsStore.Key.port.rawValue)
        defaults.set(false, forKey: SettingsStore.Key.ratedWatts.rawValue)
        var result = store.load()
        XCTAssertEqual(result.settings.port, 3493)
        XCTAssertNil(result.settings.ratedWatts)
        XCTAssertEqual(result.issues, [.storedValueCorrupted(.port), .storedValueCorrupted(.ratedWatts)])

        defaults.set(3493.5, forKey: SettingsStore.Key.port.rawValue)
        result = store.load()
        XCTAssertEqual(result.settings.port, 3493)
        XCTAssertEqual(result.issues.first, .storedValueCorrupted(.port))
    }

    func testInvalidStoredValuesFallBackPerField() {
        defaults.set("bad name", forKey: SettingsStore.Key.upsName.rawValue)
        defaults.set("::1", forKey: SettingsStore.Key.host.rawValue)
        defaults.set(70000, forKey: SettingsStore.Key.port.rawValue)
        defaults.set("relative/upsc", forKey: SettingsStore.Key.upscPath.rawValue)
        defaults.set(Double.infinity, forKey: SettingsStore.Key.ratedWatts.rawValue)
        let result = store.load()
        XCTAssertEqual(result.settings, Settings())
        XCTAssertEqual(result.issues, [.upsNameInvalidCharacters, .hostIPv6NotSupported, .portOutOfRange,
                                       .upscPathNotAbsolute, .ratedWattsNotFinite])
        XCTAssertEqual(result.settings.nutTarget(), .failure(.notConfigured))
    }

    func testOneBadFieldKeepsTheOthers() {
        defaults.set("mustek", forKey: SettingsStore.Key.upsName.rawValue)
        defaults.set("nut.example.org", forKey: SettingsStore.Key.host.rawValue)
        defaults.set(-5, forKey: SettingsStore.Key.port.rawValue)
        defaults.set(0, forKey: SettingsStore.Key.ratedWatts.rawValue)
        let result = store.load()
        XCTAssertEqual(result.settings, Settings(upsName: "mustek", host: "nut.example.org"))
        XCTAssertEqual(result.missing, [.upscPath])
        XCTAssertEqual(result.issues, [.portOutOfRange, .ratedWattsOutOfRange])
        XCTAssertEqual(result.settings.nutTarget(), .success("mustek@nut.example.org:3493"))
    }

    func testResetRemovesOnlySettingsKeys() throws {
        defaults.set("keep", forKey: "unrelated")
        try store.save(Settings(upsName: "ups", ratedWatts: 400))
        store.reset()
        XCTAssertEqual(store.load().missing, Set(SettingsStore.Key.allCases))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testSuitesAreIsolatedAndProductionDomainIsUntouched() throws {
        let production = UserDefaults.standard.persistentDomain(forName: Self.productionDomain) as NSDictionary?
        let other = InMemoryDefaults()

        try store.save(Settings(upsName: "first", ratedWatts: 400))
        try SettingsStore(defaults: other).save(Settings(upsName: "second"))
        XCTAssertEqual(store.load().settings.upsName, "first")
        XCTAssertEqual(SettingsStore(defaults: other).load().settings.upsName, "second")

        // Settings keys never reach the test process's standard domain or the installed app's domain.
        for key in SettingsStore.Key.allCases {
            XCTAssertNil(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key.rawValue])
        }
        let after = UserDefaults.standard.persistentDomain(forName: Self.productionDomain) as NSDictionary?
        XCTAssertEqual(after, production)
        for key in SettingsStore.Key.allCases { XCTAssertNil(after?[key.rawValue]) }
    }
}
