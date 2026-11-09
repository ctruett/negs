import AppKit
import SwiftUI
import XCTest
@testable import NegsApp

/// The zones: where they sit on the L\* axis and the tones they print as.
final class ZoneSystemTests: XCTestCase {
    /// Zones 0 to VII, a stop apart, with their bands tiling the L* axis.
    func testTheEightZonesRunFromPureBlackToLightTexture() {
        let zones = ZoneScale.zones
        XCTAssertEqual(zones.map(\.numeral), ["0", "I", "II", "III", "IV", "V", "VI", "VII"])
        for (index, zone) in zones.enumerated() { XCTAssertEqual(zone.index, index) }
        for (zone, target) in zip(zones, [5.1, 10.0, 16.7, 25.3, 36.0, 49.5, 66.5, 88.0]) {
            XCTAssertEqual(zone.target, target, accuracy: 0.1, zone.numeral)
        }
        for (zone, high) in zip(zones, [7.2, 13.2, 20.8, 30.3, 42.4, 57.5, 76.6, 100.0]) {
            XCTAssertEqual(zone.band.upperBound, high, accuracy: 0.1, zone.numeral)
        }
        XCTAssertEqual(zones[0].band.lowerBound, 0)
        for (below, above) in zip(zones, zones.dropFirst()) {
            XCTAssertEqual(below.band.upperBound, above.band.lowerBound, accuracy: 1e-9)
        }
        XCTAssertEqual(zones[0].name, "Pure black")
        XCTAssertEqual(zones[5].name, "Middle gray")
        XCTAssertEqual(zones[7].name, "Light texture")
    }

    /// Zone V is 18 % gray, the point meters are calibrated to.
    func testZoneFiveIsEighteenPercentGray() {
        let y = pow((ZoneScale.zones[5].target + 16) / 116, 3)
        XCTAssertEqual(y, 0.18, accuracy: 0.005)
    }

    /// A plain placement aims for a zone's start, ⇧ for its middle; zone 0
    /// starts at black, which no exposure reaches, so it takes its middle.
    func testAZoneStartsAtTheBottomOfItsBand() {
        for zone in ZoneScale.zones.dropFirst() {
            XCTAssertEqual(zone.start, zone.band.lowerBound, zone.numeral)
            XCTAssertLessThan(zone.start, zone.target, zone.numeral)
        }
        XCTAssertEqual(ZoneScale.zones[0].start, ZoneScale.zones[0].target)
        XCTAssertEqual(ZoneScale.zones[5].start, 42.4, accuracy: 0.05)
    }

    /// The reading names the zone it prints in, by the bands' edges.
    func testAReadingKnowsItsZone() {
        var reading = ZoneReading(from: .zero, to: .zero)
        XCTAssertNil(reading.zone)
        XCTAssertFalse(reading.isRead)
        for (lstar, zone) in [(0.0, 0), (7.3, 1), (50, 5), (57.6, 7 - 1), (99, 7), (100, 7)] {
            reading.printed = lstar
            XCTAssertEqual(reading.zone, zone, "L* \(lstar)")
        }
        reading.toStart = Array(repeating: 0, count: 8); reading.toMiddle = Array(repeating: 0, count: 8)
        XCTAssertTrue(reading.isRead)
    }

    /// Stops read as the zone system writes them, with a true minus.
    func testStopsReadWithASignAndOneDecimal() {
        XCTAssertEqual(ZoneHistogramView.stops(1.26), "+1.3")
        XCTAssertEqual(ZoneHistogramView.stops(-0.74), "−0.7")
        XCTAssertEqual(ZoneHistogramView.stops(0.04), "0.0")
        XCTAssertEqual(ZoneHistogramView.stops(-0.04), "0.0")
    }

