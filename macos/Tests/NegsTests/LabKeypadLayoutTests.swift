import AppKit
import SwiftUI
import XCTest
@testable import NegsApp

/// The Scan tab's Lab Scanner section, in the real inspector.
@MainActor
final class LabKeypadLayoutTests: XCTestCase {
    private func render(_ model: EditorModel, name: String) -> (NSView, NSWindow) {
        let host = NSHostingView(rootView: AdjustmentInspector(model: model).background(Color(nsColor: .underPageBackgroundColor)))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 2000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        if let folder = ProcessInfo.processInfo.environment["NEGS_INSPECTOR_LAYOUT_SNAPSHOTS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return (host, window)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Where each segmented control sits, in the host's coordinates.
    private func segmentFrames(_ host: NSView) -> [CGRect] {
        descendants(host).compactMap { $0 as? NSSegmentedControl }.map { host.convert($0.bounds, from: $0) }
    }

    /// The keypad alone, for a look (with NEGS_INSPECTOR_LAYOUT_SNAPSHOTS).
    func testKeypadRenders() throws {
        _ = NSApplication.shared
        let model = EditorModel()
        model.stepKey("scanner.cyan_key", by: 2)
        model.stepKey("scanner.density_key", by: -3)
        let host = NSHostingView(rootView: LabKeypad(model: model).padding(16).frame(width: 330).background(Color(nsColor: .underPageBackgroundColor)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 150)
        if let folder = ProcessInfo.processInfo.environment["NEGS_INSPECTOR_LAYOUT_SNAPSHOTS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("keypad.png"))
        }
    }

    /// Moving a slider leaves the Frontier and Noritsu control where it was.
    func testTheScannerChoiceStaysPutWhileASliderMoves() throws {
        _ = NSApplication.shared
        let model = EditorModel()
        model.inspectorMode = .advanced
        model.inspectorTab = .scan
        model.chooseOutput(.labScan)
        let (before, window) = render(model, name: "scan-tab-lab")
        let still = segmentFrames(before)
        window.orderOut(nil)
        XCTAssertFalse(still.isEmpty, "the scanner choice is on the Scan tab")
        for value in [-60.0, 35.0, 100.0] {
            model.set("post.brightness", .number(value))
            model.stepKey("scanner.cyan_key", by: 1)
            let (host, window) = render(model, name: "scan-tab-lab-\(Int(value))")
            defer { window.orderOut(nil) }
            XCTAssertEqual(segmentFrames(host), still, "after Brightness \(value)")
        }
    }
}
