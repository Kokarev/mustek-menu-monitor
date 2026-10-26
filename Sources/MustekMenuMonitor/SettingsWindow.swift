import AppKit

/// Native settings window. All logic lives in `SettingsController`; this class only maps
/// fields to drafts and shows results. Long operations run in tasks with the buttons disabled.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let controller: SettingsController

    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let ratedWattsField = NSTextField()
    private let upsBox = NSComboBox()
    private let findButton = NSButton(title: "Найти", target: nil, action: nil)
    private let manualPath = NSButton(checkboxWithTitle: "Указать путь к upsc вручную", target: nil, action: nil)
    private let pathField = NSTextField()
    private let chooseButton = NSButton(title: "Выбрать…", target: nil, action: nil)
    private let upscLabel = NSTextField(wrappingLabelWithString: "")
    private let activeLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkButton = NSButton(title: "Проверить", target: nil, action: nil)
    private let saveButton = NSButton(title: "Сохранить", target: nil, action: nil)
    private let closeButton = NSButton(title: "Закрыть", target: nil, action: nil)
    private var busy = false

    init(controller: SettingsController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Настройки MUSTEK Menu Monitor" + (AppIdentity.isQA ? " — QA" : "")
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
        ratedWattsField.stringValue = current.ratedWatts.map { String($0) } ?? ""
        upsBox.stringValue = current.upsName ?? ""
        manualPath.state = current.upscPath == nil ? .off : .on
        pathField.stringValue = current.upscPath ?? ""
        updatePathControls()
        showActive()
        statusLabel.stringValue = current.upsName == nil
            ? "ИБП ещё не настроен. Укажите сервер NUT и имя ИБП, затем нажмите «Проверить» или «Сохранить»."
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
        ratedWattsField.placeholderString = "Вт; пусто — мощность неизвестна"
        ratedWattsField.setAccessibilityIdentifier("ratedWatts")
        upsBox.placeholderString = "имя ИБП в ups.conf"
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
            [label("Сервер NUT:"), hostField],
            [label("Порт:"), portField],
            [label("Имя ИБП:"), upsRow],
            [label("Номинальная мощность, Вт:"), ratedWattsField],
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
            activeLabel.stringValue = "Сейчас действует: ИБП не настроен."; return
        }
        activeLabel.stringValue = "Сейчас действует: \(target), upsc: \(current.upscPath ?? "автоматически")."
    }

    private func show(_ failure: SettingsCheckFailure) {
        statusLabel.stringValue = "⚠️ " + failure.message
    }

    private func describe(_ report: SettingsCheckReport) -> String {
        var parts = ["статус \(report.status)"]
        if let input = report.input { parts.append("вход \(Format.number(input, digits: 1...1)) В") }
        if let load = report.load { parts.append("нагрузка \(Format.number(load, digits: 0...1))%") }
        return "\(report.target): " + parts.joined(separator: ", ")
    }

    /// Shows which upsc would be used and, in the background, its version.
    private func refreshUpsc() {
        guard let draft = draft() else { return }
        switch controller.locateUpsc(for: draft) {
        case .failure(let error):
            upscLabel.stringValue = SettingsCheckFailure.upsc(error).message
        case .success(let path):
            upscLabel.stringValue = "Используется \(path)"
            Task {
                guard let version = await controller.version(path: path) else { return }
                if case .success(path) = controller.locateUpsc(for: self.draft() ?? draft) {
                    upscLabel.stringValue = "Используется \(path) — \(version)"
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
        panel.message = "Выберите исполняемый файл upsc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
        refreshUpsc()
    }

    @objc private func find() {
        guard !busy, let draft = draft() else { return }
        setBusy(true, "Поиск ИБП на \(draft.host):\(draft.port)…")
        Task {
            let result = await controller.discover(draft)
            setBusy(false)
            switch result {
            case .failure(let failure): show(failure)
            case .success(let names) where names.isEmpty:
                statusLabel.stringValue = "⚠️ Сервер NUT ответил, но ИБП не найдено."
            case .success(let names):
                upsBox.removeAllItems()
                upsBox.addItems(withObjectValues: names)
                if !names.contains(upsBox.stringValue) { upsBox.stringValue = names[0] }
                statusLabel.stringValue = "Найдено: \(names.joined(separator: ", ")). Выберите ИБП и нажмите «Проверить»."
            }
        }
    }

    @objc private func check() {
        guard !busy, let draft = draft() else { return }
        setBusy(true, "Проверка подключения…")
        Task {
            let result = await controller.check(draft)
            setBusy(false)
            switch result {
            case .failure(let failure): show(failure)
            case .success(let report):
                statusLabel.stringValue = "✅ Есть связь — \(describe(report)). Настройки ещё не сохранены."
            }
        }
    }

    @objc private func save() {
        guard !busy, let draft = draft() else { return }
        setBusy(true, "Проверка и сохранение…")
        Task {
            let result = await controller.save(draft)
            setBusy(false)
            showActive()
            switch result {
            case .failure(let failure):
                statusLabel.stringValue = "⚠️ " + failure.message + "\nНастройки не сохранены; действуют прежние."
            case .success(let report):
                statusLabel.stringValue = "✅ Сохранено и применено — \(describe(report))."
            }
        }
    }

    @objc private func closeWindow() { window?.performClose(nil) }
}
