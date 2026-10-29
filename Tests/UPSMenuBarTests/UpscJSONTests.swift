import XCTest
@testable import UPSMenuBar

/// `upsc -j` parsing and the fallback to plain output. Fake upsc scripts only; no device.
final class UpscJSONTests: XCTestCase {
    private var directory: URL!

    /// JSON as `upsc -j` prints it (NUT 2.8.5): a flat object of strings. One value carries
    /// quotes, a backslash, a newline and a colon to prove they stay inside that value.
    static let sampleJSON = #"""
    {
      "battery.voltage": "13.5",
      "device.type": "ups",
      "driver.name": "nutdrv_qx",
      "driver.state": "quiet",
      "driver.version": "2.8.5",
      "input.frequency": "50.0",
      "input.voltage": "230.0",
      "input.voltage.fault": "225.0",
      "output.voltage": "230.0",
      "ups.beeper.status": "enabled",
      "ups.load": "5",
      "ups.model": "Line \"A\" \\ B\nC: D",
      "ups.status": "OL",
      "ups.temperature": "25.0",
      "ups.type": "offline / line interactive"
    }
    """#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpscJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sampleOL.write(to: file("text"), atomically: true, encoding: .utf8)
        try Self.sampleJSON.write(to: file("json"), atomically: true, encoding: .utf8)
        JSONSupport.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        JSONSupport.reset()
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// A fake upsc that logs its arguments and runs `body` with $1 … set.
    private func upsc(_ body: String) throws -> String {
        let url = file("upsc")
        try "#!/bin/sh\necho \"$*\" >> '\(file("calls").path)'\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private var calls: [String] {
        ((try? String(contentsOf: file("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func output(_ outcome: UpscOutcome) throws -> String {
        guard case .output(let raw) = outcome else { throw XCTSkip("not an output: \(outcome)") }
        return raw
    }

    // MARK: Parsing

    func testJSONParsesLikeText() throws {
        let json = try XCTUnwrap(Reading.parse(Self.sampleJSON, at: Date()))
        let text = try XCTUnwrap(Reading.parse(sampleOL, at: Date()))
        XCTAssertEqual(json.status, text.status)
        XCTAssertEqual(json.input, text.input)
        XCTAssertEqual(json.output, text.output)
        XCTAssertEqual(json.load, text.load)
        XCTAssertEqual(json.batteryVoltage, text.batteryVoltage)
        XCTAssertEqual(json.frequency, text.frequency)
        XCTAssertEqual(json.temperature, text.temperature)
        XCTAssertEqual(json.driverState, "quiet")
        XCTAssertNil(json.batteryCharge)
        XCTAssertNil(json.batteryRuntime)
    }

    func testEscapedCharactersStayInsideTheirValue() throws {
        let object = try XCTUnwrap(Reading.jsonObject(Self.sampleJSON))
        XCTAssertEqual(object["ups.model"], "Line \"A\" \\ B\nC: D")
        XCTAssertEqual(object["ups.status"], "OL")
        XCTAssertEqual(object.count, 15, "no key is invented from the newline or the colon")
    }

    func testNumbersAreAcceptedNextToStrings() throws {
        let r = try XCTUnwrap(Reading.parse(#"{"ups.status": "OL OB", "input.voltage": 229.5, "ups.load": 7}"#, at: Date()))
        XCTAssertEqual(r.input, 229.5)
        XCTAssertEqual(r.load, 7)
        XCTAssertTrue(r.onBattery)
    }

    func testNonObjectOrBrokenJSONIsRejected() {
        XCTAssertNil(Reading.jsonObject("[1, 2]"))
        XCTAssertNil(Reading.jsonObject(#"{"ups.status": "OL""#))
        XCTAssertNil(Reading.jsonObject("usage: upsc [-j] -l | -L [<hostname>[:port]]"))
        XCTAssertNil(Reading.parse("[1, 2]", at: Date()))
        XCTAssertNil(Reading.parse(#"{"ups.status": "OL""#, at: Date()))
        XCTAssertNil(Reading.parse("usage: upsc [-j] -l | -L [<hostname>[:port]]", at: Date()))
        XCTAssertNil(Reading.parse(#"{"ups.status": "OL", "ups.load": "5"}"#, at: Date()), "input.voltage required")
    }

    func testNestedValuesAreIgnored() throws {
        let r = try XCTUnwrap(Reading.parse(
            #"{"ups.status": "OL", "input.voltage": "230", "ups.load": "5", "x": {"a": 1}, "y": [1], "z": null}"#, at: Date()))
        XCTAssertEqual(r.input, 230)
    }

    func testPlainTextAcceptsCRLFAndKeepsColonsInValues() throws {
        let r = try XCTUnwrap(Reading.parse("ups.status: OL\r\ninput.voltage: 230.0\r\nups.load: 5\r\ndriver.state: a: b\r\n",
                                            at: Date()))
        XCTAssertEqual(r.input, 230)
        XCTAssertEqual(r.driverState, "a: b")
    }

    // MARK: Fallback in Upsc.run

    func testRunPrefersJSONWhenUpscSupportsIt() async throws {
        let path = try upsc("if [ \"$1\" = -j ]; then cat '\(file("json").path)'; else cat '\(file("text").path)'; fi")
        let raw = try output(await Upsc.run(path: path, target: "ups@h:3493"))
        XCTAssertNotNil(Reading.jsonObject(raw))
        XCTAssertEqual(calls, ["-j ups@h:3493"])
        _ = await Upsc.run(path: path, target: "ups@h:3493")
        XCTAssertEqual(calls, ["-j ups@h:3493", "-j ups@h:3493"], "JSON stays in use")
    }

    func testOldUpscPrintingUsageFallsBackToTextAndRemembers() async throws {
        // NUT before -j: unknown option → usage on stdout, exit 0.
        let path = try upsc("if [ \"$1\" = -j ]; then echo 'usage: upsc -l | -L [<hostname>[:port]]'; exit 0; fi; cat '\(file("text").path)'")
        let raw = try output(await Upsc.run(path: path, target: "ups"))
        XCTAssertNil(Reading.jsonObject(raw))
        XCTAssertNotNil(Reading.parse(raw, at: Date()))
        XCTAssertEqual(calls, ["-j ups", "ups"])
        _ = await Upsc.run(path: path, target: "ups")
        XCTAssertEqual(calls, ["-j ups", "ups", "ups"], "no second -j attempt for this path")
    }

    func testOptionErrorFallsBackToText() async throws {
        let path = try upsc("if [ \"$1\" = -j ]; then echo \"upsc: illegal option -- j\" >&2; exit 1; fi; cat '\(file("text").path)'")
        let raw = try output(await Upsc.run(path: path, target: "ups"))
        XCTAssertNotNil(Reading.parse(raw, at: Date()))
        XCTAssertEqual(calls, ["-j ups", "ups"])
        XCTAssertFalse(JSONSupport.isEnabled(path))
    }

    func testBrokenJSONFallsBackToTextForThisPollOnly() async throws {
        let path = try upsc("if [ \"$1\" = -j ]; then echo '{\"ups.status\": \"OL\", \"x\": \"a\"b\"}'; exit 0; fi; cat '\(file("text").path)'")
        let raw = try output(await Upsc.run(path: path, target: "ups"))
        XCTAssertNotNil(Reading.parse(raw, at: Date()))
        XCTAssertEqual(calls, ["-j ups", "ups"])
        XCTAssertTrue(JSONSupport.isEnabled(path), "damaged JSON does not switch the path")
        _ = await Upsc.run(path: path, target: "ups")
        XCTAssertEqual(calls, ["-j ups", "ups", "-j ups", "ups"], "the next poll tries -j again")
    }

    func testJSONRecoversAfterOneDamagedReply() async throws {
        // First -j reply is cut short (e.g. a truncated read); later replies are whole.
        let path = try upsc("""
            if [ "$1" = -j ]; then
              if [ -f '\(file("damaged-once").path)' ]; then cat '\(file("json").path)'
              else touch '\(file("damaged-once").path)'; echo '{"ups.status": "OL", "input.volt'; fi
              exit 0
            fi
            cat '\(file("text").path)'
            """)
        let first = try output(await Upsc.run(path: path, target: "ups"))
        XCTAssertNil(Reading.jsonObject(first))
        XCTAssertNotNil(Reading.parse(first, at: Date()))
        let second = try output(await Upsc.run(path: path, target: "ups"))
        XCTAssertNotNil(Reading.jsonObject(second))
        XCTAssertEqual(calls, ["-j ups", "ups", "-j ups"])
    }

    func testPlainTextReplyToJSONOptionSwitchesPath() async throws {
        // An upsc that ignores -j and prints plain lines is an old client, not damaged JSON.
        let path = try upsc("cat '\(file("text").path)'")
        let raw = try output(await Upsc.run(path: path, target: "ups"))
        XCTAssertNotNil(Reading.parse(raw, at: Date()))
        XCTAssertEqual(calls, ["-j ups", "ups"])
        XCTAssertFalse(JSONSupport.isEnabled(path))
    }

    func testLooksLikeJSON() {
        XCTAssertTrue(JSONSupport.looksLikeJSON(" \n{\"a\": "))
        XCTAssertFalse(JSONSupport.looksLikeJSON("usage: upsc -l"))
        XCTAssertFalse(JSONSupport.looksLikeJSON("ups.status: OL"))
        XCTAssertFalse(JSONSupport.looksLikeJSON(""))
    }

    func testConnectionFailureIsReportedAndKeepsJSON() async throws {
        let path = try upsc("echo 'Error: Connection failure: Connection refused' >&2; exit 1")
        let outcome = await Upsc.run(path: path, target: "ups")
        guard case .failed(let status, let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(status, 1)
        XCTAssertTrue(message.contains("Connection refused"))
        XCTAssertEqual(calls, ["-j ups"], "a server failure is not retried without -j")
        XCTAssertTrue(JSONSupport.isEnabled(path))
        _ = await Upsc.run(path: path, target: "ups")
        XCTAssertEqual(calls, ["-j ups", "-j ups"])
    }

    @MainActor func testMonitorReadsJSONUpscWithoutFallback() async throws {
        let path = try upsc("if [ \"$1\" = -j ]; then cat '\(file("json").path)'; else echo plain-not-expected; exit 3; fi")
        let data = file("data")
        let monitor = Monitor(settings: Settings(upsName: "mustek", upscPath: path, ratedWatts: 400),
                              historyDirectory: data, locator: UpscLocator(candidates: []))
        await monitor.poll()?.value
        XCTAssertEqual(monitor.link, .ok)
        XCTAssertEqual(monitor.freshReading?.input, 230)
        XCTAssertEqual(monitor.freshReading?.driverState, "quiet")
        XCTAssertEqual(calls, ["-j mustek@127.0.0.1:3493"])
        let history = try String(contentsOf: data.appendingPathComponent("history.csv"), encoding: .utf8)
        XCTAssertEqual(history.split(separator: "\n").count, 2, "header plus one sample")
    }

    func testDecisionIsPerUpscPath() async throws {
        let old = try upsc("if [ \"$1\" = -j ]; then echo usage:; exit 0; fi; cat '\(file("text").path)'")
        _ = await Upsc.run(path: old, target: "ups")
        XCTAssertFalse(JSONSupport.isEnabled(old))
        XCTAssertTrue(JSONSupport.isEnabled(old + "-other"))
    }

    func testOptionErrorWording() {
        XCTAssertTrue(JSONSupport.isOptionError("upsc: invalid option -- 'j'"))
        XCTAssertTrue(JSONSupport.isOptionError("upsc: illegal option -- j\nusage: upsc ..."))
        XCTAssertFalse(JSONSupport.isOptionError("Error: Connection failure: Connection refused"))
        XCTAssertFalse(JSONSupport.isOptionError("Error: Unknown UPS"))
        XCTAssertFalse(JSONSupport.isOptionError(""))
    }
}
