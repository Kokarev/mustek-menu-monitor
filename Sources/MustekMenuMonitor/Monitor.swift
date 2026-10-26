import AppKit
import Foundation

/// State of the link to NUT as last observed.
enum LinkState: Equatable {
    /// No poll has finished yet.
    case waiting
    /// Last poll returned a valid reading, recent enough to show.
    case ok
    /// NUT reported stale data, or no valid reading arrived within `Monitor.staleAfter`.
    case stale
    /// upsc could not get an answer; the associated text says why.
    case noResponse(String)
    /// upsc answered, but the response was empty, malformed or lacked required values.
    case invalid

    /// Maps upsc's stderr text to a link state.
    static func forFailure(message: String) -> LinkState {
        let text = message.lowercased()
        if text.contains("data stale") { return .stale }
        if text.contains("driver not connected") { return .noResponse("драйвер не подключён") }
        if text.contains("unknown ups") { return .noResponse("ИБП не найден в upsd") }
        if text.contains("connection failure") || text.contains("connection refused") { return .noResponse("upsd недоступен") }
        return .noResponse("ошибка upsc")
    }
}

@MainActor final class Monitor {
    /// A reading older than this is no longer shown as current.
    static let staleAfter: TimeInterval = 15
    static let historyHeader = "timestamp,status,input_V,output_V,load_percent,estimated_W,delta_Wh,battery_V\n"

    /// Last valid reading. Shown only through `freshReading`.
    private(set) var reading: Reading?
    private(set) var link: LinkState = .waiting
    /// Time of the last valid reading; a started but failed upsc call does not move it.
    private(set) var lastSuccess: Date?
    private(set) var todayWh: Double = 0
    private(set) var monthWh: Double = 0
    private(set) var sampleCount: Int = 0
    /// Outage in progress (OB seen, no OL since), restored from power_events.csv after a restart.
    private(set) var currentOutage: Outage?
    private(set) var lastOutage: Outage?
    /// Called on the main actor after any visible state change.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var previous: Reading?
    private var isPolling = false
    /// Calendar day/month the in-memory totals currently belong to.
    private var totalsDate = Date()
    private let fm = FileManager.default
    private let iso = ISO8601DateFormatter()
    private let historyDirectory: URL
    private let events: PowerEventLog

    var historyURL: URL {
        try? fm.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        return historyDirectory.appendingPathComponent("history.csv")
    }

    /// The reading to display, or nil when the link is not healthy.
    var freshReading: Reading? { link == .ok ? reading : nil }

