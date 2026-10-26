import Foundation

/// User configuration for the NUT connection and power estimate.
/// Not yet used by the monitor; defaults carry no demonstration values.
struct Settings: Equatable {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 3493
    static let portRange = 1...65535
    static let ratedWattsRange: ClosedRange<Double> = 1...100_000

    /// nil means the application is not configured yet.
    var upsName: String?
    var host: String = Settings.defaultHost
    var port: Int = Settings.defaultPort
    /// nil means upsc is located automatically.
    var upscPath: String?
    /// nil means the UPS rating is unknown and no watts are estimated.
    var ratedWatts: Double?
}

/// Settings field a validation problem belongs to.
enum SettingsField: String, CaseIterable {
    case upsName, host, port, upscPath, ratedWatts
}

/// One validation problem, structured for a future settings window.
enum SettingsIssue: Error, Equatable {
    case upsNameEmpty
    case upsNameInvalidCharacters
    case upsNameLeadingHyphen
    case hostEmpty
    case hostInvalidCharacters
    case hostLeadingHyphen
    /// IPv6 literals are rejected until the upsc address syntax for them is verified.
    case hostIPv6NotSupported
    case portOutOfRange
    case upscPathNotAbsolute
    case upscPathNotFound
    case upscPathNotExecutable
    case ratedWattsNotFinite
    case ratedWattsOutOfRange
    /// A stored value had the wrong type and was ignored.
    case storedValueCorrupted(SettingsField)

    var field: SettingsField {
        switch self {
        case .upsNameEmpty, .upsNameInvalidCharacters, .upsNameLeadingHyphen: return .upsName
        case .hostEmpty, .hostInvalidCharacters, .hostLeadingHyphen, .hostIPv6NotSupported: return .host
        case .portOutOfRange: return .port
        case .upscPathNotAbsolute, .upscPathNotFound, .upscPathNotExecutable: return .upscPath
        case .ratedWattsNotFinite, .ratedWattsOutOfRange: return .ratedWatts
        case .storedValueCorrupted(let field): return field
        }
    }
}

/// Why no NUT target can be formed.
enum NutTargetError: Error, Equatable {
    case notConfigured
    case invalid([SettingsIssue])
}

extension Settings {
    private static let upsNameCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    private static let hostCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")

    /// All problems, in field order. `checkFileSystem: false` skips the upsc file checks
    /// (existence and execute permission); the file is never run either way.
    func validate(checkFileSystem: Bool = true, fileManager: FileManager = .default) -> [SettingsIssue] {
        targetIssues() + upscPathIssues(checkFileSystem: checkFileSystem, fileManager: fileManager)
            + ratedWattsIssues()
    }

    /// `upsName@host:port`, built only from valid connection fields; upsc is not invoked.
    func nutTarget() -> Result<String, NutTargetError> {
        let issues = targetIssues()
        guard issues.isEmpty else { return .failure(.invalid(issues)) }
        guard let upsName else { return .failure(.notConfigured) }
        return .success("\(upsName)@\(host):\(port)")
    }

    private func targetIssues() -> [SettingsIssue] {
        var issues: [SettingsIssue] = []
        if let upsName {
            if upsName.isEmpty {
                issues.append(.upsNameEmpty)
            } else {
                if upsName.hasPrefix("-") { issues.append(.upsNameLeadingHyphen) }
                if !Self.only(upsName, in: Self.upsNameCharacters) { issues.append(.upsNameInvalidCharacters) }
            }
        }
        if host.isEmpty {
            issues.append(.hostEmpty)
        } else {
            if host.hasPrefix("-") { issues.append(.hostLeadingHyphen) }
            if host.contains(":") || host.hasPrefix("[") {
                issues.append(.hostIPv6NotSupported)
            } else if !Self.only(host, in: Self.hostCharacters) {
                issues.append(.hostInvalidCharacters)
            }
        }
        if !Self.portRange.contains(port) { issues.append(.portOutOfRange) }
        return issues
    }

    private func upscPathIssues(checkFileSystem: Bool, fileManager: FileManager) -> [SettingsIssue] {
        guard let upscPath else { return [] }
        guard upscPath.hasPrefix("/"), !upscPath.contains("\0") else { return [.upscPathNotAbsolute] }
        guard checkFileSystem else { return [] }
        return UpscLocator.problem(at: upscPath, fileManager: fileManager).map { [$0] } ?? []
    }

