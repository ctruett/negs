import AppKit
import SwiftUI
import XCTest
@testable import NegsApp

/// The zones: where they sit on the L\* axis and the tones they print as.
final class ZoneSystemTests: XCTestCase {
    /// Adams' eleven zones, evenly spaced in lightness as a print shows them.
    func testTheElevenZonesRunFromPureBlackToPureWhite() throws {
        let zones = ZoneScale.zones
        try XCTSkipUnless(zones.count == 11 || { XCTFail("\(zones.count) zones"); return false }())
        for (index, zone) in zones.enumerated() {
            XCTAssertEqual(zone.index, index)
            XCTAssertEqual(zone.numeral, "\(index)")
            XCTAssertEqual(zone.target, Double(index) * 10)
        }
        XCTAssertEqual(zones[0].name, "Pure black")
        XCTAssertEqual(zones[5].name, "Middle gray")
        XCTAssertEqual(zones[10].name, "Pure white")
    }

    /// Zone 5 is 18 % gray, the point meters are calibrated to.
    func testZoneFiveIsEighteenPercentGray() {
        let y = pow((ZoneScale.zones[5].target + 16) / 116, 3)
        XCTAssertEqual(y, 0.18, accuracy: 0.005)
    }

    func testATargetFallsInTheNearestZone() {
        XCTAssertEqual(ZoneScale.zone(forTarget: 0), 0)
        XCTAssertEqual(ZoneScale.zone(forTarget: 4.9), 0)
        XCTAssertEqual(ZoneScale.zone(forTarget: 5.1), 1)
        XCTAssertEqual(ZoneScale.zone(forTarget: 50), 5)
        XCTAssertEqual(ZoneScale.zone(forTarget: 100), 10)
        XCTAssertEqual(ZoneScale.zone(forTarget: 140), 10)
        XCTAssertEqual(ZoneScale.zone(forTarget: -5), 0)
    }

    /// A tile's tooltip names the zone and says what belongs in it.
    func testATilesTooltipDescribesTheZone() {
        let tip = ZonePanel.tooltip(for: ZoneScale.zones[5])
        XCTAssertTrue(tip.hasPrefix("Zone 5: Middle gray\n"), tip)
        XCTAssertTrue(tip.contains("18% gray"), tip)
        XCTAssertTrue(tip.contains("dark blue sky"), tip)
        for zone in ZoneScale.zones {
            XCTAssertFalse(zone.note.isEmpty, zone.numeral)
            XCTAssertTrue(ZonePanel.tooltip(for: zone).contains(zone.note), zone.numeral)
        }
    }

    func testTileLabelsNameTheZoneAndWhetherItIsPlaced() {
        XCTAssertEqual(ZonePanel.label(for: ZoneScale.zones[5], placed: true), "Zone 5, Middle gray, placed")
        XCTAssertEqual(ZonePanel.label(for: ZoneScale.zones[0], placed: false), "Zone 0, Pure black, not placed")
    }

    /// The bar is one scale, dark to light, with no lines between its tiles.
    @MainActor func testTheZoneBarIsOneScale() throws {
        _ = NSApplication.shared
        let model = EditorModel()
        defer { model.shutdown() }
        let host = NSHostingView(rootView: ZonePanel(model: model).background(Color.white))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = bitmap.pixelsWide / Int(ZoneGeometry.barWidth)
        // Along a row clear of the numerals, the tone only ever rises: a line
        // between tiles would show as a dip below the tile before it.
        var previous: CGFloat = -1
        for x in (Int(ZoneGeometry.gripWidth) + 2)..<(Int(ZoneGeometry.barWidth) - 12) {
            let value = try XCTUnwrap(bitmap.colorAt(x: x * scale, y: 5 * scale)?.usingColorSpace(.sRGB)).redComponent * 255
            XCTAssertGreaterThanOrEqual(value, previous - 0.5, "A line at \(x)")
            previous = value
        }
        XCTAssertGreaterThan(previous, 200, "It ends in white")
    }

    /// The same line over a dark tile comes out lighter than the tile.
    @MainActor func testTheZoneEdgeIsLighterThanADarkTone() throws {
        let host = NSHostingView(rootView: Color.black.overlay { Rectangle().fill(ZonePanel.edgeColour) })
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let colour = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(colour.redComponent * 255, 20)
    }

    /// Tab shows and hides the pins, and stands down while typing in a field.
    @MainActor func testTabTogglesThePinsOutsideTextFields() {
        let tab: UInt16 = 48
        XCTAssertTrue(EditorWindowController.togglesPins(keyCode: tab, modifiers: [], firstResponder: NSView()))
        XCTAssertTrue(EditorWindowController.togglesPins(keyCode: tab, modifiers: [], firstResponder: nil))
        XCTAssertTrue(EditorWindowController.togglesPins(keyCode: tab, modifiers: [.capsLock], firstResponder: nil), "Caps Lock doesn't matter")
        XCTAssertFalse(EditorWindowController.togglesPins(keyCode: tab, modifiers: [], firstResponder: NSTextView()))
        XCTAssertFalse(EditorWindowController.togglesPins(keyCode: tab, modifiers: [.shift], firstResponder: nil), "Shift-Tab keeps its meaning")
        XCTAssertFalse(EditorWindowController.togglesPins(keyCode: tab, modifiers: [.control], firstResponder: nil))
        XCTAssertFalse(EditorWindowController.togglesPins(keyCode: 6, modifiers: [], firstResponder: nil), "Z no longer does")
    }

    /// Delete has no modifier, so it stands down while typing in a field.
    @MainActor func testBareKeysStandDownWhileEditingText() {
        XCTAssertFalse(MainMenu.bareKeysAllowed(firstResponder: NSTextView()))
        XCTAssertTrue(MainMenu.bareKeysAllowed(firstResponder: NSView()))
        XCTAssertTrue(MainMenu.bareKeysAllowed(firstResponder: nil))
    }

    func testGreysRiseFromBlackToPaperWhite() throws {
        let levels = try ZoneScale.zones.map { zone -> CGFloat in
            try XCTUnwrap(ZoneScale.grey(zone.index).usingColorSpace(.sRGB)).redComponent
        }
        XCTAssertEqual(try XCTUnwrap(levels.first), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(levels.last), 1, accuracy: 1e-9)
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(Set(levels).count, 11)
    }
}
