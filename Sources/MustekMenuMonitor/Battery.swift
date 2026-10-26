import Foundation

/// Demonstration battery profile; replace with your own specifications before use. Informational only; no runtime or charge is derived yet.
struct BatteryProfile {
    let model: String
    let chemistry: String
    let nominalVoltage: Double
    let capacityAh: Double
    /// Reference end-of-discharge voltage, not a measured or manufacturer-confirmed cut-off.
    let referenceCutoffVoltage: Double
    /// Calendar date the battery was put into service (local time).
    let installedOn: DateComponents
    /// Condition at installation, as stated by the owner.
    let condition: String

    var nominalEnergyWh: Double { nominalVoltage * capacityAh }

    static let installed = BatteryProfile(model: "Demo GEL 12V 9Ah", chemistry: "GEL",
                                          nominalVoltage: 12, capacityAh: 9, referenceCutoffVoltage: 10.5,
                                          installedOn: DateComponents(year: 2000, month: 1, day: 1),
                                          condition: "пример")
}

/// One period on battery power, from the first OB reading to the first OL reading after it.
struct Outage: Equatable {
    let start: Date
    var end: Date?
    /// Battery voltage at the first OB reading.
    var startVoltage: Double?
    /// Battery voltage at the most recent OB reading.
    var lastVoltage: Double?
    var lastVoltageAt: Date?
    /// Lowest battery voltage among OB readings of this outage.
    var minVoltage: Double?
    /// Rate read back from power_events.csv for a finished outage.
    var loggedDropRate: Double?

    func duration(now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }

    /// Average voltage drop in V/h between the first and the latest OB reading; nil below one minute of data.
    var dropRatePerHour: Double? {
        if let loggedDropRate { return loggedDropRate }
        guard let startVoltage, let lastVoltage, let lastVoltageAt else { return nil }
        let hours = lastVoltageAt.timeIntervalSince(start) / 3600
        guard hours >= 1.0 / 60 else { return nil }
        return (startVoltage - lastVoltage) / hours
    }

    mutating func record(voltage: Double?, at date: Date) {
        guard let voltage else { return }
        if startVoltage == nil { startVoltage = voltage }
        lastVoltage = voltage
        lastVoltageAt = date
        minVoltage = min(minVoltage ?? voltage, voltage)
    }
}

/// Append-only log of OL → OB and OB → OL transitions, plus CFG when observation of an
/// open outage stops (`power_events.csv`).
/// Kept apart from history.csv so that file's format stays unchanged.
struct PowerEventLog {
    static let header = "timestamp,event,status,battery_V,duration_s,start_battery_V,last_ob_battery_V,min_battery_V,drop_V_per_h\n"
    let url: URL
    private let iso = ISO8601DateFormatter()

    init(url: URL) { self.url = url }

    func appendStart(_ r: Reading) {
        append([iso.string(from: r.timestamp), "OB", r.status, text(r.batteryVoltage), "", "", "", "", ""])
    }

    func appendEnd(_ r: Reading, outage: Outage) {
        append([iso.string(from: r.timestamp), "OL", r.status, text(r.batteryVoltage),
                String(Int(outage.duration(now: r.timestamp).rounded())), text(outage.startVoltage),
                text(outage.lastVoltage), text(outage.minVoltage), text(outage.dropRatePerHour)])
    }

    /// Observation of an open outage stopped (UPS changed, or its owner is unknown).
    /// Not a power return: no status and no duration, only the voltages seen so far.
    func appendInterrupted(_ outage: Outage, at date: Date) {
        append([iso.string(from: date), "CFG", "", "", "", text(outage.startVoltage),
                text(outage.lastVoltage), text(outage.minVoltage), ""])
    }

    /// Sidecar holding the NUT target that owns the open outage; the CSV columns stay unchanged.
    var ownerURL: URL { url.deletingLastPathComponent().appendingPathComponent("open_outage_ups.txt") }

    /// Owner of the open outage, or nil when unknown (also for history from before 0.1.4).
    func owner() -> String? {
        guard let text = try? String(contentsOf: ownerURL, encoding: .utf8) else { return nil }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    func setOwner(_ target: String?) {
        if let target {
            try? (target + "\n").write(to: ownerURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: ownerURL)
        }
    }

    private func text(_ value: Double?) -> String { value.map { String($0) } ?? "" }

    private func append(_ fields: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try? Self.header.write(to: url, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
        } catch { return }
    }

    /// Replays the log: returns the last finished outage and an outage still open at the end of the log.
    func load() -> (last: Outage?, open: Outage?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var last: Outage?, open: Outage?
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard parts.count >= 9, let date = iso.date(from: parts[0]) else { continue }
            switch parts[1] {
            case "OB":
                guard open == nil else { continue }
                var outage = Outage(start: date)
                outage.record(voltage: Double(parts[3]), at: date)
                open = outage
            case "OL":
                let duration = Double(parts[4]) ?? 0
                var outage = open ?? Outage(start: date.addingTimeInterval(-duration))
                outage.end = date
                outage.startVoltage = Double(parts[5]) ?? outage.startVoltage
                outage.lastVoltage = Double(parts[6]) ?? outage.lastVoltage
                outage.minVoltage = Double(parts[7]) ?? outage.minVoltage
                outage.loggedDropRate = Double(parts[8])
                last = outage
                open = nil
            case "CFG":
                // Observation stopped without a confirmed return; it neither stays open nor becomes the last outage.
                open = nil
            default:
                continue
            }
        }
        return (last, open)
    }
}
