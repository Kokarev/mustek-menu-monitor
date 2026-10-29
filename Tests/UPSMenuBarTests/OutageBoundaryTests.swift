import XCTest
@testable import UPSMenuBar

/// Outage events across a change of UPS, at runtime and between launches.
@MainActor final class OutageBoundaryTests: XCTestCase {
    private var directory: URL!
    private let upsA = Settings(upsName: "upsA")
    private let upsB = Settings(upsName: "upsB")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MustekOutageTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func monitor(_ settings: Settings) -> Monitor {
        Monitor(settings: settings, historyDirectory: directory, locator: UpscLocator(candidates: []))
    }

    /// Event column of each power_events.csv row, header excluded; every row must keep 9 columns.
    private func events() -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("power_events.csv"), encoding: .utf8)) ?? ""
        let rows = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        XCTAssertEqual(rows.first.map { $0.joined(separator: ",") + "\n" }, PowerEventLog.header)
        XCTAssertTrue(rows.allSatisfy { $0.count == 9 })
        return rows.dropFirst().map { String($0[1]) }
    }

    private var ownerFile: String { directory.appendingPathComponent("open_outage_ups.txt").path }

    private func onBattery(_ m: Monitor, at seconds: TimeInterval, battery: Double = 12.6) {
        m.handle(.output(sample(status: "OB", input: 0, battery: battery)), at: t0.addingTimeInterval(seconds))
    }

    private func onMains(_ m: Monitor, at seconds: TimeInterval) {
        m.handle(.output(sample(status: "OL")), at: t0.addingTimeInterval(seconds))
    }

    // MARK: Runtime switch

    func testSwitchFromBatteryToUpsOnMainsDoesNotConfirmReturn() throws {
        let m = monitor(upsA)
        onBattery(m, at: 0, battery: 12.8)
        onBattery(m, at: 5, battery: 12.5)
        XCTAssertEqual(m.outageOwner, "upsA@127.0.0.1:3493")
        XCTAssertEqual(try String(contentsOfFile: ownerFile, encoding: .utf8), "upsA@127.0.0.1:3493\n")

        m.apply(upsB)
        onMains(m, at: 10)
        XCTAssertEqual(events(), ["OB", "CFG"])
        XCTAssertNil(m.currentOutage)
        XCTAssertNil(m.lastOutage, "an interrupted outage is not shown as a finished one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile))

        let cfg = try XCTUnwrap(String(contentsOf: directory.appendingPathComponent("power_events.csv"), encoding: .utf8)
            .split(separator: "\n").last).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // No status and no duration: nothing confirms that power returned.
        XCTAssertEqual(Array(cfg[1...]), ["CFG", "", "", "", "12.8", "12.5", "12.5", ""])
    }

    func testSwitchFromBatteryToUpsOnBatteryStartsItsOwnOutage() {
        let m = monitor(upsA)
        onBattery(m, at: 0)
        m.apply(upsB)
        onBattery(m, at: 10, battery: 12.1)
        XCTAssertEqual(events(), ["OB", "CFG", "OB"])
        XCTAssertEqual(m.currentOutage?.start, t0.addingTimeInterval(10))
        XCTAssertEqual(m.currentOutage?.startVoltage, 12.1)
        XCTAssertEqual(m.outageOwner, "upsB@127.0.0.1:3493")
        onMains(m, at: 20)
        XCTAssertEqual(events(), ["OB", "CFG", "OB", "OL"])
        XCTAssertEqual(m.lastOutage?.duration(now: t0), 10)
    }

    func testSwitchToNotConfiguredAlsoEndsObservation() {
        let m = monitor(upsA)
        onBattery(m, at: 0)
        m.apply(Settings())
        XCTAssertEqual(events(), ["OB", "CFG"])
        XCTAssertNil(m.currentOutage)
    }

    func testChangingOnlyUpscPathKeepsTheOutage() {
        let m = monitor(upsA)
        onBattery(m, at: 0)
        m.apply(Settings(upsName: "upsA", upscPath: "/usr/local/bin/upsc"))
        onMains(m, at: 10)
        XCTAssertEqual(events(), ["OB", "OL"])
    }

    // MARK: Between launches

    func testUpsChangedBetweenLaunches() {
        onBattery(monitor(upsA), at: 0)
        let restarted = monitor(upsB)
        XCTAssertNotNil(restarted.currentOutage, "restored until a reading decides")
        XCTAssertEqual(restarted.outageOwner, "upsA@127.0.0.1:3493")
        onMains(restarted, at: 30)
        XCTAssertEqual(events(), ["OB", "CFG"])
        XCTAssertNil(restarted.lastOutage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile))
    }

    func testSameUpsAcrossRestartContinuesTheOutage() {
        let first = monitor(upsA)
        onBattery(first, at: 0, battery: 12.9)
        let restarted = monitor(upsA)
        onBattery(restarted, at: 30, battery: 12.4)
        onMains(restarted, at: 35)
        XCTAssertEqual(events(), ["OB", "OL"])
        XCTAssertEqual(restarted.lastOutage?.duration(now: t0), 35)
        XCTAssertEqual(restarted.lastOutage?.startVoltage, 12.9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile))
    }

    func testRestoredOutageTakesHistoryVoltagesOnlyFromItsOwnUps() {
        let first = monitor(upsA)
        onBattery(first, at: 0, battery: 12.8)
        onBattery(first, at: 5, battery: 12.0)
        XCTAssertEqual(monitor(upsA).currentOutage?.minVoltage, 12.0, "same UPS: history samples are restored")
        let other = monitor(upsB)
        XCTAssertEqual(other.currentOutage?.minVoltage, 12.8, "other UPS: only what power_events.csv recorded")
        XCTAssertEqual(other.currentOutage?.lastVoltage, 12.8)
    }

    func testRestartAfterCfgDoesNotReopen() {
        let m = monitor(upsA)
        onBattery(m, at: 0)
        m.apply(upsB)
        for settings in [upsA, upsB] {
            let restarted = monitor(settings)
            XCTAssertNil(restarted.currentOutage)
            XCTAssertNil(restarted.lastOutage)
        }
        let restarted = monitor(upsA)
        onMains(restarted, at: 20)
        XCTAssertEqual(events(), ["OB", "CFG"])
    }

    func testCfgKeepsTheEarlierFinishedOutageAsLast() {
        let m = monitor(upsA)
        onBattery(m, at: 0)
        onMains(m, at: 10)
        onBattery(m, at: 20)
        m.apply(upsB)
        XCTAssertEqual(m.lastOutage?.duration(now: t0), 10)
        XCTAssertEqual(monitor(upsB).lastOutage?.duration(now: t0), 10)
        XCTAssertEqual(events(), ["OB", "OL", "OB", "CFG"])
    }

    // MARK: Normal cycle and old history

    func testNormalCycleWithoutSwitch() {
        let m = monitor(upsA)
        onMains(m, at: 0)
        onBattery(m, at: 5, battery: 12.8)
        onBattery(m, at: 65, battery: 12.5)
        onMains(m, at: 70)
        XCTAssertEqual(events(), ["OB", "OL"])
        XCTAssertEqual(m.lastOutage?.duration(now: t0), 65)
        XCTAssertNil(m.currentOutage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile))
    }

    func testOldHistoryWithoutOwnerIsNotConfirmedByAnyUps() throws {
        // power_events.csv as written by 0.1.3: an open OB, no owner file.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        try (PowerEventLog.header + "\(iso.string(from: t0)),OB,OB,12.7,,,,,\n")
            .write(to: directory.appendingPathComponent("power_events.csv"), atomically: true, encoding: .utf8)
        let m = monitor(upsA)
        XCTAssertNotNil(m.currentOutage)
        XCTAssertNil(m.outageOwner)
        onMains(m, at: 60)
        XCTAssertEqual(events(), ["OB", "CFG"])
        XCTAssertNil(m.lastOutage)
    }

    func testOldFinishedHistoryLoadsAsBefore() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let rows = PowerEventLog.header
            + "\(iso.string(from: t0)),OB,OB,12.7,,,,,\n"
            + "\(iso.string(from: t0.addingTimeInterval(120))),OL,OL,13.1,120,12.7,12.3,12.3,12.0\n"
        try rows.write(to: directory.appendingPathComponent("power_events.csv"), atomically: true, encoding: .utf8)
        let m = monitor(upsA)
        XCTAssertNil(m.currentOutage)
        XCTAssertEqual(m.lastOutage?.duration(now: t0), 120)
        XCTAssertEqual(m.lastOutage?.minVoltage, 12.3)
        onMains(m, at: 200)
        XCTAssertEqual(events(), ["OB", "OL"])
    }

    func testHistoryFormatIsUnchanged() {
        let m = monitor(upsA)
        onBattery(m, at: 0)
        m.apply(upsB)
        onMains(m, at: 10)
        let text = (try? String(contentsOf: directory.appendingPathComponent("history.csv"), encoding: .utf8)) ?? ""
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.first.map { $0 + "\n" }, Monitor.historyHeader)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 8 })
    }
}
