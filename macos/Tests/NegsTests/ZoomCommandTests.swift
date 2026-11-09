import XCTest
@testable import NegsApp

@MainActor
final class ZoomCommandTests: XCTestCase {
    func testCommandZeroFitsAndCommandOneShowsTheExportSize() {
        let model = EditorModel()
        model.zoomIn(); model.zoomIn()
        model.zoomToFit()
        XCTAssertTrue(model.fitShown)
        model.zoomActualSize()
        XCTAssertFalse(model.fitShown)
        XCTAssertEqual(model.canvasZoomSteps, 0, "100% is the export's size")
    }

    func testZoomingInLeavesTheFit() {
        let model = EditorModel()
        model.zoomToFit()
        model.zoomIn()
        XCTAssertFalse(model.fitShown)
        XCTAssertEqual(model.canvasZoomSteps, 1)
    }
}
