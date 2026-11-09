import AppKit
import SwiftUI
import XCTest
@testable import NegsApp

final class InspectorTabsTests: XCTestCase {
    func testWorkflowOrder() {
        XCTAssertEqual(InspectorTab.allCases.map(\.title), ["Camera", "Film", "Print", "Scan", "Export"])
    }

    /// In the all-controls column a double-click folds one heading, another
    /// brings it back, and the others stay as they were.
    func testAllControlsFoldsOneHeadingAtATime() {
        var stored = ""
        let folds = AllFolds(storage: Binding(get: { stored }, set: { stored = $0 }))
        folds.toggle("stage:Camera")
        folds.toggle("module:Grain")
        XCTAssertTrue(folds.contains("stage:Camera"))
        XCTAssertTrue(folds.contains("module:Grain"))
        XCTAssertFalse(folds.contains("stage:Film"))
        folds.toggle("stage:Camera")
        XCTAssertFalse(folds.contains("stage:Camera"))
        XCTAssertTrue(folds.contains("module:Grain"))
    }

    /// A part is shown unless it's hidden, and the eye, open, shows every part.
    func testHiddenPartsComeBackWithTheEye() {
        var stored = ""
        var parts = HiddenParts(storage: Binding(get: { stored }, set: { stored = $0 }), revealed: false)
        XCTAssertTrue(parts.shows("section:Tone"))
        XCTAssertFalse(parts.any)
        parts.toggle("section:Tone")
        XCTAssertFalse(parts.shows("section:Tone"))
        XCTAssertTrue(parts.isHidden("section:Tone"))
        XCTAssertTrue(parts.shows("module:Grain"))
        XCTAssertTrue(parts.any)
        parts.revealed = true
        XCTAssertTrue(parts.shows("section:Tone"), "The open eye shows everything")
        XCTAssertTrue(parts.isHidden("section:Tone"), "and remembers what's hidden")
        parts.toggle("section:Tone")
        XCTAssertFalse(parts.any)
    }

    /// A stage can be hidden like a section; the tab shown moves off a hidden
    /// one, and with every stage hidden, the first stays.
    func testAHiddenStageGivesUpItsTab() {
        var stored = ""
        let parts = HiddenParts(storage: Binding(get: { stored }, set: { stored = $0 }), revealed: false)
        XCTAssertEqual(parts.visibleTab(.scan), .scan)
        parts.toggle(InspectorTab.scan.hideKey)
        XCTAssertEqual(parts.visibleTab(.scan), .camera)
        XCTAssertEqual(parts.visibleTabs, [.camera, .film, .print, .export])
        for tab in InspectorTab.allCases where tab != .scan { parts.toggle(tab.hideKey) }
        XCTAssertEqual(parts.visibleTab(.film), .camera, "Never no tab at all")
        XCTAssertEqual(HiddenParts(storage: Binding(get: { stored }, set: { stored = $0 }), revealed: true).visibleTab(.scan), .scan)
    }

    /// A hidden stock leaves the picker, and a group it empties goes too,
    /// but the stock in use always stays; the open eye shows them all.
    func testHiddenStocksLeaveThePicker() {
        let stock = { (id: String) in Stock(.object(["id": .string(id), "name": .string(id)])) }
        let groups = [StockGroup(title: "Slide", stocks: [stock("velvia"), stock("provia")]),
                      StockGroup(title: "B&W", stocks: [stock("trix")])]
        var stored = ""
        let parts = HiddenParts(storage: Binding(get: { stored }, set: { stored = $0 }), revealed: false)
        parts.toggle(Stock.hideKey("velvia"))
        parts.toggle(Stock.hideKey("trix"))
        let shown = parts.visible(groups, keeping: "provia")
        XCTAssertEqual(shown.map(\.title), ["Slide"])
        XCTAssertEqual(shown[0].stocks.map(\.id), ["provia"])
        XCTAssertEqual(parts.visible(groups, keeping: "trix").flatMap(\.stocks).map(\.id), ["provia", "trix"], "The one in use stays")
        let open = HiddenParts(storage: Binding(get: { stored }, set: { stored = $0 }), revealed: true)
        XCTAssertEqual(open.visible(groups, keeping: "provia").flatMap(\.stocks).count, 3)
    }

    /// Sections keep the order they're dragged into; one the order doesn't
    /// know yet keeps its own place, and a section that's gone is skipped.
    func testSectionsKeepTheOrderTheyAreDraggedInto() {
        let shipped = ["a", "b", "c", "d"]
        XCTAssertEqual(SectionOrder.arranged(shipped, saved: []), shipped)
        let moved = SectionOrder.moving("d", before: "b", in: shipped)
        XCTAssertEqual(moved, ["a", "d", "b", "c"])
        XCTAssertEqual(SectionOrder.arranged(shipped, saved: moved), ["a", "d", "b", "c"])
        XCTAssertEqual(SectionOrder.moving("a", after: "d", in: shipped), ["b", "c", "d", "a"])
        // A new section, and one no longer shown.
        XCTAssertEqual(SectionOrder.arranged(["a", "b", "new", "c", "d"], saved: ["gone", "a", "d", "b", "c"]), ["a", "d", "new", "b", "c"])
    }

