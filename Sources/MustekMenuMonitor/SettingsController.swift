import Foundation

/// Runs upsc with arguments; injectable for tests.
typealias UpscExecutor = @Sendable (_ path: String, _ arguments: [String], _ timeout: TimeInterval) async -> UpscOutcome

/// Why a draft cannot be checked, discovered against or saved. Texts are for the settings window.
enum SettingsCheckFailure: Error, Equatable {
    case invalid([SettingsIssue])
    case noUpsName
    case upsc(UpscLocatorError)
    /// upsc ran but could not reach the UPS; the text says why.
    case connection(String)
    /// upsc answered without the values a reading needs.
    case invalidResponse
    case saveFailed

    var message: String {
        switch self {
        case .invalid(let issues): return issues.map(\.message).joined(separator: "\n")
        case .noUpsName: return "Укажите имя ИБП."
        case .upsc(.notFound): return "upsc не найден. Установите NUT (brew install nut) или укажите путь вручную."
        case .upsc(.userPathUnusable(_, let issue)): return issue.message
        case .connection(let reason): return "Нет связи: \(reason)."
        case .invalidResponse: return "Ответ NUT не содержит ups.status, input.voltage и ups.load."
        case .saveFailed: return "Не удалось сохранить настройки."
        }
    }
}

extension SettingsIssue {
    var message: String {
        switch self {
        case .upsNameEmpty: return "Укажите имя ИБП."
        case .upsNameInvalidCharacters: return "Имя ИБП: только латинские буквы, цифры, «_», «.» и «-»."
        case .upsNameLeadingHyphen: return "Имя ИБП не может начинаться с «-»."
        case .hostEmpty: return "Укажите адрес сервера NUT."
        case .hostInvalidCharacters: return "Адрес сервера: только латинские буквы, цифры, «.» и «-»."
        case .hostLeadingHyphen: return "Адрес сервера не может начинаться с «-»."
        case .hostIPv6NotSupported: return "Адреса IPv6 пока не поддерживаются."
        case .portOutOfRange: return "Порт: целое число от 1 до 65535."
        case .upscPathNotAbsolute: return "Путь к upsc должен быть полным (начинаться с «/»)."
        case .upscPathNotFound: return "Файл upsc по указанному пути не найден."
        case .upscPathNotExecutable: return "Указанный файл upsc не является исполняемым."
        case .ratedWattsNotFinite, .ratedWattsOutOfRange: return "Некорректная номинальная мощность."
        case .storedValueCorrupted: return "Сохранённое значение повреждено и сброшено."
        }
    }
}

/// Result of a successful connection check.
struct SettingsCheckReport: Equatable {
    let upscPath: String
    let target: String
    let status: String
    let input: Double?
    let load: Double?
    /// nil when `upsc -V` failed; the check itself still succeeded.
    let version: String?
}

/// Logic behind the settings window: discovery, checks and the only path that saves and applies.
/// A draft is saved and applied only after a successful check, so a failed attempt never
/// replaces the settings in effect.
@MainActor final class SettingsController {
    /// Settings in effect (saved and applied).
    private(set) var current: Settings
    private let store: SettingsStore
    private let apply: (Settings) -> Void
    private let locator: UpscLocator
    private let execute: UpscExecutor
    private let probe: UpscVersionProbe

    init(current: Settings, store: SettingsStore, locator: UpscLocator = UpscLocator(),
         execute: @escaping UpscExecutor = { await Upsc.execute(path: $0, arguments: $1, timeout: $2) },
         apply: @escaping (Settings) -> Void) {
        self.current = current
        self.store = store
        self.locator = locator
        self.execute = execute
        probe = UpscVersionProbe(run: execute)
        self.apply = apply
    }

    /// Settings from the window's fields; values the window does not edit are kept from `current`.
    func draft(upsName: String, host: String, port: String, upscPath: String?) -> Result<Settings, SettingsCheckFailure> {
        var draft = current
        let name = upsName.trimmingCharacters(in: .whitespaces)
        draft.upsName = name.isEmpty ? nil : name
        draft.host = host.trimmingCharacters(in: .whitespaces)
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)) else { return .failure(.invalid([.portOutOfRange])) }
        draft.port = number
        draft.upscPath = upscPath?.trimmingCharacters(in: .whitespaces)
        return .success(draft)
    }

    /// The upsc that would be used for this draft, without running it.
    func locateUpsc(for draft: Settings) -> Result<String, UpscLocatorError> {
        locator.locate(userPath: draft.upscPath)
    }

    func version(path: String) async -> String? {
        try? await probe.version(path: path).get()
    }

    /// UPS names served at the draft's host and port (`upsc -l host:port`).
    func discover(_ draft: Settings) async -> Result<[String], SettingsCheckFailure> {
        var server = draft
        server.upsName = nil
        let issues = server.validate().filter { [.host, .port, .upscPath].contains($0.field) }
        guard issues.isEmpty else { return .failure(.invalid(issues)) }
        let path: String
        switch locateUpsc(for: draft) {
        case .success(let found): path = found
        case .failure(let error): return .failure(.upsc(error))
        }
        switch await execute(path, ["-l", "\(draft.host):\(draft.port)"], Upsc.timeout) {
        case .output(let text):
            let names = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && Settings(upsName: $0).validate(checkFileSystem: false).isEmpty }
            return .success(names)
        case let outcome: return .failure(Self.failure(for: outcome))
        }
    }

    /// Queries the draft's UPS once and reports what NUT returned; nothing is saved.
    func check(_ draft: Settings) async -> Result<SettingsCheckReport, SettingsCheckFailure> {
        let issues = draft.validate()
        guard issues.isEmpty else { return .failure(.invalid(issues)) }
        guard case .success(let target) = draft.nutTarget() else { return .failure(.noUpsName) }
        let path: String
        switch locateUpsc(for: draft) {
        case .success(let found): path = found
        case .failure(let error): return .failure(.upsc(error))
        }
        switch await execute(path, [target], Upsc.timeout) {
        case .output(let raw):
            guard let reading = Reading.parse(raw, at: Date()) else { return .failure(.invalidResponse) }
            let version = await version(path: path)
            return .success(SettingsCheckReport(upscPath: path, target: target, status: reading.status,
                                                input: reading.input, load: reading.load, version: version))
        case let outcome: return .failure(Self.failure(for: outcome))
        }
    }

    /// Checks the draft, then saves and applies it. On any failure the settings in effect stay as they are.
    func save(_ draft: Settings) async -> Result<SettingsCheckReport, SettingsCheckFailure> {
        let result = await check(draft)
        guard case .success = result else { return result }
        do { try store.save(draft) } catch { return .failure(.saveFailed) }
        current = draft
        apply(draft)
        return result
    }

    private static func failure(for outcome: UpscOutcome) -> SettingsCheckFailure {
        switch outcome {
        case .output: return .invalidResponse
        case .timedOut: return .connection("тайм-аут")
        case .launchError: return .connection("upsc не запускается")
        case .failed(_, let message):
            if case .noResponse(let reason) = LinkState.forFailure(message: message) { return .connection(reason) }
            return .connection("данные устарели")
        }
    }
}