    /// Data directory for history, events and the instance lock.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MustekMenuMonitor", isDirectory: true)
    }

    init(historyDirectory: URL? = nil) {
        let directory = historyDirectory ?? Self.defaultDirectory
        self.historyDirectory = directory
        events = PowerEventLog(url: directory.appendingPathComponent("power_events.csv"))
        (lastOutage, currentOutage) = events.load()
        // History is read once; afterwards totals are kept in memory and only appended to.
        loadHistory()
    }

    func start() {
        poll()
        // .common keeps the timer firing while the menu is open (event-tracking run loop mode).
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let now = Date()
        // Day/month rollover and staleness are applied even when no sample arrives.
        rollTotalsIfNeeded(now: now)
        checkStaleness(now: now)
        // A slow upsc must not stack up overlapping polls.
        guard !isPolling else { return }
        guard fm.isExecutableFile(atPath: Upsc.path) else {
            fail(.noResponse("upsc не найден")); return
        }
        isPolling = true
        Task {
            let outcome = await Upsc.run()
            handle(outcome, at: Date())
            isPolling = false
        }
    }

    /// Marks the link stale once the last valid reading is older than `staleAfter`.
    func checkStaleness(now: Date) {
        guard link == .ok, let lastSuccess, now.timeIntervalSince(lastSuccess) > Self.staleAfter else { return }
        link = .stale
        previous = nil
        onChange?()
    }

    func handle(_ outcome: UpscOutcome, at now: Date) {
        switch outcome {
        case .launchError:
            fail(.noResponse("upsc не запускается"))
        case .timedOut:
            fail(.noResponse("тайм-аут"))
        case .failed(_, let message):
            fail(LinkState.forFailure(message: message))
        case .output(let raw):
            guard let next = Reading.parse(raw, at: now) else { fail(.invalid); return }
            if let prev = previous, let p1 = prev.estimatedWatts, let p2 = next.estimatedWatts,
               next.timestamp.timeIntervalSince(prev.timestamp) <= 30 {
                // Trapezoidal integration; estimates UPS output energy, not mains input consumption.
                let wh = (p1 + p2) / 2 * next.timestamp.timeIntervalSince(prev.timestamp) / 3600
                appendSample(next, deltaWh: wh)
            } else { appendSample(next, deltaWh: 0) }
            previous = next
            reading = next
            lastSuccess = now
            link = .ok
            trackPower(next)
            onChange?()
        }
    }

    /// Records OL → OB and OB → OL transitions; only valid readings reach here.
    private func trackPower(_ r: Reading) {
        if r.onBattery {
            if currentOutage == nil {
                currentOutage = Outage(start: r.timestamp)
                events.appendStart(r)
            }
            currentOutage?.record(voltage: r.batteryVoltage, at: r.timestamp)
        } else if r.online, var outage = currentOutage {
            // After a monitoring gap the moment power returned is unknown; the last OB sample
            // is then the last confirmed time on battery, so the duration is a lower bound.
            if let lastAt = outage.lastVoltageAt, r.timestamp.timeIntervalSince(lastAt) > 60 {
                outage.end = lastAt
            } else {
                outage.end = r.timestamp
            }
            events.appendEnd(r, outage: outage)
            lastOutage = outage
            currentOutage = nil
        }
    }

    /// Any failure breaks the integration chain, so a gap is never bridged with estimated energy.
    private func fail(_ state: LinkState) {
        link = state
        previous = nil
        onChange?()
    }

    private func appendSample(_ r: Reading, deltaWh: Double) {
        let fields: [String] = [iso.string(from: r.timestamp), r.status,
            r.input.map { String($0) } ?? "", r.output.map { String($0) } ?? "",
            r.load.map { String($0) } ?? "", r.estimatedWatts.map { String($0) } ?? "",
            String(deltaWh), r.batteryVoltage.map { String($0) } ?? ""]
        let line = fields.joined(separator: ",") + "\n"
        let url = historyURL
        if !fm.fileExists(atPath: url.path) {
            try? Self.historyHeader.write(to: url, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch { return }
        // Totals follow only what reached the file, so a restart recomputes the same values.
        rollTotalsIfNeeded(now: r.timestamp)
        if deltaWh.isFinite, deltaWh >= 0 {
            todayWh += deltaWh
            monthWh += deltaWh
        }
        sampleCount += 1
    }

    /// Resets the day and month totals when the calendar day or month changes.
    private func rollTotalsIfNeeded(now: Date) {
        let calendar = Calendar.current
        if !calendar.isDate(now, equalTo: totalsDate, toGranularity: .month) { monthWh = 0 }
        if !calendar.isDate(now, inSameDayAs: totalsDate) { todayWh = 0 }
        totalsDate = now
    }

    private func loadHistory() {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        let calendar = Calendar.current
        let now = Date()
        var today = 0.0, month = 0.0, count = 0
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 7, let date = iso.date(from: String(parts[0])),
                  let wh = Double(parts[6]), wh.isFinite, wh >= 0 else { continue }
            if calendar.isDate(date, inSameDayAs: now) { today += wh }
            if calendar.isDate(date, equalTo: now, toGranularity: .month) { month += wh }
            count += 1
            // An outage still open after a restart regains its OB voltage samples from history.
            if let start = currentOutage?.start, date > start, parts[1].split(separator: " ").contains("OB"),
               parts.count >= 8 {
                currentOutage?.record(voltage: Double(parts[7]), at: date)
            }
        }
        todayWh = today; monthWh = month; sampleCount = count; totalsDate = now
    }

    func openHistory() { NSWorkspace.shared.open(historyURL.deletingLastPathComponent()) }
}
