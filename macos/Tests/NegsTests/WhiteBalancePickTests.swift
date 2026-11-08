import AppKit
import XCTest
@testable import NegsApp

/// ⌘-click or ⌘-drag on a RAW sets a Custom white balance that makes that spot
/// or area neutral, as one edit.
@MainActor final class WhiteBalancePickTests: XCTestCase {
    /// ⌘ goes to the picker ahead of a double-click's zoom.
    func testCommandPicksWhiteBalanceAheadOfOtherGestures() {
        XCTAssertEqual(CanvasGesture.start(clickCount: 1, command: true), .pickWhiteBalance)
        XCTAssertEqual(CanvasGesture.start(clickCount: 2, command: true), .pickWhiteBalance)
        XCTAssertEqual(CanvasGesture.start(clickCount: 1), .pan)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func model(in directory: URL) async throws -> EditorModel {
        let paths = EnginePaths(helper: root.appendingPathComponent("target/release/spektrafilm-native"),
                                exporter: root.appendingPathComponent("target/release/spektrafilm-f64"),
                                data: root.appendingPathComponent("data"))
        guard FileManager.default.isExecutableFile(atPath: paths.helper.path) else { throw XCTSkip("Build the release helper first") }
        let model = EditorModel(previewCache: RenderedPreviewCache(file: directory.appendingPathComponent("preview.cache")))
        await model.start(paths: paths)
        XCTAssertTrue(model.hasCatalog, model.error ?? "No catalog")
        return model
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Timed out")
    }

    func testAPickOnARawSetsCustomWhiteBalanceAsOneEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("negs-wb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("photo.dng")
        try FileManager.default.copyItem(at: root.appendingPathComponent("web/sample/DSC_6028.dng"), to: raw)
        let model = try await model(in: directory)
        defer { model.shutdown() }
        let undo = UndoManager()
        model.undoManager = undo
        model.open(raw)
        try await waitUntil { model.previewCurrent }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let before = model.state
        // An area: a box across the middle.
        model.pickWhiteBalance(from: CGPoint(x: 0.4, y: 0.4), to: CGPoint(x: 0.6, y: 0.6))
        try await waitUntil { model.value("io.raw_white_balance.mode").string == "custom" }
        let temperature = model.value("io.raw_white_balance.temperature").double
        let tint = model.value("io.raw_white_balance.tint").double
        XCTAssertTrue((1667...25000).contains(temperature), "\(temperature)")
        XCTAssertTrue(tint > 0 && tint <= 4, "\(tint)")
        XCTAssertEqual(undo.undoActionName, "Set White Balance")
        XCTAssertTrue(model.status.hasPrefix("White balance set to"), model.status)
        // The same area picked again, whatever the mode now, gives the same answer:
        // it's read from the neutral base, not from the current balance.
        model.pickWhiteBalance(from: CGPoint(x: 0.4, y: 0.4), to: CGPoint(x: 0.6, y: 0.6))
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(model.value("io.raw_white_balance.temperature").double, temperature, accuracy: 1)
        // One undo takes it back.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        undo.undo()
        if model.value("io.raw_white_balance.mode") == .string("custom") { undo.undo() }
        XCTAssertEqual(model.value("io.raw_white_balance.mode"), before.params["io.raw_white_balance.mode"])
        // A single point works too.
        model.pickWhiteBalance(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.5))
        try await waitUntil { model.value("io.raw_white_balance.mode").string == "custom" }
    }

    func testAPickOnANonRawSaysWhy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("negs-wb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 24))
        memset(bitmap.bitmapData!, 120, 96 * 24)
        let png = directory.appendingPathComponent("photo.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let model = try await model(in: directory)
        defer { model.shutdown() }
        model.open(png)
        try await waitUntil { model.previewCurrent }
        let before = model.state
        model.pickWhiteBalance(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(model.status, "White balance can be picked on RAW files")
        XCTAssertEqual(model.state, before)
    }

    /// The box shows while it's dragged and goes when it's done.
    func testTheOverlayDrawsTheBox() {
        let overlay = CanvasOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertFalse(overlay.marqueeShown)
        overlay.showMarquee(CGRect(x: 10, y: 10, width: 50, height: 30))
        XCTAssertTrue(overlay.marqueeShown)
        overlay.showMarquee(nil)
        XCTAssertFalse(overlay.marqueeShown)
    }
}
