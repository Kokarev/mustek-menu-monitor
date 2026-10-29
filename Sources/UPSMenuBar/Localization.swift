import Foundation

/// Standard bundle localization. Production uses macOS/app language preferences;
/// explicit preferences are provided only by tests, never by a UI switch.
struct AppLocalization {
    static let supported = ["en", "uk", "de", "ru"]
    static let resources: Bundle = {
        // Installed .app: do not depend on SwiftPM's absolute build-directory fallback.
        if let url = Bundle.main.url(forResource: "UPSMenuBar_UPSMenuBar", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    let language: String
    private let translated: Bundle
    private let english: Bundle

    init(preferences: [String]? = nil) {
        let resource = Self.resources
        let preferred = preferences.map { Bundle.preferredLocalizations(from: Self.supported, forPreferences: $0) }
            ?? resource.preferredLocalizations
        let selected = preferred.first ?? "en"
        language = Self.supported.contains(selected) ? selected : "en"
        // All four catalogs, including the English fallback, are packaged and checked by tests.
        english = Bundle(url: resource.url(forResource: "en", withExtension: "lproj")!)!
        translated = Bundle(url: resource.url(forResource: language, withExtension: "lproj")!) ?? english
    }

    func text(_ key: String) -> String {
        let fallback = english.localizedString(forKey: key, value: key, table: nil)
        return translated.localizedString(forKey: key, value: fallback, table: nil)
    }

    func format(_ key: String, _ arguments: [CVarArg], locale: Locale = .current) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

enum L10n {
    static let current = AppLocalization()
    static func tr(_ key: String) -> String { current.text(key) }
    static func format(_ key: String, _ arguments: CVarArg...) -> String { current.format(key, arguments) }
}
