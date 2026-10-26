import Foundation

/// Where this build keeps its data and settings. The QA build (`build-qa.sh`, compiled with
/// `-DMUSTEK_QA`) uses its own directory, lock and settings suite, so it can run beside an
/// installed copy. The public build contains no QA values and reads no environment overrides.
enum AppIdentity {
    #if MUSTEK_QA
    static let isQA = true
    static let dataDirectoryName = "MustekMenuMonitor-QA"
    static let titlePrefix = "QA · "
    /// Never the bundle identifier itself: UserDefaults rejects that as a suite name.
    static let settingsSuite: String? = "local.mustek.menumanager.qa.settings"
    #else
    static let isQA = false
    static let dataDirectoryName = "MustekMenuMonitor"
    static let titlePrefix = ""
    static let settingsSuite: String? = nil
    #endif

    /// The app's standard defaults, or the QA suite in a QA build.
    static func settingsDefaults() -> UserDefaults {
        guard let settingsSuite else { return .standard }
        guard let suite = UserDefaults(suiteName: settingsSuite) else {
            fatalError(L10n.tr("QA settings suite unavailable; refusing to use production settings."))
        }
        return suite
    }
}
