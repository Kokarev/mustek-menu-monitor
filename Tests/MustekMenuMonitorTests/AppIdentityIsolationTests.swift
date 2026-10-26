import XCTest
@testable import MustekMenuMonitor

/// Identity checks only: never open the real production/QA data files or write their defaults.
@MainActor final class AppIdentityIsolationTests: XCTestCase {
    func testExactDefaultDirectoryHasOneApplicationSupportComponent() {
        #if MUSTEK_QA
        let name = "MustekMenuMonitor-QA"
        #else
        let name = "MustekMenuMonitor"
        #endif
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        XCTAssertEqual(Monitor.defaultDirectory.path, expected.path)
        XCTAssertEqual(Monitor.defaultDirectory.appendingPathComponent(".lock").path,
                       expected.appendingPathComponent(".lock").path)
        // These tests also run with the old QA environment overrides deliberately set.
        XCTAssertFalse(Monitor.defaultDirectory.path.contains("ignored-qa-environment"))
    }

    func testSettingsFactorySelectsTheBuildDomainWithoutWriting() throws {
        let selected = AppIdentity.settingsDefaults()
        #if MUSTEK_QA
        let suite = try XCTUnwrap(AppIdentity.settingsSuite)
        XCTAssertNotEqual(suite, "local.mustek.menumanager")
        XCTAssertNotEqual(suite, "local.mustek.menumanager.qa")
        XCTAssertFalse(selected === UserDefaults.standard)
        let expected = try XCTUnwrap(UserDefaults(suiteName: suite))
        for key in SettingsStore.Key.allCases {
            XCTAssertEqual(selected.object(forKey: key.rawValue) as? NSObject,
                           expected.object(forKey: key.rawValue) as? NSObject)
        }
        #else
        XCTAssertNil(AppIdentity.settingsSuite)
        XCTAssertTrue(selected === UserDefaults.standard)
        #endif
    }

    func testIndependentDataAndLocksInDisposableDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MustekIdentityIsolation-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let publicData = root.appendingPathComponent("MustekMenuMonitor")
        let qaData = root.appendingPathComponent("MustekMenuMonitor-QA")
        let publicLock = InstanceLock.acquire(at: publicData.appendingPathComponent(".lock"))
        let qaLock = InstanceLock.acquire(at: qaData.appendingPathComponent(".lock"))
        guard case .acquired = publicLock, case .acquired = qaLock else {
            return XCTFail("separate data directories must allow independent instances")
        }
        guard case .heldElsewhere = InstanceLock.acquire(at: qaData.appendingPathComponent(".lock")) else {
            return XCTFail("the second QA instance must still be refused")
        }
        let publicMonitor = Monitor(settings: Settings(upsName: "public-example"), historyDirectory: publicData)
        let qaMonitor = Monitor(settings: Settings(upsName: "qa-example"), historyDirectory: qaData)
        publicMonitor.handle(.output(sample(status: "OL")), at: Date())
        let history = try Data(contentsOf: publicData.appendingPathComponent("history.csv"))
        qaMonitor.handle(.output(sample(status: "OB")), at: Date())
        XCTAssertEqual(try Data(contentsOf: publicData.appendingPathComponent("history.csv")), history)
        XCTAssertFalse(fm.fileExists(atPath: publicData.appendingPathComponent("power_events.csv").path))
        for name in [".lock", "history.csv", "power_events.csv", "open_outage_ups.txt"] {
            XCTAssertTrue(fm.fileExists(atPath: qaData.appendingPathComponent(name).path), name)
        }
        withExtendedLifetime((publicLock, qaLock)) {}
    }
}
