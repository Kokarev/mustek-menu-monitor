import AppKit

/// Text-only view for an informational menu row.
/// Disabled NSMenuItems draw their title in the grey "disabled" colour; a custom view keeps
/// the system label colours (light and dark appearance) and stays non-interactive.
final class MenuTextView: NSView {
    enum Style { case header, sectionTitle, row, note }

    static let width: CGFloat = 360
    private static let inset: CGFloat = 14

    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init(style: Style) {
        let height: CGFloat
        switch style {
        case .header: height = 24
        case .sectionTitle: height = 20
        case .row: height = 19
        case .note: height = 18
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        let menuSize = NSFont.menuFont(ofSize: 0).pointSize
        switch style {
        case .header:
            label.font = .boldSystemFont(ofSize: menuSize)
            label.textColor = .labelColor
        case .sectionTitle:
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
        case .row:
            label.font = .menuFont(ofSize: 0)
            label.textColor = .labelColor
            value.font = .monospacedDigitSystemFont(ofSize: menuSize, weight: .regular)
            value.textColor = .labelColor
            value.alignment = .right
        case .note:
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }

        // Only rows carry a right-aligned value; other styles give the label the full width.
        let fields = style == .row ? [label, value] : [label]
        for field in fields {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if style == .row {
            NSLayoutConstraint.activate([
                value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
                value.centerYAnchor.constraint(equalTo: centerYAnchor),
                value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            ])
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(label text: String, value valueText: String = "") {
        label.stringValue = text
        value.stringValue = valueText
        setAccessibilityLabel(valueText.isEmpty ? text : "\(text): \(valueText)")
    }
}

/// The status item's menu. Built once; texts are updated in place so an open menu refreshes live.
@MainActor final class MenuContent: NSObject {
    let menu = NSMenu()
    private let header = MenuTextView(style: .header)
    private var sectionViews: [(title: MenuTextView, rows: [MenuTextView])] = []
    private let note = MenuTextView(style: .note)
    private var layout: [[Int]] = []
    private let openHistory: () -> Void
    private let openSettings: () -> Void

    init(openHistory: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.openHistory = openHistory
        self.openSettings = openSettings
        super.init()
        menu.autoenablesItems = false
    }

    func update(_ model: MenuModel) {
        let shape = model.sections.map { [$0.rows.count] }
        if shape != layout { rebuild(for: model); layout = shape }
        header.set(label: model.header)
        for (views, section) in zip(sectionViews, model.sections) {
            views.title.set(label: section.title)
            for (view, row) in zip(views.rows, section.rows) { view.set(label: row.label, value: row.value) }
        }
        note.set(label: model.note)
    }

    private func rebuild(for model: MenuModel) {
        menu.removeAllItems()
        sectionViews = []
        menu.addItem(item(header))
        for section in model.sections {
            menu.addItem(.separator())
            let title = MenuTextView(style: .sectionTitle)
            menu.addItem(item(title))
            let rows = section.rows.map { _ in MenuTextView(style: .row) }
            rows.forEach { menu.addItem(item($0)) }
            if section.title == L10n.tr("Statistics") { menu.addItem(item(note)) }
            sectionViews.append((title, rows))
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.tr("Settings…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let open = NSMenuItem(title: L10n.tr("Open CSV log"), action: #selector(openHistoryAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: L10n.tr("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func openHistoryAction() { openHistory() }
    @objc private func openSettingsAction() { openSettings() }
}
