import XCTest
@testable import MustekMenuMonitor

@MainActor final class LocalizationTests: XCTestCase {
    private func catalog(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(AppLocalization.resources.url(forResource: language, withExtension: "lproj"))
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testSystemLanguageMatchingAndEnglishFallback() {
        for (preference, expected) in [("en-GB", "en"), ("uk-UA", "uk"), ("de-DE", "de"), ("ru-RU", "ru"), ("fr-FR", "en"), ("ja-JP", "en")] {
            XCTAssertEqual(AppLocalization(preferences: [preference]).language, expected)
        }
        XCTAssertEqual(AppLocalization(preferences: ["uk-UA", "en-GB"]).language, "uk")
        XCTAssertEqual(AppLocalization(preferences: ["de-DE", "ru-RU"]).language, "de")
        XCTAssertEqual(AppLocalization(preferences: ["fr-FR"]).text("No data"), "No data")
    }

    func testFourCompleteCatalogsAndNaturalTranslations() throws {
        let base = try catalog("en")
        XCTAssertGreaterThan(base.count, 100)
        for language in AppLocalization.supported {
            let strings = try catalog(language)
            XCTAssertEqual(Set(strings.keys), Set(base.keys), language)
            for (key, value) in strings {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count,
                               base[key]!.components(separatedBy: "%@").count, "\(language): \(key)")
            }
        }
        let expected = ["en": ["Mains", "Save", "No data"],
                        "uk": ["Електромережа", "Зберегти", "Немає даних"],
                        "de": ["Stromnetz", "Speichern", "Keine Daten"],
                        "ru": ["Электросеть", "Сохранить", "Нет данных"]]
        for language in AppLocalization.supported {
            let localizer = AppLocalization(preferences: [language])
            XCTAssertEqual(["Mains", "Save", "No data"].map(localizer.text), expected[language])
            XCTAssertTrue(localizer.format("status %@", ["OB LB"]).contains("OB LB"))
        }
    }

    func testVisibleSourceStringsHaveResourcesAndNoHardcodedCyrillic() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/MustekMenuMonitor")
        let keys = Set(try catalog("en").keys)
        let lookup = try NSRegularExpression(pattern: #"L10n\.(?:tr|format)\("((?:\\.|[^"\\])*)""#)
        let cyrillic = try NSRegularExpression(pattern: #""[^"\n]*[А-Яа-яЁёІіЇїЄєҐґ][^"\n]*""#)
        for url in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let source = try String(contentsOf: url)
            let range = NSRange(source.startIndex..., in: source)
            XCTAssertEqual(cyrillic.numberOfMatches(in: source, range: range), 0, url.lastPathComponent)
            for match in lookup.matches(in: source, range: range) {
                let key = String(source[Range(match.range(at: 1), in: source)!])
                XCTAssertTrue(keys.contains(key), "Untranslated UI lookup: \(key)")
            }
        }
    }

    /// D-1: in Russian "Output" and "Quit" are both «Выход», so the output-voltage row once picked up the "Quit" key.
    func testOutputVoltageRowUsesTheOutputKey() throws {
        let snapshot = MonitorSnapshot(link: .waiting, reading: nil, lastSuccess: nil, todayWh: 0, monthWh: 0,
                                       currentOutage: nil, lastOutage: nil, now: Date())
        let mains = try XCTUnwrap(MenuModel.make(snapshot).sections.first)
        XCTAssertEqual(mains.rows.map(\.label), [L10n.tr("Input"), L10n.tr("Output"), L10n.tr("Frequency")])
        for language in ["en", "uk", "de"] {
            let localizer = AppLocalization(preferences: [language])
            XCTAssertNotEqual(localizer.text("Output"), localizer.text("Quit"), language)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MustekMenuMonitor/MenuModel.swift"))
        let outputRow = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("r?.output") })
        XCTAssertTrue(outputRow.contains(#"L10n.tr("Output")"#), String(outputRow))
    }

    func testNumbersDatesAndInputFollowTheRequestedSystemLocale() {
        XCTAssertEqual(Format.number(1234.5, digits: 1...1, locale: Locale(identifier: "en_GB")), "1234.5")
        for locale in ["uk_UA", "de_DE", "ru_RU"] {
            XCTAssertEqual(Format.number(1234.5, digits: 1...1, locale: Locale(identifier: locale)), "1234,5")
            XCTAssertEqual(Format.inputNumber(650.5, locale: Locale(identifier: locale)), "650,5")
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["en_GB", "uk_UA", "de_DE", "ru_RU"] {
            let locale = Locale(identifier: name)
            let expected = DateFormatter(); expected.locale = locale; expected.dateStyle = .short; expected.timeStyle = .medium
            XCTAssertEqual(Format.dateTime(date, locale: locale), expected.string(from: date))
        }
    }

    func testCsvAndNutCodesStayTechnicalWhileTheMenuIsLocalized() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MustekLocalization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = Monitor(settings: Settings(upsName: "example", ratedWatts: 400), historyDirectory: directory)
        let now = Date()
        monitor.handle(.output(sample(status: "OB LB", load: 25, battery: 12.5)), at: now)
        monitor.handle(.output(sample(status: "OL", load: 25, battery: 13.5)), at: now.addingTimeInterval(5))
        let csv = try String(contentsOf: directory.appendingPathComponent("history.csv"))
        XCTAssertTrue(csv.hasPrefix("timestamp,status,input_V,output_V,load_percent,estimated_W,delta_Wh,battery_V\n"))
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        XCTAssertEqual(rows[1][1], "OB LB")
        XCTAssertEqual(rows[1][5], "100.0")
        XCTAssertEqual(rows[1][7], "12.5")
        XCTAssertTrue(rows.allSatisfy { $0.count == 8 })
        let events = try String(contentsOf: directory.appendingPathComponent("power_events.csv"))
        XCTAssertTrue(events.hasPrefix(PowerEventLog.header))
        XCTAssertTrue(events.contains(",OB,OB LB,"))
        XCTAssertTrue(events.contains(",OL,OL,"))
        XCTAssertTrue(MenuModel.make(monitor.snapshot()).statusBarTitle.contains("≈"))
    }

    func testLocalizationDoesNotChangeIdentitySettingsOrQaMarker() {
        #if MUSTEK_QA
        XCTAssertEqual(AppIdentity.titlePrefix, "QA · ")
        XCTAssertEqual(AppIdentity.dataDirectoryName, "MustekMenuMonitor-QA")
        XCTAssertEqual(AppIdentity.settingsSuite, "local.mustek.menumanager.qa.settings")
        #else
        XCTAssertEqual(AppIdentity.titlePrefix, "")
        XCTAssertEqual(AppIdentity.dataDirectoryName, "MustekMenuMonitor")
        XCTAssertNil(AppIdentity.settingsSuite)
        #endif
        for language in AppLocalization.supported {
            let title = "QA · " + AppLocalization(preferences: [language]).text("On mains")
            XCTAssertTrue(title.hasPrefix("QA · "))
        }
        XCTAssertEqual(SettingsStore.Key.upsName.rawValue, "nut.upsName")
        XCTAssertEqual(SettingsStore.Key.ratedWatts.rawValue, "power.ratedWatts")
    }
}
