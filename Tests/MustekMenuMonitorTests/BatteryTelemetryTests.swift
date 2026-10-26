import XCTest
@testable import MustekMenuMonitor

@MainActor final class BatteryTelemetryTests: XCTestCase {
    private var directory: URL!
    private let now = Date()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MustekBattery-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func telemetry(_ fields: [String: String], status: String = "OL") -> String {
        sample(status: status).split(separator: "\n").filter { !$0.hasPrefix("battery.") }
            .map(String.init).joined(separator: "\n") + "\n" + fields.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func model(_ raw: String) -> MenuModel {
        let m = Monitor(settings: Settings(upsName: "example-ups"), historyDirectory: directory)
        m.handle(.output(raw), at: now)
        return MenuModel.make(m.snapshot(now: now))
    }

    private func battery(_ model: MenuModel) throws -> [String: String] {
        let section = try XCTUnwrap(model.sections.first { $0.title == "Аккумулятор" })
        return Dictionary(uniqueKeysWithValues: section.rows.map { ($0.label, $0.value) })
    }

    func testAllBatteryFieldsComeFromNut() throws {
        let raw = telemetry(["battery.voltage": "12.7", "battery.charge": "76.5", "battery.runtime": "1800"])
        let reading = try XCTUnwrap(Reading.parse(raw, at: now))
        XCTAssertEqual(reading.batteryVoltage, 12.7)
        XCTAssertEqual(reading.batteryCharge, 76.5)
        XCTAssertEqual(reading.batteryRuntime, 1800)
        let values = try battery(model(raw))
        XCTAssertEqual(values["Напряжение"], "12,7 В")
        XCTAssertEqual(values["Заряд"], "76,5 %")
        XCTAssertEqual(values["Оставшееся время (NUT)"], "1800 с")
        XCTAssertEqual(values["Режим"], "От сети")
    }

    func testPartialBatteryFieldsDoNotInventTheMissingValues() throws {
        let raw = telemetry(["battery.charge": "50"])
        let values = try battery(model(raw))
        XCTAssertEqual(values["Заряд"], "50 %")
        XCTAssertEqual(values["Напряжение"], "Нет данных")
        XCTAssertEqual(values["Оставшееся время (NUT)"], "Нет данных")
    }

    func testAbsentBatteryFieldsShowNoDataAndNoDemonstrationProfile() throws {
        let raw = telemetry([:])
        let reading = try XCTUnwrap(Reading.parse(raw, at: now))
        XCTAssertNil(reading.batteryVoltage)
        XCTAssertNil(reading.batteryCharge)
        XCTAssertNil(reading.batteryRuntime)
        let values = try battery(model(raw))
        XCTAssertEqual(values.count, 4)
        for label in ["Напряжение", "Заряд", "Оставшееся время (NUT)"] {
            XCTAssertEqual(values[label], "Нет данных")
        }
        for label in ["Номинальная ёмкость", "Номинальная энергия", "Установлен", "Расчётный заряд", "Мин. напряжение"] {
            XCTAssertNil(values[label])
        }
        let visible = model(raw).sections.flatMap { [$0.title] + $0.rows.map { $0.label + $0.value } }.joined(separator: "\n")
        for demonstration in ["Demo GEL", "01.01.2000", "108 Вт·ч", "не откалиброван", "10,5 В — ориентир"] {
            XCTAssertFalse(visible.contains(demonstration))
        }
    }

    func testReportedZerosRemainDistinctFromMissingFields() throws {
        let raw = telemetry(["battery.voltage": "0", "battery.charge": "0", "battery.runtime": "0"])
        let reading = try XCTUnwrap(Reading.parse(raw, at: now))
        XCTAssertEqual(reading.batteryVoltage, 0)
        XCTAssertEqual(reading.batteryCharge, 0)
        XCTAssertEqual(reading.batteryRuntime, 0)
        let values = try battery(model(raw))
        XCTAssertEqual(values["Напряжение"], "0,0 В")
        XCTAssertEqual(values["Заряд"], "0 %")
        XCTAssertEqual(values["Оставшееся время (NUT)"], "0 с")
    }

    func testMalformedAndStaleBatteryValuesAreNotDisplayed() throws {
        let raw = telemetry(["battery.voltage": "nan", "battery.charge": "unknown", "battery.runtime": "inf"])
        let values = try battery(model(raw))
        for label in ["Напряжение", "Заряд", "Оставшееся время (NUT)"] {
            XCTAssertEqual(values[label], "Нет данных")
        }
        let m = Monitor(historyDirectory: directory)
        m.handle(.output(telemetry(["battery.voltage": "12", "battery.charge": "80", "battery.runtime": "600"])), at: now)
        m.handle(.timedOut, at: now.addingTimeInterval(5))
        let stale = try battery(MenuModel.make(m.snapshot()))
        for label in ["Напряжение", "Заряд", "Оставшееся время (NUT)"] {
            XCTAssertEqual(stale[label], "Нет данных")
        }
    }

    func testStatusesAndOutageCsvRemainCompatibleWithoutBatteryFields() throws {
        let m = Monitor(settings: Settings(upsName: "example-ups", ratedWatts: 400), historyDirectory: directory)
        for (i, status) in ["OL", "OB", "OB LB", "OL"].enumerated() {
            let raw = telemetry([:], status: status)
            let reading = try XCTUnwrap(Reading.parse(raw, at: now))
            XCTAssertEqual(reading.online, status == "OL")
            XCTAssertEqual(reading.onBattery, status.contains("OB"))
            XCTAssertEqual(reading.lowBattery, status.contains("LB"))
            m.handle(.output(raw), at: now.addingTimeInterval(Double(i) * 5))
            let visible = MenuModel.make(m.snapshot())
            if status == "OB LB" {
                XCTAssertTrue(visible.header.contains("низкий заряд"))
                XCTAssertTrue(visible.statusBarTitle.contains("Нет данных"))
                XCTAssertTrue(visible.statusBarTitle.hasSuffix("OB LB"))
            }
        }
        XCTAssertNil(m.currentOutage)
        XCTAssertNotNil(m.lastOutage)
        let history = try String(contentsOf: directory.appendingPathComponent("history.csv"))
        let rows = history.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0.count == 8 })
        XCTAssertEqual(rows[0].joined(separator: ",") + "\n", Monitor.historyHeader)
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0[7].isEmpty })
        let events = try String(contentsOf: directory.appendingPathComponent("power_events.csv"))
        let eventRows = events.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        XCTAssertEqual(eventRows[0].joined(separator: ",") + "\n", PowerEventLog.header)
        XCTAssertTrue(eventRows.allSatisfy { $0.count == 9 })
        XCTAssertEqual(eventRows.dropFirst().map { String($0[1]) }, ["OB", "OL"])
    }
}
