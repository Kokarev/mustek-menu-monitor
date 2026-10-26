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
    static let noData = "Нет данных"

    static func make(_ s: MonitorSnapshot) -> MenuModel {
        // Values are shown only while the link is healthy; otherwise every reading shows a dash.
        let r = s.link == .ok ? s.reading : nil
        let dash = unavailable
        let outage = s.currentOutage ?? s.lastOutage
        return MenuModel(
            statusBarTitle: barTitle(for: r, ratedWatts: s.ratedWatts),
            header: "MUSTEK UPS — \(stateText(link: s.link, reading: r))",
            sections: [
                MenuSection(title: "Электросеть", rows: [
                    MenuRow(label: "Вход", value: Format.value(r?.input, "В", digits: 1)),
                    MenuRow(label: "Выход", value: Format.value(r?.output, "В", digits: 1)),
                    MenuRow(label: "Частота", value: Format.value(r?.frequency, "Гц", digits: 1)),
                ]),
                MenuSection(title: "Нагрузка", rows: [
                    MenuRow(label: "Нагрузка", value: Format.value(r?.load, "%", digits: 0...1, space: false)),
                    MenuRow(label: "Мощность", value: s.ratedWatts == nil ? "не настроена" : Format.value(r?.estimatedWatts(ratedWatts: s.ratedWatts), "Вт", digits: 0, approx: true)),
                ]),
                MenuSection(title: "Аккумулятор", rows: [
                    MenuRow(label: "Напряжение", value: batteryValue(r?.batteryVoltage, "В", digits: 1)),
                    MenuRow(label: "Режим", value: r.map(modeText) ?? noData),
                    MenuRow(label: "Заряд", value: batteryValue(r?.batteryCharge, "%", digits: 0...1)),
                    MenuRow(label: "Оставшееся время (NUT)", value: batteryValue(r?.batteryRuntime, "с", digits: 0)),
                ]),
                MenuSection(title: "Отключения сети", rows: [
                    MenuRow(label: "Последнее отключение", value: outageStartText(current: s.currentOutage, last: s.lastOutage)),
                    MenuRow(label: "Продолжительность", value: outage.map { outageDuration($0, now: s.now) } ?? dash),
                    MenuRow(label: "Мин. напряжение АКБ", value: Format.value(outage?.minVoltage, "В", digits: 1)),
                    MenuRow(label: "Падение напряжения", value: Format.value(outage?.dropRatePerHour, "В/ч", digits: 2)),
                ]),
                MenuSection(title: "Температура", rows: [
                    MenuRow(label: "ИБП", value: Format.value(r?.temperature, "°C", digits: 0...1)),
                ]),
                MenuSection(title: "Статистика", rows: [
                    MenuRow(label: "Сегодня", value: s.ratedWatts == nil && !s.hasTodayEnergy ? "не настроено" : Format.value(s.todayWh / 1000, "кВт·ч", digits: 3, approx: true)),
                    MenuRow(label: "Этот месяц", value: s.ratedWatts == nil && !s.hasMonthEnergy ? "не настроено" : Format.value(s.monthWh / 1000, "кВт·ч", digits: 3, approx: true)),
                ]),
                MenuSection(title: "Диагностика", rows: [
                    MenuRow(label: "NUT", value: linkText(s.link)),
                    MenuRow(label: "Статус ИБП", value: r?.status ?? dash),
                    MenuRow(label: "Драйвер", value: r?.driverState ?? dash),
                    MenuRow(label: "Последнее обновление", value: s.lastSuccess.map(Format.time) ?? dash),
                ]),
            ],
            note: s.ratedWatts.map { "Оценка: нагрузка × \(Format.number($0, digits: 0...2)) Вт / 100; не счётчик сети" } ?? "Номинальная мощность не настроена; новые Wh не рассчитываются")
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
        guard let r else { return "⚠️ UPS —" }
        let watts = r.estimatedWatts(ratedWatts: ratedWatts).map { String(format: "≈%.0f Вт", $0) } ?? (ratedWatts == nil ? "мощность не настроена" : "— Вт")
        if r.onBattery {
            let volts = batteryValue(r.batteryVoltage, "В", digits: 1)
            return "🔋 \(volts) · \(watts) · OB" + (r.lowBattery ? " LB" : "")
        }
        let symbol = r.online ? "⚡" : "⚠️"
        let volts = r.input.map { String(format: "%.0f В", $0) } ?? "— В"
        let load = r.load.map { String(format: "%.0f%%", $0) } ?? "—%"
        return "\(symbol) \(volts) · \(watts) · \(load)"
    }

    static func stateText(link: LinkState, reading r: Reading?) -> String {
        switch link {
        case .notConfigured: return "⚙️ ИБП не настроен"
        case .waiting: return "⏳ Ожидание данных"
        case .stale: return "🟡 Данные устарели"
        case .noResponse: return "🔴 Нет ответа NUT"
        case .invalid: return "🔴 Некорректный ответ NUT"
        case .ok:
            guard let r else { return "⏳ Ожидание данных" }
            if r.onBattery { return r.lowBattery ? "🔴 От аккумулятора, низкий заряд" : "🟠 От аккумулятора" }
            if r.online { return "🟢 От сети" }
            return "⚠️ Статус: \(r.status)"
        }
    }

    static func modeText(_ r: Reading) -> String {
        if r.onBattery { return "Разряд" }
        if r.online { return "От сети" }
        return r.status
    }

    static func linkText(_ link: LinkState) -> String {
        switch link {
        case .notConfigured: return "не настроен"
        case .waiting: return "ожидание"
        case .ok: return "подключён"
        case .stale: return "данные устарели"
        case .noResponse(let reason): return "нет ответа (\(reason))"
        case .invalid: return "некорректный ответ"
        }
    }

    static func outageStartText(current: Outage?, last: Outage?) -> String {
        if let current { return "идёт с \(Format.time(current.start))" }
        if let last { return Format.dateTime(last.start) }
        return "не зафиксировано"
    }

    static func outageDuration(_ outage: Outage, now: Date) -> String {
        Format.duration(outage.duration(now: now)) + (outage.end == nil ? " (идёт)" : "")
    }
}

/// Russian number formatting: decimal comma, no grouping.
enum Format {
    private static let locale = Locale(identifier: "ru_RU")
    private static let timeFormatter = formatter("HH:mm:ss")
    private static let dateTimeFormatter = formatter("dd.MM.yyyy HH:mm")

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = pattern
        return f
    }

    static func number(_ value: Double, digits: ClosedRange<Int>) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = digits.lowerBound
        f.maximumFractionDigits = digits.upperBound
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func value(_ value: Double?, _ unit: String, digits: Int, space: Bool = true, approx: Bool = false) -> String {
        Self.value(value, unit, digits: digits...digits, space: space, approx: approx)
    }

    static func value(_ value: Double?, _ unit: String, digits: ClosedRange<Int>, space: Bool = true, approx: Bool = false) -> String {
        guard let value else { return MenuModel.unavailable }
        return (approx ? "≈" : "") + number(value, digits: digits) + (space ? " " : "") + unit
    }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин \(s) с" }
        return "\(s) с"
    }
}
