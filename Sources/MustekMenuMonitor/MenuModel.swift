import Foundation

struct MenuRow: Equatable {
    let label: String
    let value: String
}

struct MenuSection: Equatable {
    let title: String
    let rows: [MenuRow]
}

/// Monitor state at one moment, as input for `MenuModel.make`.
struct MonitorSnapshot {
    var link: LinkState
    var reading: Reading?
    var lastSuccess: Date?
    var todayWh: Double
    var monthWh: Double
    var currentOutage: Outage?
    var lastOutage: Outage?
    var now: Date
    var ratedWatts: Double? = nil
    var hasTodayEnergy = false
    var hasMonthEnergy = false
}

extension Monitor {
    func snapshot(now: Date = Date()) -> MonitorSnapshot {
        MonitorSnapshot(link: link, reading: reading, lastSuccess: lastSuccess, todayWh: todayWh, monthWh: monthWh,
                        currentOutage: currentOutage, lastOutage: lastOutage, now: now, ratedWatts: settings.ratedWatts,
                        hasTodayEnergy: hasTodayEnergy, hasMonthEnergy: hasMonthEnergy)
    }
}

/// Everything the status item and its menu show, derived from monitor state.
/// The section and row layout is the same in every state; only the texts change.
struct MenuModel: Equatable {
    let statusBarTitle: String
    let header: String
    let sections: [MenuSection]
    let note: String

    static let unavailable = "—"
    static let noData = L10n.tr("No data")

    static func make(_ s: MonitorSnapshot) -> MenuModel {
        // Values are shown only while the link is healthy; otherwise every reading shows a dash.
        let r = s.link == .ok ? s.reading : nil
        let dash = unavailable
        let outage = s.currentOutage ?? s.lastOutage
        return MenuModel(
            statusBarTitle: barTitle(for: r, ratedWatts: s.ratedWatts),
            header: "MUSTEK \(L10n.tr("UPS")) — \(stateText(link: s.link, reading: r))",
            sections: [
                MenuSection(title: L10n.tr("Mains"), rows: [
                    MenuRow(label: L10n.tr("Input"), value: Format.value(r?.input, L10n.tr("V"), digits: 1)),
                    MenuRow(label: L10n.tr("Quit"), value: Format.value(r?.output, L10n.tr("V"), digits: 1)),
                    MenuRow(label: L10n.tr("Frequency"), value: Format.value(r?.frequency, L10n.tr("Hz"), digits: 1)),
                ]),
                MenuSection(title: L10n.tr("Load"), rows: [
                    MenuRow(label: L10n.tr("Load"), value: Format.value(r?.load, "%", digits: 0...1, space: false)),
                    MenuRow(label: L10n.tr("Power"), value: s.ratedWatts == nil ? L10n.tr("Power not configured") : Format.value(r?.estimatedWatts(ratedWatts: s.ratedWatts), L10n.tr("W"), digits: 0, approx: true)),
                ]),
                MenuSection(title: L10n.tr("Battery"), rows: [
                    MenuRow(label: L10n.tr("Voltage"), value: batteryValue(r?.batteryVoltage, L10n.tr("V"), digits: 1)),
                    MenuRow(label: L10n.tr("Mode"), value: r.map(modeText) ?? noData),
                    MenuRow(label: L10n.tr("Charge"), value: batteryValue(r?.batteryCharge, "%", digits: 0...1)),
                    MenuRow(label: L10n.tr("Remaining runtime (NUT)"), value: batteryValue(r?.batteryRuntime, L10n.tr("s"), digits: 0)),
                ]),
                MenuSection(title: L10n.tr("Power outages"), rows: [
                    MenuRow(label: L10n.tr("Last outage"), value: outageStartText(current: s.currentOutage, last: s.lastOutage)),
                    MenuRow(label: L10n.tr("Duration"), value: outage.map { outageDuration($0, now: s.now) } ?? dash),
                    MenuRow(label: L10n.tr("Minimum battery voltage"), value: Format.value(outage?.minVoltage, L10n.tr("V"), digits: 1)),
                    MenuRow(label: L10n.tr("Voltage drop"), value: Format.value(outage?.dropRatePerHour, L10n.tr("V/h"), digits: 2)),
                ]),
                MenuSection(title: L10n.tr("Temperature"), rows: [
                    MenuRow(label: L10n.tr("UPS"), value: Format.value(r?.temperature, "°C", digits: 0...1)),
                ]),
                MenuSection(title: L10n.tr("Statistics"), rows: [
                    MenuRow(label: L10n.tr("Today"), value: s.ratedWatts == nil && !s.hasTodayEnergy ? L10n.tr("Not configured") : Format.value(s.todayWh / 1000, L10n.tr("kWh"), digits: 3, approx: true)),
                    MenuRow(label: L10n.tr("This month"), value: s.ratedWatts == nil && !s.hasMonthEnergy ? L10n.tr("Not configured") : Format.value(s.monthWh / 1000, L10n.tr("kWh"), digits: 3, approx: true)),
                ]),
                MenuSection(title: L10n.tr("Diagnostics"), rows: [
                    MenuRow(label: "NUT", value: linkText(s.link)),
                    MenuRow(label: L10n.tr("UPS status"), value: r?.status ?? dash),
                    MenuRow(label: L10n.tr("Driver"), value: r?.driverState ?? dash),
                    MenuRow(label: L10n.tr("Last update"), value: s.lastSuccess.map { Format.time($0) } ?? dash),
                ]),
            ],
            note: s.ratedWatts.map { L10n.format("Estimate: load × %@ W / 100; not a mains meter", Format.number($0, digits: 0...2)) } ?? L10n.tr("Nominal power not configured; new Wh are not calculated"))
    }

