import AppKit

/// Owns the status item and wires monitor updates to the menu.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem?
    private var content: MenuContent?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let content = MenuContent(openHistory: { [weak self] in self?.monitor.openHistory() })
        content.menu.delegate = self
        statusItem.menu = content.menu
        self.statusItem = statusItem
        self.content = content
        monitor.onChange = { [weak self] in self?.refresh() }
        refresh()
        monitor.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // An open menu must not present an old reading as current.
        monitor.checkStaleness(now: Date())
        refresh()
    }

    private func refresh() {
        let model = MenuModel.make(monitor.snapshot())
        statusItem?.button?.title = model.statusBarTitle
        content?.update(model)
    }
}

@main enum MustekMenuMonitorApp {
    @MainActor static func main() {
        // Single instance: taken before the monitor exists, so a second copy never reads or writes history.
        let lock: InstanceLock
        switch InstanceLock.acquire(at: Monitor.defaultDirectory.appendingPathComponent(".lock")) {
        case .acquired(let acquired):
            lock = acquired
        case .heldElsewhere:
            FileHandle.standardError.write(Data("MustekMenuMonitor: another instance is running; exiting.\n".utf8))
            exit(0)
        case .unavailable(let error):
            FileHandle.standardError.write(Data("MustekMenuMonitor: instance lock unavailable (\(String(cString: strerror(error)))); exiting.\n".utf8))
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime((delegate, lock)) { app.run() }
    }
}
