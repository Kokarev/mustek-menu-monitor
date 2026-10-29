import AppKit

/// Owns the status item and wires monitor updates to the menu.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor: Monitor
    private let store: SettingsStore
    private var statusItem: NSStatusItem?
    private var content: MenuContent?
    private var settingsWindow: SettingsWindowController?

    init(store: SettingsStore) {
        self.store = store
        monitor = Monitor(settings: store.load().settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let content = MenuContent(openHistory: { [weak self] in self?.monitor.openHistory() },
                                  openSettings: { [weak self] in self?.openSettings() })
        content.menu.delegate = self
        statusItem.menu = content.menu
        self.statusItem = statusItem
        self.content = content
        monitor.onChange = { [weak self] in self?.refresh() }
        refresh()
        monitor.start()
        // First launch: nothing to monitor until a UPS is chosen.
        if monitor.settings.upsName == nil { openSettings() }
    }

    private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsController(current: monitor.settings, store: store) { [weak self] settings in
                self?.monitor.apply(settings)
            }
            settingsWindow = SettingsWindowController(controller: controller)
        }
        settingsWindow?.show()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // An open menu must not present an old reading as current.
        monitor.checkStaleness(now: Date())
        refresh()
    }

    private func refresh() {
        let model = MenuModel.make(monitor.snapshot())
        let prefix = AppIdentity.titlePrefix
        statusItem?.button?.title = prefix + model.statusBarTitle
        content?.update(MenuModel(statusBarTitle: prefix + model.statusBarTitle, header: prefix + model.header,
                                  sections: model.sections, note: model.note))
    }
}

@main enum UPSMenuBarApp {
    @MainActor static func main() {
        // Single instance: taken before the monitor exists, so a second copy never reads or writes history.
        let lock: InstanceLock
        switch InstanceLock.acquire(at: Monitor.defaultDirectory.appendingPathComponent(".lock")) {
        case .acquired(let acquired):
            lock = acquired
        case .heldElsewhere:
            FileHandle.standardError.write(Data(("UPSMenuBar: " + L10n.tr("Another instance is running; exiting.") + "\n").utf8))
            exit(0)
        case .unavailable(let error):
            FileHandle.standardError.write(Data(("UPSMenuBar: " + L10n.format("Instance lock unavailable (%@); exiting.", String(cString: strerror(error))) + "\n").utf8))
            exit(1)
        }
        let app = NSApplication.shared
        // Settings are written only by a successful save in the settings window. Without a
        // stored UPS name the app starts not configured and never runs upsc.
        let delegate = AppDelegate(store: SettingsStore(defaults: AppIdentity.settingsDefaults()))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime((delegate, lock)) { app.run() }
    }
}
