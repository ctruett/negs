import XCTest
@testable import NegsApp

/// Output: a lab scan on a Frontier or Noritsu, or a paper print.
@MainActor
final class LabScanTests: XCTestCase {
    private let stocks = [
        Stock(.object(["id": .string("gold"), "name": .string("Gold"), "paper": .bool(false), "positive": .bool(false),
                       "bw": .bool(false), "target_print": .string("endura"), "development_times": .array([])])),
        Stock(.object(["id": .string("provia"), "name": .string("Provia"), "paper": .bool(false), "positive": .bool(true),
                       "bw": .bool(false), "target_print": .string("endura"), "development_times": .array([])])),
        Stock(.object(["id": .string("endura"), "name": .string("Endura"), "paper": .bool(true), "positive": .bool(false),
                       "bw": .bool(false), "target_print": .string(""), "development_times": .array([])])),
    ]

    private func state(route: OutputRoute, film: String) -> EditState {
        var state = EditState()
        state.film = film; state.paper = "endura"
        state.params["io.output_route"] = .string(route.rawValue)
        return state
    }

    func testNewPhotoDefaultsToLabScanOnFrontier() {
        // The engine's own defaults are a paper print, for old edits.
        let engine: JSONValue = .object(["io": .object(["output_route": .string("paper_print")]),
                                         "scanner": .object(["model": .string("frontier")])])
        let defaults = EditorModel.appDefaults(engine)
        XCTAssertEqual(OutputRoute.of(defaults), .labScan)
        XCTAssertEqual(defaults["scanner.model"], .string("frontier"))
    }

    func testPickingNegativeAfterSlideKeepsLabScan() {
        let next = PreviewRules.choosing("gold", paper: false, in: state(route: .labScan, film: "provia"), stocks: stocks)
        XCTAssertEqual(OutputRoute.of(next.params), .labScan)
    }

    func testPickingNegativeKeepsPaperPrintWhenSet() {
        let next = PreviewRules.choosing("gold", paper: false, in: state(route: .paperPrint, film: "gold"), stocks: stocks)
        XCTAssertEqual(OutputRoute.of(next.params), .paperPrint)
    }

    func testPositiveFilmForcesLabScan() {
        let next = PreviewRules.choosing("provia", paper: false, in: state(route: .paperPrint, film: "gold"), stocks: stocks)
        XCTAssertEqual(OutputRoute.of(next.params), .labScan)
    }

    func testOldDirectScanEditOpensAsFrontierLabScan() {
        var direct = EditState()
        direct.params = .object(["io": .object(["scan_film": .bool(true)])])
        let migrated = EditorModel.withRoute(direct)
        XCTAssertEqual(OutputRoute.of(migrated.params), .labScan)
        XCTAssertEqual(migrated.params["io.scan_film"], .null, "the old key is gone")
        // Missing scanner keys read as Frontier with no keys, the engine's defaults.
        XCTAssertEqual(migrated.params["scanner.model"], .null)

        var paper = EditState()
        paper.params = .object(["io": .object(["scan_film": .bool(false)])])
        XCTAssertEqual(OutputRoute.of(EditorModel.withRoute(paper).params), .paperPrint, "a paper edit stays on paper")

        var older = EditState()
        older.params = .object(["camera": .object(["exposure_compensation_ev": .number(1)])])
        XCTAssertEqual(OutputRoute.of(EditorModel.withRoute(older).params), .paperPrint, "an edit from before either key printed")

        let current = state(route: .labScan, film: "gold")
        XCTAssertEqual(EditorModel.withRoute(current), current, "a new edit is left alone")
        XCTAssertEqual(EditorModel.withRoute(EditState()), EditState(), "nothing to migrate")
    }

    func testSubtitleNamesScanner() {
        var params: JSONValue = .object([:])
        params["io.output_route"] = .string("lab_scan")
        params["scanner.model"] = .string("noritsu")
        XCTAssertEqual(EditorModel.stockCaption(params, film: "Portra 400", paper: "Endura"), "Portra 400 → Noritsu")
        params["scanner.model"] = .string("frontier")
        XCTAssertEqual(EditorModel.stockCaption(params, film: "Portra 400", paper: "Endura"), "Portra 400 → Frontier")
        params["io.output_route"] = .string("paper_print")
        XCTAssertEqual(EditorModel.stockCaption(params, film: "Portra 400", paper: "Endura"), "Portra 400 → Endura")
    }

    func testLUTNameUsesTheScanner() {
        var params: JSONValue = .object([:])
        params["io.output_route"] = .string("lab_scan")
        params["scanner.model"] = .string("noritsu")
        XCTAssertEqual(EditorModel.lutName(film: "kodak_portra_400", paper: "kodak_portra_endura", params: params), "kodak_portra_400_noritsu.cube")
        params["io.output_route"] = .string("paper_print")
        XCTAssertEqual(EditorModel.lutName(film: "kodak_portra_400", paper: "kodak_portra_endura", params: params), "kodak_portra_400_kodak_portra_endura.cube")
    }

    func testKeysClampToTwentySteps() {
        XCTAssertEqual(ScannerKeys.clamped(25), 20)
        XCTAssertEqual(ScannerKeys.clamped(-21.4), -20)
        XCTAssertEqual(ScannerKeys.clamped(3.6), 4, "keys are whole clicks")
    }
}