    private static func batteryValue(_ value: Double?, _ unit: String, digits: Int) -> String {
        batteryValue(value, unit, digits: digits...digits)
    }

    private static func batteryValue(_ value: Double?, _ unit: String, digits: ClosedRange<Int>) -> String {
        guard let value else { return noData }
        return Format.value(value, unit, digits: digits)
    }

    /// v0.1.1 format on mains; battery voltage and OB on battery; a warning dash without fresh data.
    static func barTitle(for r: Reading?, ratedWatts: Double? = nil) -> String {
        guard let r else { return "⚠️ \(L10n.tr("UPS")) —" }
        let watts = r.estimatedWatts(ratedWatts: ratedWatts).map { Format.value($0, L10n.tr("W"), digits: 0, approx: true) } ?? (ratedWatts == nil ? L10n.tr("power not configured") : "— " + L10n.tr("W"))
        if r.onBattery {
            let volts = batteryValue(r.batteryVoltage, L10n.tr("V"), digits: 1)
            return "🔋 \(volts) · \(watts) · OB" + (r.lowBattery ? " LB" : "")
        }
        let symbol = r.online ? "⚡" : "⚠️"
        let volts = r.input.map { Format.value($0, L10n.tr("V"), digits: 0) } ?? "— " + L10n.tr("V")
        let load = r.load.map { Format.value($0, "%", digits: 0, space: false) } ?? "—%"
        return "\(symbol) \(volts) · \(watts) · \(load)"
    }

    static func stateText(link: LinkState, reading r: Reading?) -> String {
        switch link {
        case .notConfigured: return "⚙️ " + L10n.tr("UPS not configured")
        case .waiting: return "⏳ " + L10n.tr("Waiting for data")
        case .stale: return "🟡 " + L10n.tr("Data stale")
        case .noResponse: return "🔴 " + L10n.tr("No NUT response")
        case .invalid: return "🔴 " + L10n.tr("Invalid NUT response")
        case .ok:
            guard let r else { return "⏳ " + L10n.tr("Waiting for data") }
            if r.onBattery { return r.lowBattery ? "🔴 " + L10n.tr("On battery, low battery") : "🟠 " + L10n.tr("On battery") }
            if r.online { return "🟢 " + L10n.tr("On mains") }
            return "⚠️ " + L10n.format("Status: %@", r.status)
        }
    }

    static func modeText(_ r: Reading) -> String {
        if r.onBattery { return L10n.tr("Discharging") }
        if r.online { return L10n.tr("On mains") }
        return r.status
    }

    static func linkText(_ link: LinkState) -> String {
        switch link {
        case .notConfigured: return L10n.tr("not configured")
        case .waiting: return L10n.tr("waiting")
        case .ok: return L10n.tr("connected")
        case .stale: return L10n.tr("data stale")
        case .noResponse(let reason): return L10n.format("no response (%@)", reason)
        case .invalid: return L10n.tr("invalid response")
        }
    }

    static func outageStartText(current: Outage?, last: Outage?) -> String {
        if let current { return L10n.format("ongoing since %@", Format.time(current.start)) }
        if let last { return Format.dateTime(last.start) }
        return L10n.tr("not recorded")
    }

    static func outageDuration(_ outage: Outage, now: Date) -> String {
        Format.duration(outage.duration(now: now)) + (outage.end == nil ? L10n.tr(" (ongoing)") : "")
    }
}

/// Russian number formatting: decimal comma, no grouping.
enum Format {
    static func number(_ value: Double, digits: ClosedRange<Int>, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = digits.lowerBound
        f.maximumFractionDigits = digits.upperBound
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func inputNumber(_ value: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = 17
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func value(_ value: Double?, _ unit: String, digits: Int, space: Bool = true, approx: Bool = false) -> String {
        Self.value(value, unit, digits: digits...digits, space: space, approx: approx)
    }

    static func value(_ value: Double?, _ unit: String, digits: ClosedRange<Int>, space: Bool = true, approx: Bool = false) -> String {
        guard let value else { return MenuModel.unavailable }
        return (approx ? "≈" : "") + number(value, digits: digits) + (space ? " " : "") + unit
    }

    static func time(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter(); f.locale = locale; f.timeStyle = .medium; f.dateStyle = .none
        return f.string(from: date)
    }
    static func dateTime(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter(); f.locale = locale; f.dateStyle = .short; f.timeStyle = .medium
        return f.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        if h > 0 { return "\(number(Double(h), digits: 0...0)) \(L10n.tr("h")) \(number(Double(m), digits: 0...0)) \(L10n.tr("min"))" }
        if m > 0 { return "\(number(Double(m), digits: 0...0)) \(L10n.tr("min")) \(number(Double(s), digits: 0...0)) \(L10n.tr("s"))" }
        return "\(number(Double(s), digits: 0...0)) \(L10n.tr("s"))"
    }
}
