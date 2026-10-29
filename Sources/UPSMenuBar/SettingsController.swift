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
        case .noUpsName: return L10n.tr("Enter the UPS name.")
        case .upsc(.notFound): return L10n.tr("upsc not found. Install NUT (brew install nut) or specify its path manually.")
        case .upsc(.userPathUnusable(_, let issue)): return issue.message
        case .connection(let reason): return L10n.format("Cannot connect: %@.", reason)
        case .invalidResponse: return L10n.tr("NUT response lacks ups.status, input.voltage or ups.load.")
        case .saveFailed: return L10n.tr("Could not save settings.")
        }
    }
}

extension SettingsIssue {
    var message: String {
        switch self {
        case .upsNameEmpty: return L10n.tr("Enter the UPS name.")
        case .upsNameInvalidCharacters: return L10n.tr("UPS name: use only Latin letters, digits, _, . and -.")
        case .upsNameLeadingHyphen: return L10n.tr("UPS name cannot start with -.")
        case .hostEmpty: return L10n.tr("Enter the NUT server address.")
        case .hostInvalidCharacters: return L10n.tr("Server address: use only Latin letters, digits, . and -.")
        case .hostLeadingHyphen: return L10n.tr("Server address cannot start with -.")
        case .hostIPv6NotSupported: return L10n.tr("IPv6 addresses are not supported yet.")
        case .portOutOfRange: return L10n.tr("Port must be an integer from 1 to 65535.")
        case .upscPathNotAbsolute: return L10n.tr("upsc path must be absolute (start with /).")
        case .upscPathNotFound: return L10n.tr("upsc file not found at the specified path.")
        case .upscPathNotExecutable: return L10n.tr("The selected upsc file is not executable.")
        case .ratedWattsNotFinite, .ratedWattsOutOfRange: return L10n.tr("Nominal power must be 1–100000 W, or leave the field empty.")
        case .storedValueCorrupted: return L10n.tr("A stored value was invalid and has been reset.")
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

    /// Settings from the window's fields. A nil power field preserves `current`; empty text clears it.
    func draft(upsName: String, host: String, port: String, upscPath: String?, ratedWatts: String? = nil) -> Result<Settings, SettingsCheckFailure> {
        var draft = current
        let name = upsName.trimmingCharacters(in: .whitespaces)
        draft.upsName = name.isEmpty ? nil : name
        draft.host = host.trimmingCharacters(in: .whitespaces)
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)) else { return .failure(.invalid([.portOutOfRange])) }
        draft.port = number
        draft.upscPath = upscPath?.trimmingCharacters(in: .whitespaces)
        if let ratedWatts {
            let text = ratedWatts.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            if text.isEmpty { draft.ratedWatts = nil }
            else {
                guard let value = Double(text), value.isFinite else { return .failure(.invalid([.ratedWattsNotFinite])) }
                guard Settings.ratedWattsRange.contains(value) else { return .failure(.invalid([.ratedWattsOutOfRange])) }
                draft.ratedWatts = value
            }
        }
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
        case .timedOut: return .connection(L10n.tr("timeout"))
        case .launchError: return .connection(L10n.tr("upsc could not start"))
        case .failed(_, let message):
            if case .noResponse(let reason) = LinkState.forFailure(message: message) { return .connection(reason) }
            return .connection(L10n.tr("data stale"))
        }
    }
}