    private func ratedWattsIssues() -> [SettingsIssue] {
        guard let ratedWatts else { return [] }
        guard ratedWatts.isFinite else { return [.ratedWattsNotFinite] }
        return Self.ratedWattsRange.contains(ratedWatts) ? [] : [.ratedWattsOutOfRange]
    }

    private static func only(_ text: String, in allowed: CharacterSet) -> Bool {
        text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// The part of `UserDefaults` the store uses; tests can supply an in-memory one.
protocol SettingsBackend {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: SettingsBackend {}

/// Reads and writes `Settings` in an injected `UserDefaults`; there is no implicit default domain.
struct SettingsStore {
    enum Key: String, CaseIterable {
        case upsName = "nut.upsName"
        case host = "nut.host"
        case port = "nut.port"
        case upscPath = "upsc.path"
        case ratedWatts = "power.ratedWatts"

        var field: SettingsField {
            switch self {
            case .upsName: return .upsName
            case .host: return .host
            case .port: return .port
            case .upscPath: return .upscPath
            case .ratedWatts: return .ratedWatts
            }
        }
    }

    /// Loaded settings plus what was absent or rejected.
    struct LoadResult: Equatable {
        var settings: Settings
        /// Keys with no stored value; their fields hold defaults.
        var missing: Set<Key>
        /// Stored values that were rejected and replaced with defaults.
        var issues: [SettingsIssue]
    }

    enum SaveError: Error, Equatable {
        case invalid([SettingsIssue])
    }

    let defaults: SettingsBackend

    init(defaults: SettingsBackend) { self.defaults = defaults }

    /// Never fails: a wrong type or invalid stored value falls back to that field's default.
    /// The upsc file itself is not checked here, so a temporarily missing upsc keeps the user's choice.
    func load() -> LoadResult {
        var result = LoadResult(settings: Settings(), missing: [], issues: [])

        func stored<T>(_ key: Key, _ cast: (Any) -> T?) -> T? {
            guard let raw = defaults.object(forKey: key.rawValue) else {
                result.missing.insert(key); return nil
            }
            guard let value = cast(raw) else {
                result.issues.append(.storedValueCorrupted(key.field)); return nil
            }
            return value
        }
        /// Applies one field and keeps it only if it produces no problem of its own.
        func accept(_ field: SettingsField, _ apply: (inout Settings) -> Void) {
            var candidate = result.settings
            apply(&candidate)
            let problems = candidate.validate(checkFileSystem: false).filter { $0.field == field }
            if problems.isEmpty { result.settings = candidate } else { result.issues += problems }
        }

        if let value = stored(.upsName, { $0 as? String }) { accept(.upsName) { $0.upsName = value } }
        if let value = stored(.host, { $0 as? String }) { accept(.host) { $0.host = value } }
        if let value = stored(.port, Self.integer) { accept(.port) { $0.port = value } }
        if let value = stored(.upscPath, { $0 as? String }) { accept(.upscPath) { $0.upscPath = value } }
        if let value = stored(.ratedWatts, Self.double) { accept(.ratedWatts) { $0.ratedWatts = value } }
        return result
    }

    /// Writes all fields; nil removes the key. Invalid settings are not written at all.
    /// File checks for upsc are left to the caller, as in `load()`.
    func save(_ settings: Settings) throws {
        let issues = settings.validate(checkFileSystem: false)
        guard issues.isEmpty else { throw SaveError.invalid(issues) }
        set(settings.upsName, .upsName)
        set(settings.host, .host)
        set(settings.port, .port)
        set(settings.upscPath, .upscPath)
        set(settings.ratedWatts, .ratedWatts)
    }

    func reset() {
        Key.allCases.forEach { defaults.removeObject(forKey: $0.rawValue) }
    }

    private func set(_ value: Any?, _ key: Key) {
        if let value { defaults.set(value, forKey: key.rawValue) } else { defaults.removeObject(forKey: key.rawValue) }
    }

    /// NSNumber holding an exact integer; booleans and fractions are rejected.
    private static func integer(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber, !isBoolean(number) else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func double(_ raw: Any) -> Double? {
        guard let number = raw as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
