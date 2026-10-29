import AppKit
import Foundation

/// State of the link to NUT as last observed.
enum LinkState: Equatable {
    /// No UPS name, or connection settings are invalid; upsc is not run.
    case notConfigured
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
        if text.contains("driver not connected") { return .noResponse(L10n.tr("driver not connected")) }
        if text.contains("unknown ups") { return .noResponse(L10n.tr("UPS not found in upsd")) }
        if text.contains("connection failure") || text.contains("connection refused") { return .noResponse(L10n.tr("upsd unavailable")) }
        return .noResponse(L10n.tr("upsc error"))
    }
}

/// What one poll runs: NUT target, and the user's upsc path (nil means located automatically).
/// The executable itself is located on every poll, so installing NUT later needs no restart.
struct UpscConnection: Equatable {
    let userPath: String?
    let target: String

    /// nil when the settings do not yield a usable target. An unusable upsc path is not a
    /// configuration gap: it is reported by the poll.
    init?(_ settings: Settings) {
        guard case .success(let target) = settings.nutTarget() else { return nil }
        userPath = settings.upscPath
        self.target = target
    }
}

typealias UpscRunner = @Sendable (_ path: String, _ target: String) async -> UpscOutcome

@MainActor final class Monitor {
    /// A reading older than this is no longer shown as current.
    static let staleAfter: TimeInterval = 15
    static let historyHeader = "timestamp,status,input_V,output_V,load_percent,estimated_W,delta_Wh,battery_V\n"

    private(set) var settings: Settings
    private(set) var connection: UpscConnection?
    /// Bumped on every connection change; a poll started under an older value is discarded.
    private(set) var generation = 0
    /// Last valid reading. Shown only through `freshReading`.
    private(set) var reading: Reading?
    private(set) var link: LinkState
    /// Time of the last valid reading; a started but failed upsc call does not move it.
    private(set) var lastSuccess: Date?
    private(set) var todayWh: Double = 0
    private(set) var monthWh: Double = 0
    private(set) var hasTodayEnergy = false
    private(set) var hasMonthEnergy = false
    private(set) var sampleCount: Int = 0
    /// Outage in progress (OB seen, no OL since), restored from power_events.csv after a restart.
    private(set) var currentOutage: Outage?
    /// NUT target the open outage was observed on; nil when unknown.
    private(set) var outageOwner: String?
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
    private let runUpsc: UpscRunner
    private let locator: UpscLocator

    var historyURL: URL {
        try? fm.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        return historyDirectory.appendingPathComponent("history.csv")
    }

    /// The reading to display, or nil when the link is not healthy.
    var freshReading: Reading? { link == .ok ? reading : nil }

