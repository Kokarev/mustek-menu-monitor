import AppKit

/// Native settings window. All logic lives in `SettingsController`; this class only maps
/// fields to drafts and shows results. Long operations run in tasks with the buttons disabled.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let controller: SettingsController

    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let ratedWattsField = NSTextField()
    private let upsBox = NSComboBox()
    private let findButton = NSButton(title: L10n.tr("Find"), target: nil, action: nil)
    private let manualPath = NSButton(checkboxWithTitle: L10n.tr("Set upsc path manually"), target: nil, action: nil)
    private let pathField = NSTextField()
    private let chooseButton = NSButton(title: L10n.tr("Choose…"), target: nil, action: nil)
    /// Internal for layout tests only.
    let upscLabel = NSTextField(wrappingLabelWithString: "")
    private let activeLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkButton = NSButton(title: L10n.tr("Check"), target: nil, action: nil)
    private let saveButton = NSButton(title: L10n.tr("Save"), target: nil, action: nil)
    private let closeButton = NSButton(title: L10n.tr("Close"), target: nil, action: nil)
    private var busy = false

    init(controller: SettingsController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = L10n.tr("UPS Menu Bar Settings") + (AppIdentity.isQA ? " — QA" : "")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window filled with the settings in effect.
    func show() {
        let current = controller.current
        hostField.stringValue = current.host
        portField.stringValue = String(current.port)
        ratedWattsField.stringValue = current.ratedWatts.map { Format.inputNumber($0) } ?? ""
        upsBox.stringValue = current.upsName ?? ""
        manualPath.state = current.upscPath == nil ? .off : .on
        pathField.stringValue = current.upscPath ?? ""
        updatePathControls()
        showActive()
        statusLabel.stringValue = current.upsName == nil
            ? L10n.tr("UPS is not configured. Enter the NUT server and UPS name, then click Check or Save.")
            : ""
        refreshUpsc()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        for field in [hostField, portField, pathField, ratedWattsField] { field.lineBreakMode = .byTruncatingMiddle }
        hostField.placeholderString = "127.0.0.1"
        portField.placeholderString = "3493"
        ratedWattsField.placeholderString = L10n.tr("W; leave empty if unknown")
        ratedWattsField.setAccessibilityIdentifier("ratedWatts")
        upsBox.placeholderString = L10n.tr("UPS name in ups.conf")
        upsBox.completes = true
        pathField.placeholderString = "/opt/homebrew/bin/upsc"
        for label in [upscLabel, activeLabel, statusLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 480
        }
        statusLabel.textColor = .labelColor
        statusLabel.isSelectable = true

        findButton.target = self; findButton.action = #selector(find)
        manualPath.target = self; manualPath.action = #selector(togglePath)
        chooseButton.target = self; chooseButton.action = #selector(choosePath)
        checkButton.target = self; checkButton.action = #selector(check)
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        closeButton.target = self; closeButton.action = #selector(closeWindow)
        closeButton.keyEquivalent = "\u{1b}"

        let upsRow = NSStackView(views: [upsBox, findButton])
        let pathRow = NSStackView(views: [pathField, chooseButton])
        let grid = NSGridView(views: [
            [label(L10n.tr("NUT server:")), hostField],
            [label(L10n.tr("Port:")), portField],
            [label(L10n.tr("UPS name:")), upsRow],
            [label(L10n.tr("Nominal power, W:")), ratedWattsField],
            [NSGridCell.emptyContentView, manualPath],
            [label("upsc:"), pathRow],
            [NSGridCell.emptyContentView, upscLabel],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        let buttons = NSStackView(views: [checkButton, NSView(), closeButton, saveButton])
        buttons.distribution = .fill
        let stack = NSStackView(views: [grid, activeLabel, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        // The upsc line gets its version later and is longer in some languages: wrap it within
        // the value column of this fixed-size window rather than at 480 pt past its edge (U-1).
        let labelColumn = (0..<grid.numberOfRows)
            .compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView?.fittingSize.width }.max() ?? 0
        upscLabel.preferredMaxLayoutWidth = min(480, content.bounds.width - stack.edgeInsets.left
                                                - stack.edgeInsets.right - grid.columnSpacing - labelColumn)
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    // MARK: State

    private var userPath: String? { manualPath.state == .on ? pathField.stringValue : nil }

    private func draft() -> Settings? {
        switch controller.draft(upsName: upsBox.stringValue, host: hostField.stringValue,
                                port: portField.stringValue, upscPath: userPath,
                                ratedWatts: ratedWattsField.stringValue) {
        case .success(let settings): return settings
        case .failure(let failure): show(failure); return nil
        }
    }

    private func updatePathControls() {
        pathField.isEnabled = manualPath.state == .on && !busy
        chooseButton.isEnabled = manualPath.state == .on && !busy
    }

    private func setBusy(_ value: Bool, _ text: String = "") {
        busy = value
        for control in [findButton, checkButton, saveButton, manualPath] as [NSControl] { control.isEnabled = !value }
        updatePathControls()
        if value { statusLabel.stringValue = text }
    }

    private func showActive() {
        let current = controller.current
        guard case .success(let target) = current.nutTarget() else {
            activeLabel.stringValue = L10n.tr("Currently active: UPS not configured."); return
        }
        activeLabel.stringValue = L10n.format("Currently active: %@, upsc: %@.", target, current.upscPath ?? L10n.tr("automatic"))
    }

    private func show(_ failure: SettingsCheckFailure) {
        statusLabel.stringValue = "⚠️ " + failure.message
    }

    private func describe(_ report: SettingsCheckReport) -> String {
        var parts = [L10n.format("status %@", report.status)]
        if let input = report.input { parts.append(L10n.format("input %@", Format.value(input, L10n.tr("V"), digits: 1))) }
        if let load = report.load { parts.append(L10n.format("load %@", Format.value(load, "%", digits: 0...1, space: false))) }
        return "\(report.target): " + parts.joined(separator: ", ")
    }

    /// Shows which upsc would be used and, in the background, its version.
    private func refreshUpsc() {
        guard let draft = draft() else { return }
        switch controller.locateUpsc(for: draft) {
        case .failure(let error):
            upscLabel.stringValue = SettingsCheckFailure.upsc(error).message
        case .success(let path):
            upscLabel.stringValue = L10n.format("Using %@", path)
            Task {
                guard let version = await controller.version(path: path) else { return }
                if case .success(path) = controller.locateUpsc(for: self.draft() ?? draft) {
                    upscLabel.stringValue = L10n.format("Using %@", path) + " — " + version
                }
            }
        }
    }

    // MARK: Actions

    @objc private func togglePath() {
        updatePathControls()
        refreshUpsc()
    }

    @objc private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.message = L10n.tr("Choose the upsc executable")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
        refreshUpsc()
    }

    @objc private func find() {
        guard !busy, let draft = draft() else { return }
        setBusy(true, L10n.format("Finding UPS devices on %@:%@…", draft.host, String(draft.port)))
        Task {
            let result = await controller.discover(draft)
            setBusy(false)
            switch result {
            case .failure(let failure): show(failure)
            case .success(let names) where names.isEmpty:
                statusLabel.stringValue = "⚠️ " + L10n.tr("NUT server responded, but no UPS devices were found.")
            case .success(let names):
                upsBox.removeAllItems()
                upsBox.addItems(withObjectValues: names)
                if !names.contains(upsBox.stringValue) { upsBox.stringValue = names[0] }
                statusLabel.stringValue = L10n.format("Found: %@. Select a UPS and click Check.", names.joined(separator: ", "))
            }
        }
    }

    @objc private func check() {
        guard !busy, let draft = draft() else { return }
        setBusy(true, L10n.tr("Checking connection…"))
        Task {
            let result = await controller.check(draft)
            setBusy(false)
            switch result {
            case .failure(let failure): show(failure)
            case .success(let report):
                statusLabel.stringValue = "✅ " + L10n.format("Connected — %@. Settings have not been saved yet.", describe(report))
            }
        }
    }

    @objc private func save() {
        guard !busy, let draft = draft() else { return }
        setBusy(true, L10n.tr("Checking and saving…"))
        Task {
            let result = await controller.save(draft)
            setBusy(false)
            showActive()
            switch result {
            case .failure(let failure):
                statusLabel.stringValue = "⚠️ " + failure.message + "\n" + L10n.tr("Settings not saved; previous settings remain active.")
            case .success(let report):
                statusLabel.stringValue = "✅ " + L10n.format("Saved and applied — %@.", describe(report))
            }
        }
    }

    @objc private func closeWindow() { window?.performClose(nil) }
}