    func testPrintIsSkippedOnlyWhileScanningFilmDirectly() {
        XCTAssertTrue(InspectorTab.print.isSkipped(scanning: true))
        for tab in InspectorTab.allCases where tab != .print {
            XCTAssertFalse(tab.isSkipped(scanning: true))
        }
        XCTAssertFalse(InspectorTab.print.isSkipped(scanning: false))
    }

    /// An untouched tab has no edits; a linked slider counts once however many
    /// lanes it moved, and the total adds the tabs up.
    @MainActor func testEditsAreCountedByTab() {
        let model = EditorModel()
        defer { model.shutdown() }
        XCTAssertEqual(model.editCount, 0)
        model.set("post.blacks", .number(-24))
        XCTAssertEqual(model.editCount(on: .scan), 1, "Finishing tones are Scan's")
        XCTAssertEqual(model.editCount(on: .camera), 0)
        model.set("film_render.density_curves_morph.gamma_factor_red", .number(1.2))
        model.set("film_render.density_curves_morph.gamma_factor_blue", .number(0.8))
        XCTAssertEqual(model.editCount(on: .film), 1, "One linked slider")
        XCTAssertEqual(model.editCount, 2)
    }

    /// The linked slider moves its lanes together and keeps their differences.
    @MainActor func testLinkedLanesMoveTogether() {
        let model = EditorModel()
        defer { model.shutdown() }
        let root = "film_render.density_curves_morph"
        let lanes = ["red", "green", "blue"].map { ChannelLane(title: $0, path: "\(root).gamma_factor_\($0)") }
        model.set(lanes[0].path, .number(1.0)); model.set(lanes[1].path, .number(1.1)); model.set(lanes[2].path, .number(1.2))
        model.moveLanes(lanes, to: 1.3, range: 0.5...2, step: 0.01)
        XCTAssertEqual(lanes.map(model.laneValue)[0], 1.2, accuracy: 1e-9)
        XCTAssertEqual(lanes.map(model.laneValue)[1], 1.3, accuracy: 1e-9)
        XCTAssertEqual(lanes.map(model.laneValue)[2], 1.4, accuracy: 1e-9)
    }

    /// Both cuts of the edge print's font are bundled, and register under their names.
    func testTheBundledFontsRegister() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        EdgePrint.registerFont(data: root.appendingPathComponent("data"))
        XCTAssertEqual(EdgePrint.font(size: 14).fontName, "BarlowCondensed-SemiBold")
        XCTAssertEqual(EdgePrint.mediumFont(size: 18).fontName, "BarlowCondensed-Medium")
    }

    /// With previews off the stocks are a plain menu: a heading per group, ordinary
    /// rows, one check on the chosen stock, and a click that chooses.
    @MainActor func testTheStockMenuListsItsGroupsWithOneCheck() throws {
        _ = NSApplication.shared
        func stock(_ id: String, _ name: String) -> Stock {
            Stock(.object(["id": .string(id), "name": .string(name), "stage": .string("film")]))
        }
        let groups = [StockGroup(title: "Color Negative", stocks: [stock("a", "Kodak Portra 160"), stock("b", "Kodak Portra 400")]),
                      StockGroup(title: "Color Slide", stocks: [stock("c", "Fujifilm Velvia 100")])]
        var chosen: String?
        let menu = StockMenu.make(groups: groups, selected: "b") { chosen = $0 }
        XCTAssertEqual(menu.items.map(\.title), ["Color Negative", "Kodak Portra 160", "Kodak Portra 400", "", "Color Slide", "Fujifilm Velvia 100"])
        XCTAssertTrue(menu.items[0].isSectionHeader)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Kodak Portra 400"])
        XCTAssertTrue(menu.items.allSatisfy { $0.view == nil && $0.image == nil }, "Plain rows")
        menu.performActionForItem(at: 5)
        XCTAssertEqual(chosen, "c")
    }

    /// Every band a zone covers tiles the histogram, and shares add up to all of it.
    func testZoneSharesAddUpToTheWholePhotograph() {
        var histogram = Histogram()
        for index in histogram.luminance.indices { histogram.luminance[index] = UInt32(index % 7 + 1) }
        let total = ZoneScale.zones.reduce(0) { $0 + ZoneChartData.share(of: $1, in: histogram) }
        XCTAssertEqual(total, 1, accuracy: 1e-9)
        XCTAssertEqual(ZoneChartData.share(of: ZoneScale.zones[0], in: Histogram()), 0)
    }
}