    /// Data directory for history, events and the instance lock.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
    }

    /// Default settings have no UPS name, so a monitor built without them stays not configured.
    init(settings: Settings = Settings(), historyDirectory: URL? = nil, locator: UpscLocator = UpscLocator(),
         runUpsc: @escaping UpscRunner = { await Upsc.run(path: $0, target: $1) }) {
        self.settings = settings
        connection = UpscConnection(settings)
        link = connection == nil ? .notConfigured : .waiting
        self.runUpsc = runUpsc
        self.locator = locator
        let directory = historyDirectory ?? Self.defaultDirectory
        self.historyDirectory = directory
        events = PowerEventLog(url: directory.appendingPathComponent("power_events.csv"))
        (lastOutage, currentOutage) = events.load()
        // Checked against the connection on the first valid reading (see trackPower).
        outageOwner = currentOutage == nil ? nil : events.owner()
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

    /// Replaces the settings. A changed connection starts a new generation: the integration
    /// chain and last reading are dropped, the link waits, and a poll starts at once if running.
    func apply(_ settings: Settings) {
        let ratingChanged = self.settings.ratedWatts != settings.ratedWatts
        self.settings = settings
        if ratingChanged { previous = nil }
        let next = UpscConnection(settings)
        guard next != connection else {
            if ratingChanged { onChange?() }
            return
        }
        // Another UPS (or none) must never close this UPS's outage.
        if currentOutage != nil, outageOwner != next?.target { interruptOutage(at: Date()) }
        connection = next
        generation += 1
        // The in-flight poll belongs to the old generation; its result will be discarded.
        isPolling = false
        previous = nil
        reading = nil
        lastSuccess = nil
        link = next == nil ? .notConfigured : .waiting
        onChange?()
        if timer != nil { poll() }
    }

    /// One poll; the timer calls it every five seconds. Returns the started task for tests.
    @discardableResult
    func poll() -> Task<Void, Never>? {
        let now = Date()
        // Day/month rollover and staleness are applied even when no sample arrives.
        rollTotalsIfNeeded(now: now)
        checkStaleness(now: now)
        guard let connection else { return nil }
        // A slow upsc must not stack up overlapping polls.
        guard !isPolling else { return nil }
        let path: String
        switch locator.locate(userPath: connection.userPath) {
        case .success(let found): path = found
        case .failure(.notFound): fail(.noResponse(L10n.tr("upsc not found"))); return nil
        // The user's choice is never replaced by another upsc behind their back.
        case .failure(.userPathUnusable): fail(.noResponse(L10n.tr("selected upsc unavailable"))); return nil
        }
        isPolling = true
        let started = generation
        let run = runUpsc
        return Task {
            let outcome = await run(path, connection.target)
            // A late answer for a replaced connection must not touch state or history.
            guard started == generation else { return }
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
            fail(.noResponse(L10n.tr("upsc could not start")))
        case .timedOut:
            fail(.noResponse(L10n.tr("timeout")))
        case .failed(_, let message):
            fail(LinkState.forFailure(message: message))
        case .output(let raw):
            guard let next = Reading.parse(raw, at: now) else { fail(.invalid); return }
            let watts = next.estimatedWatts(ratedWatts: settings.ratedWatts)
            if let prev = previous,
               let p1 = prev.estimatedWatts(ratedWatts: settings.ratedWatts), let p2 = watts,
               next.timestamp.timeIntervalSince(prev.timestamp) >= 0,
               next.timestamp.timeIntervalSince(prev.timestamp) <= 30 {
                // Trapezoidal integration; estimates UPS output energy, not mains input consumption.
                let wh = (p1 + p2) / 2 * next.timestamp.timeIntervalSince(prev.timestamp) / 3600
                appendSample(next, deltaWh: wh)
            } else { appendSample(next, deltaWh: nil) }
            previous = watts == nil ? nil : next
            reading = next
            lastSuccess = now
            link = .ok
            trackPower(next)
            onChange?()
        }
    }

    /// Records OL → OB and OB → OL transitions; only valid readings reach here.
    private func trackPower(_ r: Reading) {
        // An outage restored from disk for a different (or unknown) UPS is not continued:
        // this reading cannot confirm anything about it.
        if currentOutage != nil, outageOwner != connection?.target { interruptOutage(at: r.timestamp) }
        if r.onBattery {
            if currentOutage == nil {
                currentOutage = Outage(start: r.timestamp)
                events.appendStart(r)
                outageOwner = connection?.target
                events.setOwner(outageOwner)
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
            outageOwner = nil
            events.setOwner(nil)
        }
    }

    /// Ends observation of the open outage with CFG; it is not shown as the last outage.
    private func interruptOutage(at date: Date) {
        guard let outage = currentOutage else { return }
        events.appendInterrupted(outage, at: date)
        currentOutage = nil
        outageOwner = nil
        events.setOwner(nil)
    }

    /// Any failure breaks the integration chain, so a gap is never bridged with estimated energy.
    private func fail(_ state: LinkState) {
        link = state
        previous = nil
        onChange?()
    }

    private func appendSample(_ r: Reading, deltaWh: Double?) {
        let fields: [String] = [iso.string(from: r.timestamp), r.status,
            r.input.map { String($0) } ?? "", r.output.map { String($0) } ?? "",
            r.load.map { String($0) } ?? "", r.estimatedWatts(ratedWatts: settings.ratedWatts).map { String($0) } ?? "",
            deltaWh.map { String($0) } ?? "", r.batteryVoltage.map { String($0) } ?? ""]
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
        if let deltaWh, deltaWh.isFinite, deltaWh >= 0 {
            todayWh += deltaWh
            monthWh += deltaWh
            hasTodayEnergy = true
            hasMonthEnergy = true
        }
        sampleCount += 1
    }

    /// Resets the day and month totals when the calendar day or month changes.
    private func rollTotalsIfNeeded(now: Date) {
        let calendar = Calendar.current
        if !calendar.isDate(now, equalTo: totalsDate, toGranularity: .month) {
            monthWh = 0; hasMonthEnergy = false
        }
        if !calendar.isDate(now, inSameDayAs: totalsDate) {
            todayWh = 0; hasTodayEnergy = false
        }
        totalsDate = now
    }

    private func loadHistory() {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        let calendar = Calendar.current
        let now = Date()
        var today = 0.0, month = 0.0, count = 0
        let ownsRestoredOutage = currentOutage != nil && outageOwner == connection?.target
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 8, let date = iso.date(from: String(parts[0])) else { continue }
            if let wh = Double(parts[6]), wh.isFinite, wh >= 0 {
                if calendar.isDate(date, inSameDayAs: now) { today += wh; hasTodayEnergy = true }
                if calendar.isDate(date, equalTo: now, toGranularity: .month) { month += wh; hasMonthEnergy = true }
            }
            count += 1
            // An outage still open after a restart regains its OB voltage samples from history,
            // but only when it belongs to this connection: history rows carry no UPS identity, and
            // an outage owned by another (or unknown) UPS is ended with CFG on the first reading.
            if ownsRestoredOutage, let start = currentOutage?.start, date > start,
               parts[1].split(separator: " ").contains("OB"),
               parts.count >= 8 {
                currentOutage?.record(voltage: Double(parts[7]), at: date)
            }
        }
        todayWh = today; monthWh = month; sampleCount = count; totalsDate = now
    }

    func openHistory() { NSWorkspace.shared.open(historyURL.deletingLastPathComponent()) }
}
