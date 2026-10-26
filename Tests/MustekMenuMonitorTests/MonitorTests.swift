import XCTest
@testable import MustekMenuMonitor

/// Synthetic NUT response for parser and presentation tests; no device capture.
let sampleOL = """
battery.voltage: 13.5
device.type: ups
driver.name: nutdrv_qx
driver.state: quiet
driver.version: 2.8.5
input.frequency: 50.0
input.voltage: 230.0
input.voltage.fault: 225.0
output.voltage: 230.0
ups.beeper.status: enabled
ups.load: 5
ups.status: OL
ups.temperature: 25.0
ups.type: offline / line interactive
"""

func sample(status: String = "OL", input: Double = 230.0, load: Double = 5, battery: Double = 13.5) -> String {
    sampleOL
        .replacingOccurrences(of: "ups.status: OL", with: "ups.status: \(status)")
        .replacingOccurrences(of: "input.voltage: 230.0", with: "input.voltage: \(input)")
        .replacingOccurrences(of: "ups.load: 5", with: "ups.load: \(load)")
        .replacingOccurrences(of: "battery.voltage: 13.5", with: "battery.voltage: \(battery)")
}

@MainActor final class MonitorTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MustekMenuMonitorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0) }
    }

    // MARK: Parsing (UI-05)

    func testParseValidSample() throws {
        let r = try XCTUnwrap(Reading.parse(sampleOL, at: Date()))
        XCTAssertEqual(r.status, "OL")
        XCTAssertEqual(r.input, 230.0)
        XCTAssertEqual(r.output, 230.0)
        XCTAssertEqual(r.frequency, 50.0)
        XCTAssertEqual(r.load, 5)
        XCTAssertEqual(r.estimatedWatts(ratedWatts: 400), 20)
        XCTAssertEqual(r.batteryVoltage, 13.5)
        XCTAssertNil(r.batteryCharge)
        XCTAssertEqual(r.temperature, 25)
        XCTAssertEqual(r.driverState, "quiet")
    }

    func testParseRejectsEmptyMalformedOrIncomplete() {
        XCTAssertNil(Reading.parse("", at: Date()))
        XCTAssertNil(Reading.parse("Error: Data stale", at: Date()))
        XCTAssertNil(Reading.parse("ups.status: OL\n", at: Date()))
        XCTAssertNil(Reading.parse(sampleOL.replacingOccurrences(of: "input.voltage: 230.0", with: ""), at: Date()))
        XCTAssertNil(Reading.parse(sampleOL.replacingOccurrences(of: "ups.load: 5", with: "ups.load: n/a"), at: Date()))
        XCTAssertNil(Reading.parse(sampleOL.replacingOccurrences(of: "ups.status: OL", with: "ups.status: "), at: Date()))
    }

    func testFailureMessagesMapToLinkStates() {
        XCTAssertEqual(LinkState.forFailure(message: "Error: Data stale\n"), .stale)
        XCTAssertEqual(LinkState.forFailure(message: "Error: Driver not connected"), .noResponse(L10n.tr("driver not connected")))
        XCTAssertEqual(LinkState.forFailure(message: "Error: Connection failure: Connection refused"), .noResponse(L10n.tr("upsd unavailable")))
        XCTAssertEqual(LinkState.forFailure(message: "Error: Unknown UPS"), .noResponse(L10n.tr("UPS not found in upsd")))
        XCTAssertEqual(LinkState.forFailure(message: "something else"), .noResponse(L10n.tr("upsc error")))
    }

    // MARK: History (UI-06)

    func testValidReadingKeepsHistoryFormat() throws {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let t0 = Date()
        monitor.handle(.output(sampleOL), at: t0)
        let rows = lines("history.csv")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0] + "\n", "timestamp,status,input_V,output_V,load_percent,estimated_W,delta_Wh,battery_V\n")
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(Array(fields[1...]), ["OL", "230.0", "230.0", "5.0", "20.0", "", "13.5"])
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(monitor.lastSuccess, t0)
    }

    func testEnergyIntegrationUnchanged() throws {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let t0 = Date()
        monitor.handle(.output(sample(load: 6)), at: t0)
        monitor.handle(.output(sample(load: 6)), at: t0.addingTimeInterval(5))
        let expected = 24.0 * 5 / 3600
        XCTAssertEqual(monitor.todayWh, expected, accuracy: 1e-12)
        let delta = try XCTUnwrap(Double(lines("history.csv")[2].split(separator: ",")[6]))
        XCTAssertEqual(delta, expected, accuracy: 1e-12)
    }

    func testFailureBreaksIntegrationWithoutGapFill() throws {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let t0 = Date()
        monitor.handle(.output(sampleOL), at: t0)
        monitor.handle(.timedOut, at: t0.addingTimeInterval(5))
        monitor.handle(.output(sampleOL), at: t0.addingTimeInterval(10))
        let rows = lines("history.csv")
        XCTAssertEqual(rows.count, 3, "a failed poll must not write a row")
        XCTAssertEqual(rows[2].split(separator: ",", omittingEmptySubsequences: false)[6], "", "no energy may be estimated across the gap")
        XCTAssertEqual(monitor.todayWh, 0)
    }

    func testTotalsReloadedFromHistory() throws {
        let t0 = Date()
        do {
            let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
            monitor.handle(.output(sample(load: 6)), at: t0)
            monitor.handle(.output(sample(load: 6)), at: t0.addingTimeInterval(5))
        }
        let reloaded = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        XCTAssertEqual(reloaded.todayWh, 24.0 * 5 / 3600, accuracy: 1e-12)
        XCTAssertEqual(reloaded.sampleCount, 2)
    }

    // MARK: Connection state (UI-04, UI-05)

    func testInvalidResponseIsNotAnUpdate() {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let t0 = Date()
        monitor.handle(.output(sampleOL), at: t0)
        monitor.handle(.output("ups.status: OL\n"), at: t0.addingTimeInterval(5))
        XCTAssertEqual(monitor.link, .invalid)
        XCTAssertEqual(monitor.lastSuccess, t0)
        XCTAssertNil(monitor.freshReading)
        XCTAssertEqual(lines("history.csv").count, 2)
        let model = MenuModel.make(monitor.snapshot(now: t0.addingTimeInterval(5)))
        XCTAssertTrue(model.header.contains(L10n.tr("Invalid NUT response")))
        XCTAssertEqual(value(model, L10n.tr("Input")), "—")
        XCTAssertEqual(value(model, L10n.tr("Last update")), Format.time(t0))
        XCTAssertEqual(model.statusBarTitle, "⚠️ \(L10n.tr("UPS")) —")
    }

    func testNoResponseHidesValues() {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        monitor.handle(.output(sampleOL), at: Date())
        monitor.handle(.failed(1, "Error: Connection failure: Connection refused"), at: Date())
        let model = MenuModel.make(monitor.snapshot())
        XCTAssertTrue(model.header.contains(L10n.tr("No NUT response")))
        XCTAssertEqual(value(model, "NUT"), L10n.format("no response (%@)", L10n.tr("upsd unavailable")))
        XCTAssertEqual(value(model, L10n.tr("Voltage")), L10n.tr("No data"))
        XCTAssertEqual(value(model, L10n.tr("Power")), "—")
    }

    func testStaleDataByAgeAndByNUT() {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let t0 = Date()
        monitor.handle(.output(sampleOL), at: t0)
        monitor.checkStaleness(now: t0.addingTimeInterval(Monitor.staleAfter))
        XCTAssertEqual(monitor.link, .ok, "exactly at the limit the reading is still current")
        monitor.checkStaleness(now: t0.addingTimeInterval(Monitor.staleAfter + 1))
        XCTAssertEqual(monitor.link, .stale)
        XCTAssertNil(monitor.freshReading)
        XCTAssertTrue(MenuModel.make(monitor.snapshot()).header.contains(L10n.tr("Data stale")))

        monitor.handle(.output(sampleOL), at: t0.addingTimeInterval(20))
        monitor.handle(.failed(1, "Error: Data stale"), at: t0.addingTimeInterval(25))
        XCTAssertEqual(monitor.link, .stale)
    }

    // MARK: Battery and outages (BATTERY-01, stage A)

    func testOutageTransitionsAreLoggedAndRestored() throws {
        let t0 = Date()
        do {
            let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
            monitor.handle(.output(sample(status: "OL")), at: t0)
            monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.8)), at: t0.addingTimeInterval(5))
            XCTAssertNotNil(monitor.currentOutage)
            monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.6)), at: t0.addingTimeInterval(65))
            monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.5)), at: t0.addingTimeInterval(125))
            monitor.handle(.output(sample(status: "OL")), at: t0.addingTimeInterval(130))
            XCTAssertNil(monitor.currentOutage)
            let outage = try XCTUnwrap(monitor.lastOutage)
            XCTAssertEqual(outage.duration(now: Date()), 125, accuracy: 0.001)
            XCTAssertEqual(outage.minVoltage, 12.5)
            XCTAssertEqual(try XCTUnwrap(outage.dropRatePerHour), 0.3 / (120.0 / 3600), accuracy: 1e-9)
        }
        let events = lines("power_events.csv")
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0] + "\n", PowerEventLog.header)
        XCTAssertTrue(events[1].contains(",OB,OB,12.8,"))
        XCTAssertTrue(events[2].contains(",OL,OL,13.5,125,12.8,12.5,12.5,"))

        let reloaded = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        XCTAssertNil(reloaded.currentOutage)
        let restored = try XCTUnwrap(reloaded.lastOutage)
        XCTAssertEqual(restored.duration(now: Date()), 125, accuracy: 1)
        XCTAssertEqual(restored.minVoltage, 12.5)
        XCTAssertEqual(try XCTUnwrap(restored.dropRatePerHour), 9, accuracy: 1e-6)
    }

    func testOpenOutageSurvivesRestart() throws {
        let t0 = Date()
        do {
            let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
            monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.9)), at: t0)
            monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.4)), at: t0.addingTimeInterval(60))
        }
        let reloaded = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let open = try XCTUnwrap(reloaded.currentOutage)
        XCTAssertEqual(open.minVoltage, 12.4, "minimum is recovered from history.csv")
        reloaded.handle(.output(sample(status: "OB", input: 0, battery: 12.3)), at: t0.addingTimeInterval(65))
        XCTAssertEqual(lines("power_events.csv").count, 2, "no second OB start after restart")
        XCTAssertEqual(reloaded.currentOutage?.minVoltage, 12.3)
    }

    func testOutageEndAfterMonitoringGapIsLowerBound() throws {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let t0 = Date()
        monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.8)), at: t0)
        monitor.handle(.output(sample(status: "OB", input: 0, battery: 12.7)), at: t0.addingTimeInterval(5))
        monitor.handle(.output(sample(status: "OL")), at: t0.addingTimeInterval(600))
        XCTAssertEqual(try XCTUnwrap(monitor.lastOutage).duration(now: Date()), 5, accuracy: 0.001)
    }

    // MARK: Presentation (UI-02, UI-03)

    func testStatusBarTitles() {
        let ol = Reading.parse(sample(load: 6, battery: 13.5).replacingOccurrences(of: "230.0", with: "228.9"), at: Date())
        XCTAssertEqual(MenuModel.barTitle(for: ol, ratedWatts: 400), "⚡ \(Format.value(229, L10n.tr("V"), digits: 0)) · \(Format.value(24, L10n.tr("W"), digits: 0, approx: true)) · 6%")
        let ob = Reading.parse(sample(status: "OB DISCHRG", input: 0, load: 6, battery: 12.4), at: Date())
        XCTAssertEqual(MenuModel.barTitle(for: ob, ratedWatts: 400), "🔋 \(Format.value(12.4, L10n.tr("V"), digits: 1)) · \(Format.value(24, L10n.tr("W"), digits: 0, approx: true)) · OB")
        let lb = Reading.parse(sample(status: "OB LB", input: 0, load: 6, battery: 10.9), at: Date())
        XCTAssertEqual(MenuModel.barTitle(for: lb, ratedWatts: 400), "🔋 \(Format.value(10.9, L10n.tr("V"), digits: 1)) · \(Format.value(24, L10n.tr("W"), digits: 0, approx: true)) · OB LB")
        XCTAssertEqual(MenuModel.barTitle(for: nil), "⚠️ \(L10n.tr("UPS")) —")
    }

    func testMenuValuesUseRussianFormatting() {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        monitor.handle(.output(sampleOL), at: Date())
        let model = MenuModel.make(monitor.snapshot())
        XCTAssertEqual(model.header, "MUSTEK \(L10n.tr("UPS")) — 🟢 \(L10n.tr("On mains"))")
        XCTAssertEqual(value(model, L10n.tr("Input")), Format.value(230, L10n.tr("V"), digits: 1))
        XCTAssertEqual(value(model, L10n.tr("Quit")), Format.value(230, L10n.tr("V"), digits: 1))
        XCTAssertEqual(value(model, L10n.tr("Frequency")), Format.value(50, L10n.tr("Hz"), digits: 1))
        XCTAssertEqual(value(model, L10n.tr("Load")), "5%")
        XCTAssertEqual(value(model, L10n.tr("Power")), Format.value(20, L10n.tr("W"), digits: 0, approx: true))
        XCTAssertEqual(value(model, L10n.tr("Voltage")), Format.value(13.5, L10n.tr("V"), digits: 1))
        XCTAssertEqual(value(model, L10n.tr("Mode")), L10n.tr("On mains"))
        XCTAssertEqual(value(model, L10n.tr("Charge")), L10n.tr("No data"))
        XCTAssertEqual(value(model, L10n.tr("Remaining runtime (NUT)")), L10n.tr("No data"))
        XCTAssertEqual(value(model, L10n.tr("Last outage")), L10n.tr("not recorded"))
        XCTAssertEqual(value(model, L10n.tr("UPS")), "25 °C")
        XCTAssertEqual(value(model, L10n.tr("Today")), Format.value(0, L10n.tr("kWh"), digits: 3, approx: true))
        XCTAssertEqual(value(model, "NUT"), L10n.tr("connected"))
        XCTAssertEqual(value(model, L10n.tr("Driver")), "quiet")
        XCTAssertEqual(model.sections.first { $0.title.hasPrefix(L10n.tr("Battery")) }?.title, L10n.tr("Battery"))
    }

    func testMenuLayoutIsTheSameInEveryState() {
        let monitor = Monitor(settings: Settings(ratedWatts: 400), historyDirectory: directory)
        let shape = { (m: MenuModel) in m.sections.map { "\($0.rows.count)" } }
        let waiting = shape(MenuModel.make(monitor.snapshot()))
        monitor.handle(.output(sampleOL), at: Date())
        XCTAssertEqual(shape(MenuModel.make(monitor.snapshot())), waiting)
        monitor.handle(.timedOut, at: Date())
        XCTAssertEqual(shape(MenuModel.make(monitor.snapshot())), waiting)
    }

    private func value(_ model: MenuModel, _ label: String) -> String? {
        model.sections.flatMap(\.rows).first { $0.label == label }?.value
    }
}
