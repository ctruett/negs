import XCTest
@testable import NegsApp

final class BatchEditTests: XCTestCase {
    private func state(_ params: [String: JSONValue]) -> EditState {
        var state = EditState(); state.params = .object(params); return state
    }

    /// Only what changed travels, so another photograph keeps its own look.
    func testOnlyTheChangedValuesCarry() {
        let old = state(["post": .object(["blacks": .number(0), "whites": .number(0)])])
        var new = old; new.params["post.blacks"] = .number(-24)
        let edit = BatchEdit(from: old, to: new)
        XCTAssertEqual(edit.params, [.init(path: "post.blacks", value: .number(-24))])

        let other = state(["post": .object(["blacks": .number(10), "whites": .number(30)])])
        let result = edit.applied(to: other)
        XCTAssertEqual(result.params["post.blacks"], .number(-24))
        XCTAssertEqual(result.params["post.whites"], .number(30), "Its own value stays")
    }

    func testFilmAndPaperCarry() {
        let old = EditState()
        var new = old; new.film = "kodak_portra_400"
        let edit = BatchEdit(from: old, to: new)
        XCTAssertEqual(edit.film, "kodak_portra_400")
        XCTAssertNil(edit.paper)
        var other = EditState(); other.paper = "kodak_ektacolor_edge"
        let result = edit.applied(to: other)
        XCTAssertEqual(result.film, "kodak_portra_400")
        XCTAssertEqual(result.paper, "kodak_ektacolor_edge")
    }

    /// Pins are measured on one photograph; rotation and crop are its framing.
    func testPinsRotationAndCropStayBehind() {
        let old = state(["post": .object(["tone_anchors": .array([])]), "io": .object(["rotate_cw": .number(0)])])
        var new = old
        new.params["post.tone_anchors"] = .array([.object(["input": .number(20), "target": .number(36)])])
        new.params["io.rotate_cw"] = .number(1)
        new.crop = CropSettings(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertTrue(BatchEdit(from: old, to: new).isEmpty)
    }

    /// An unchanged state has nothing to write.
    func testNothingChangedIsEmpty() {
        let same = state(["post": .object(["blacks": .number(-24)])])
        XCTAssertTrue(BatchEdit(from: same, to: same).isEmpty)
    }
}