    /// 0 to 7 place the reading on that zone, ⇧ on its middle, and stand
    /// down while typing in a field or with another modifier.
    @MainActor func testNumberKeysPickAZoneOutsideTextFields() {
        func key(_ characters: String?, _ modifiers: NSEvent.ModifierFlags = [], _ responder: NSResponder? = nil) -> [Int] {
            EditorWindowController.zoneKey(characters: characters, modifiers: modifiers, firstResponder: responder)
                .map { [$0.zone, $0.centre ? 1 : 0] } ?? []
        }
        XCTAssertEqual(key("0"), [0, 0])
        XCTAssertEqual(key("5", [], NSView()), [5, 0])
        XCTAssertEqual(key("7", [.shift]), [7, 1], "⇧ for the middle")
        XCTAssertEqual(key("3", [.capsLock]), [3, 0], "Caps Lock doesn't matter")
        XCTAssertEqual(key("8"), [])
        XCTAssertEqual(key("a"), [])
        XCTAssertEqual(key("12"), [])
        XCTAssertEqual(key(nil), [])
        XCTAssertEqual(key("5", [], NSTextView()), [], "Typing in a field")
        XCTAssertEqual(key("5", [.command]), [])
        XCTAssertEqual(key("5", [.control]), [])
        XCTAssertEqual(key("5", [.option]), [])
    }

    /// Tab does nothing, except between text fields.
    @MainActor func testTabDoesNothingOutsideTextFields() {
        XCTAssertTrue(EditorWindowController.swallowsTab(keyCode: 48, firstResponder: NSView()))
        XCTAssertTrue(EditorWindowController.swallowsTab(keyCode: 48, firstResponder: nil))
        XCTAssertFalse(EditorWindowController.swallowsTab(keyCode: 48, firstResponder: NSTextView()))
        XCTAssertFalse(EditorWindowController.swallowsTab(keyCode: 49, firstResponder: NSView()))
    }

    /// A bare key stands down while typing in a field.
    @MainActor func testBareKeysStandDownWhileEditingText() {
        XCTAssertFalse(MainMenu.bareKeysAllowed(firstResponder: NSTextView()))
        XCTAssertTrue(MainMenu.bareKeysAllowed(firstResponder: NSView()))
        XCTAssertTrue(MainMenu.bareKeysAllowed(firstResponder: nil))
    }

    /// Centred with room to spare; off centre only to keep what's beside it clear.
    func testTheCanvasKeepsThePanelClear() {
        XCTAssertEqual(CenteringClipView.leadingGap(space: 400, leading: 56, trailing: 26), 200)
        XCTAssertEqual(CenteringClipView.leadingGap(space: 80, leading: 56, trailing: 26), 56)
        XCTAssertEqual(CenteringClipView.leadingGap(space: 30, leading: 56, trailing: 26), 30, "The panel first")
        XCTAssertEqual(CenteringClipView.leadingGap(space: 40, leading: 0, trailing: 26), 14, "Room for the details")
    }

    @MainActor func testBareArrowsStepThroughTheFolder() {
        XCTAssertEqual(EditorWindowController.photographStep(keyCode: 123, modifiers: [.numericPad, .function], firstResponder: nil), -1)
        XCTAssertEqual(EditorWindowController.photographStep(keyCode: 124, modifiers: [.numericPad, .function], firstResponder: nil), 1)
        XCTAssertNil(EditorWindowController.photographStep(keyCode: 124, modifiers: [.command], firstResponder: nil))
        XCTAssertNil(EditorWindowController.photographStep(keyCode: 124, modifiers: [], firstResponder: NSText()), "Typing")
        XCTAssertNil(EditorWindowController.photographStep(keyCode: 124, modifiers: [], firstResponder: NSSlider()), "A slider's own keys")
        XCTAssertNil(EditorWindowController.photographStep(keyCode: 126, modifiers: [], firstResponder: nil))
    }

    @MainActor func testBareFShowsOnlyThePhotograph() {
        XCTAssertTrue(EditorWindowController.togglesImageOnly(keyCode: 3, modifiers: [], firstResponder: nil))
        XCTAssertFalse(EditorWindowController.togglesImageOnly(keyCode: 3, modifiers: [.command, .option], firstResponder: nil), "Hide Film Strip")
        XCTAssertFalse(EditorWindowController.togglesImageOnly(keyCode: 3, modifiers: [], firstResponder: NSText()))
        XCTAssertFalse(EditorWindowController.togglesImageOnly(keyCode: 5, modifiers: [], firstResponder: nil))
    }

    func testGreysRiseFromBlackToLightGray() throws {
        let levels = try ZoneScale.zones.map { zone -> CGFloat in
            try XCTUnwrap(ZoneScale.grey(zone.index).usingColorSpace(.sRGB)).redComponent
        }
        XCTAssertEqual(try XCTUnwrap(levels.first), 0.067, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(levels.last), 0.867, accuracy: 0.01)
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(Set(levels).count, 8)
    }

}
