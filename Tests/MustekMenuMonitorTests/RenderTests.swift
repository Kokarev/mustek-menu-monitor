import AppKit
import XCTest
@testable import MustekMenuMonitor

/// Contrast and off-screen rendering of the menu content in light and dark appearance.
/// The menu is drawn onto windowBackgroundColor as an approximation of the menu material;
/// it is not a screenshot of the real NSMenu.
@MainActor final class RenderTests: XCTestCase {
    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    func testInformationalTextContrast() throws {
        for (name, appearanceName) in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var label = 0.0, secondary = 0.0, disabled = 0.0
            appearance.performAsCurrentDrawingAppearance {
                let background = NSColor.windowBackgroundColor
                label = contrast(.labelColor, on: background)
                secondary = contrast(.secondaryLabelColor, on: background)
                disabled = contrast(.disabledControlTextColor, on: background)
            }
            print("[contrast] \(name): labelColor \(String(format: "%.1f", label)):1, secondaryLabelColor \(String(format: "%.1f", secondary)):1, disabledControlTextColor (v0.1.1 rows) \(String(format: "%.1f", disabled)):1")
            XCTAssertGreaterThanOrEqual(label, 7, "\(name): data rows must meet WCAG AAA")
            XCTAssertGreaterThanOrEqual(secondary, 3, "\(name): section titles must stay readable")
            XCTAssertGreaterThan(label, disabled, "\(name): data rows must be more contrasted than disabled items")
        }
    }

    func testMenuUsesCustomViewsForTelemetry() throws {
        let content = MenuContent(openHistory: {})
        content.update(MenuModel.make(try freshSnapshot()))
        let informational = content.menu.items.filter { !$0.isSeparatorItem && $0.action == nil }
        XCTAssertFalse(informational.isEmpty)
        XCTAssertTrue(informational.allSatisfy { $0.view is MenuTextView }, "telemetry must not rely on disabled NSMenuItem titles")
        for item in informational {
            let view = try XCTUnwrap(item.view as? MenuTextView)
            XCTAssertNil(view.layer?.backgroundColor, "no fixed background colour")
        }
        let titles = content.menu.items.filter { $0.action != nil }.map(\.title)
        XCTAssertEqual(titles, ["Открыть журнал CSV", "Выход"])
    }

    func testRenderMenuInLightAndDark() throws {
        try render(MenuModel.make(try freshSnapshot()), prefix: "menu")
    }

    func testRenderNoResponseAndOutage() throws {
        let now = Date()
        var outage = Outage(start: now.addingTimeInterval(-754))
        outage.record(voltage: 12.8, at: now.addingTimeInterval(-750))
        outage.record(voltage: 12.4, at: now.addingTimeInterval(-10))
        let snapshot = MonitorSnapshot(link: .noResponse("upsd недоступен"), reading: nil, lastSuccess: now.addingTimeInterval(-40),
                                       todayWh: 1, monthWh: 1, currentOutage: outage, lastOutage: nil, now: now)
        try render(MenuModel.make(snapshot), prefix: "noresponse-outage")
    }

    /// Opt-in: MUSTEK_LIVE_UPSC=<ups@host:port> runs the real read-only `upsc` once and renders its values.
    func testLiveUpscReading() async throws {
        guard let target = ProcessInfo.processInfo.environment["MUSTEK_LIVE_UPSC"], target.contains("@") else {
            throw XCTSkip("set MUSTEK_LIVE_UPSC=<ups@host:port> to query a NUT server")
        }
        let outcome = await Upsc.run(path: Upsc.fallbackPath, target: target)
        guard case .output(let raw) = outcome else { return XCTFail("upsc failed: \(outcome)") }
        print("[live] raw upsc output:\n\(raw)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MustekLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = Monitor(historyDirectory: directory)
        monitor.handle(outcome, at: Date())
        XCTAssertEqual(monitor.link, .ok)
        let model = MenuModel.make(monitor.snapshot())
        print("[live] status bar: \(model.statusBarTitle)")
        print("[live] header: \(model.header)")
        for section in model.sections {
            print("[live] \(section.title)")
            for row in section.rows { print("[live]   \(row.label): \(row.value)") }
        }
        try render(model, prefix: "live")
    }

    // MARK: Helpers

    private func freshSnapshot() throws -> MonitorSnapshot {
        let now = Date()
        let reading = try XCTUnwrap(Reading.parse(sample(load: 6).replacingOccurrences(of: "230.0", with: "228.9"), at: now))
        return MonitorSnapshot(link: .ok, reading: reading, lastSuccess: now, todayWh: 1, monthWh: 1,
                               currentOutage: nil, lastOutage: nil, now: now)
    }

    /// Writes one PNG per appearance into MUSTEK_RENDER_DIR, when set.
    /// Each appearance gets its own MenuContent: the views are detached from their menu items
    /// for drawing, because an NSMenuItem resets the origin of the view it holds.
    private func render(_ model: MenuModel, prefix: String) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["MUSTEK_RENDER_DIR"] else { return }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearanceName) in appearances {
            let content = MenuContent(openHistory: {})
            content.update(model)
            let backdrop = Backdrop()
            backdrop.appearance = NSAppearance(named: appearanceName)
            var y: CGFloat = 6
            for item in content.menu.items {
                let view: NSView
                if let custom = item.view {
                    item.view = nil
                    view = custom
                } else if item.isSeparatorItem {
                    view = SeparatorLine(frame: NSRect(x: 0, y: 0, width: MenuTextView.width, height: 11))
                } else {
                    let row = MenuTextView(style: .row)
                    row.set(label: item.title, value: item.keyEquivalent.isEmpty ? "" : "⌘\(item.keyEquivalent.uppercased())")
                    view = row
                }
                view.removeFromSuperview()
                view.frame.origin = NSPoint(x: 0, y: y)
                backdrop.addSubview(view)
                y += view.frame.height
            }
            backdrop.frame = NSRect(x: 0, y: 0, width: MenuTextView.width, height: y + 6)
            // Text is measured and drawn with window metrics only inside a window; this one is never shown.
            let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = backdrop
            backdrop.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = output.appendingPathComponent("\(prefix)-\(name).png")
            try png.write(to: url)
            print("[render] \(url.path)")
        }
    }
}

private final class Backdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: bounds.midY, width: bounds.width - 28, height: 1).fill()
    }
}

/// WCAG contrast ratio of `foreground` (alpha-composited) over an opaque `background`.
private func contrast(_ foreground: NSColor, on background: NSColor) -> Double {
    guard let fg = foreground.usingColorSpace(.sRGB), let bg = background.usingColorSpace(.sRGB) else { return 0 }
    let a = fg.alphaComponent
    func mix(_ f: CGFloat, _ b: CGFloat) -> CGFloat { f * a + b * (1 - a) }
    let composite = (mix(fg.redComponent, bg.redComponent), mix(fg.greenComponent, bg.greenComponent), mix(fg.blueComponent, bg.blueComponent))
    func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double {
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    let l1 = luminance(composite.0, composite.1, composite.2)
    let l2 = luminance(bg.redComponent, bg.greenComponent, bg.blueComponent)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}
