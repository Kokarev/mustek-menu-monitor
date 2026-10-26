import Foundation

/// One validated telemetry sample from `upsc`.
struct Reading {
    let timestamp: Date
    let status: String
    let input: Double?
    let output: Double?
    let load: Double?
    let batteryVoltage: Double?
    let batteryCharge: Double?
    /// Remaining runtime in seconds, only as reported by NUT.
    let batteryRuntime: Double?
    let temperature: Double?
    let frequency: Double?
    let driverState: String

    var flags: [Substring] { status.split(separator: " ") }
    var online: Bool { flags.contains("OL") }
    var onBattery: Bool { flags.contains("OB") }
    var lowBattery: Bool { flags.contains("LB") }
    /// Estimate only when a valid configured rating and load are both known.
    func estimatedWatts(ratedWatts: Double?) -> Double? {
        guard let ratedWatts, ratedWatts.isFinite, Settings.ratedWattsRange.contains(ratedWatts),
              let load, load.isFinite, (0...100).contains(load) else { return nil }
        return ratedWatts * load / 100
    }

    /// Values without which a `upsc` response does not count as a successful update.
    static let requiredKeys = ["ups.status", "input.voltage", "ups.load"]

    /// Parses `upsc` output. Returns nil for an empty or malformed response,
    /// or one that lacks any of `requiredKeys` as a usable value.
    static func parse(_ raw: String, at timestamp: Date) -> Reading? {
        var data: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let index = line.firstIndex(of: ":") else { continue }
            data[String(line[..<index])] = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let status = data["ups.status"], !status.isEmpty else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = data[key], let n = Double(value), n.isFinite else { return nil }
            return n
        }
        guard let input = number("input.voltage"), let load = number("ups.load") else { return nil }
        return Reading(timestamp: timestamp, status: status, input: input,
                       output: number("output.voltage"), load: load,
                       batteryVoltage: number("battery.voltage"), batteryCharge: number("battery.charge"),
                       batteryRuntime: number("battery.runtime"),
                       temperature: number("ups.temperature"), frequency: number("input.frequency"),
                       driverState: data["driver.state"] ?? "—")
    }
}
