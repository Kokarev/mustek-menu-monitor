import XCTest
@testable import MustekMenuMonitor

@MainActor final class PowerTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MustekPower-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func monitor(_ rating: Double?) -> Monitor {
        Monitor(settings: Settings(upsName: "example-ups", ratedWatts: rating), historyDirectory: directory)
    }

    private func rows() throws -> [[String]] {
        try String(contentsOf: directory.appendingPathComponent("history.csv"))
            .split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private func value(_ model: MenuModel, _ label: String) -> String? {
        model.sections.flatMap(\.rows).first { $0.label == label }?.value
    }

    func testEstimatesUseConfiguredRatingAndDistinguishUnknownFromZero() throws {
        let quarter = try XCTUnwrap(Reading.parse(sample(load: 25), at: t0))
        let half = try XCTUnwrap(Reading.parse(sample(load: 50), at: t0))
        let zero = try XCTUnwrap(Reading.parse(sample(load: 0), at: t0))
        XCTAssertEqual(quarter.estimatedWatts(ratedWatts: 400), 100)
        XCTAssertEqual(half.estimatedWatts(ratedWatts: 600), 300)
        XCTAssertNil(zero.estimatedWatts(ratedWatts: nil))
        XCTAssertEqual(zero.estimatedWatts(ratedWatts: 600), 0)
        for rating in [0, -1, Double.infinity, Double.nan] {
            XCTAssertNil(half.estimatedWatts(ratedWatts: rating))
        }
        XCTAssertNil(Reading.parse(sample(load: 101), at: t0)?.estimatedWatts(ratedWatts: 600))
    }

    func testUnknownPowerAndEnergyRemainEmptyInEightColumnCsv() throws {
        let m = monitor(nil)
        m.handle(.output(sample(load: 0)), at: t0)
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(5))
        let csv = try rows()
        XCTAssertEqual(csv[0].joined(separator: ",") + "\n", Monitor.historyHeader)
        for row in csv.dropFirst() {
            XCTAssertEqual(row.count, 8)
            XCTAssertEqual(row[5], "")
            XCTAssertEqual(row[6], "")
        }
        XCTAssertEqual(m.todayWh, 0)
        XCTAssertEqual(m.monthWh, 0)
        let model = MenuModel.make(m.snapshot())
        XCTAssertEqual(value(model, L10n.tr("Power")), L10n.tr("Power not configured"))
        XCTAssertEqual(value(model, L10n.tr("Today")), L10n.tr("Not configured"))
        XCTAssertTrue(model.statusBarTitle.contains(L10n.tr("power not configured")))
        XCTAssertFalse(model.note.contains("400"))
        XCTAssertEqual(monitor(nil).sampleCount, 2, "unknown Wh must not hide telemetry on reload")
    }

    func testConfiguredZeroLoadRecordsActualZeroAndKnownEnergy() throws {
        let m = monitor(600)
        m.handle(.output(sample(load: 0)), at: t0)
        m.handle(.output(sample(load: 0)), at: t0.addingTimeInterval(5))
        let csv = try rows()
        XCTAssertEqual(csv[1][5], "0.0")
        XCTAssertEqual(csv[1][6], "", "a first point has no confirmed interval")
        XCTAssertEqual(csv[2][5], "0.0")
        XCTAssertEqual(csv[2][6], "0.0")
        m.apply(Settings(upsName: "example-ups"))
        XCTAssertEqual(value(MenuModel.make(m.snapshot()), L10n.tr("Today")), Format.value(0, L10n.tr("kWh"), digits: 3, approx: true))
    }

    func testRatingChangeBreaksIntegrationAndRefreshesMenuWithoutRewritingHistory() throws {
        let m = monitor(400)
        m.handle(.output(sample(load: 25)), at: t0)
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(5))
        let firstEnergy = 100.0 * 5 / 3600
        XCTAssertEqual(m.todayWh, firstEnergy, accuracy: 1e-12)
        let path = directory.appendingPathComponent("history.csv")
        let oldHistory = try Data(contentsOf: path)
        var notifications = 0
        m.onChange = { notifications += 1 }
        let generation = m.generation
        m.apply(Settings(upsName: "example-ups", ratedWatts: 600))
        XCTAssertEqual(m.generation, generation)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(value(MenuModel.make(m.snapshot()), L10n.tr("Power")), Format.value(150, L10n.tr("W"), digits: 0, approx: true))
        XCTAssertEqual(try Data(contentsOf: path), oldHistory)
        m.handle(.output(sample(load: 50)), at: t0.addingTimeInterval(10))
        XCTAssertEqual(try rows()[3][6], "")
        XCTAssertEqual(m.todayWh, firstEnergy, accuracy: 1e-12)
        m.handle(.output(sample(load: 50)), at: t0.addingTimeInterval(15))
        XCTAssertEqual(m.todayWh, firstEnergy + 300.0 * 5 / 3600, accuracy: 1e-12)
        XCTAssertTrue(try Data(contentsOf: path).starts(with: oldHistory))
        XCTAssertEqual(monitor(nil).todayWh, m.todayWh, accuracy: 1e-12)
    }

    func testUnknownIntervalsAndRepeatedRatingChangesNeverBridgeEnergy() throws {
        let m = monitor(400)
        m.handle(.output(sample(load: 25)), at: t0)
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(5))
        let initial = m.todayWh
        m.apply(Settings(upsName: "example-ups"))
        m.handle(.output(sample(load: 100)), at: t0.addingTimeInterval(10))
        m.handle(.output(sample(load: 100)), at: t0.addingTimeInterval(15))
        m.apply(Settings(upsName: "example-ups", ratedWatts: 600))
        m.apply(Settings(upsName: "example-ups", ratedWatts: 400))
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(20))
        let csv = try rows()
        for i in [3, 4] { XCTAssertEqual(csv[i][5], ""); XCTAssertEqual(csv[i][6], "") }
        XCTAssertEqual(csv[5][6], "")
        XCTAssertEqual(m.todayWh, initial)
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(25))
        XCTAssertEqual(m.todayWh, initial + 100.0 * 5 / 3600, accuracy: 1e-12)
    }

    func testHistoricalWhRemainVisibleWithNoCurrentRating() throws {
        let timestamp = ISO8601DateFormatter().string(from: t0)
        let old = Monitor.historyHeader + "\(timestamp),OL,230,230,25,100,1250,13.5\n"
        let path = directory.appendingPathComponent("history.csv")
        try old.write(to: path, atomically: true, encoding: .utf8)
        let m = monitor(nil)
        XCTAssertEqual(m.todayWh, 1250)
        XCTAssertEqual(m.monthWh, 1250)
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(5))
        m.handle(.output(sample(load: 25)), at: t0.addingTimeInterval(10))
        let model = MenuModel.make(m.snapshot())
        XCTAssertEqual(value(model, L10n.tr("Power")), L10n.tr("Power not configured"))
        XCTAssertEqual(value(model, L10n.tr("Today")), Format.value(1.25, L10n.tr("kWh"), digits: 3, approx: true))
        XCTAssertEqual(value(model, L10n.tr("This month")), Format.value(1.25, L10n.tr("kWh"), digits: 3, approx: true))
        XCTAssertTrue(try String(contentsOf: path).hasPrefix(old))
        let reloaded = monitor(nil)
        XCTAssertEqual(reloaded.todayWh, 1250)
        XCTAssertEqual(reloaded.monthWh, 1250)
        XCTAssertEqual(reloaded.sampleCount, 3)
        XCTAssertTrue(try rows().allSatisfy { $0.count == 8 })
    }
}
