import AppKit
import IOSurface
import XCTest
@testable import NegsApp

@MainActor final class CanvasGestureTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)

    private func makeView(rotation: Int = 0, crop: CropSettings = CropSettings()) -> PhotographView {
        _ = NSApplication.shared
        let cropped = crop.size(of: size)
        let display = rotation % 2 != 0 ? CGSize(width: cropped.height, height: cropped.width) : cropped
        let view = PhotographView(frame: CGRect(origin: .zero, size: display))
        view.show(NSImage(size: size), size: size, rotation: rotation, crop: crop)
        view.layout()
        return view
    }

    private func viewPoint(_ unit: CGPoint, in view: PhotographView) -> CGPoint {
        let photo = CGPoint(x: unit.x * size.width, y: (1 - unit.y) * size.height)
        return view.layer!.convert(photo, from: view.photographLayer)
    }

    // MARK: The gesture map

    func testADoubleClickZooms() {
        XCTAssertEqual(CanvasGesture.start(clickCount: 2), .zoomToggle)
    }

    /// As in RPP: a plain drag selects a region, the middle button pans.
    func testAPlainPressSelectsAndTheMiddleButtonPans() {
        XCTAssertEqual(CanvasGesture.start(clickCount: 1), .select)
        XCTAssertEqual(CanvasGesture.start(clickCount: 1, middle: true), .pan)
        XCTAssertEqual(CanvasGesture.start(clickCount: 1, control: true, middle: true), .pan, "The middle button always pans")
    }

    /// ⌃ reads a tone against the zones ahead of a double-click's zoom, and
    /// with ⌥ a larger patch. ⌘ is the white balance's, ahead of both.
    func testControlReadsAZone() {
        XCTAssertEqual(CanvasGesture.start(clickCount: 1, control: true), .pickZone(large: false))
        XCTAssertEqual(CanvasGesture.start(clickCount: 2, control: true), .pickZone(large: false))
        XCTAssertEqual(CanvasGesture.start(clickCount: 1, control: true, option: true), .pickZone(large: true))
        XCTAssertEqual(CanvasGesture.start(clickCount: 1, command: true, control: true), .pickWhiteBalance)
    }

    // MARK: The coordinate map

    func testUnitPointRoundTripsThroughCropAngleAndRotation() {
        let crop = CropSettings(rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), angle: 7)
        for rotation in 0..<4 {
            let view = makeView(rotation: rotation, crop: crop)
            for unit in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.45, y: 0.55)] {
                let back = view.unitPoint(at: viewPoint(unit, in: view))
                XCTAssertNotNil(back, "rotation \(rotation), \(unit)")
                XCTAssertEqual(back?.x ?? .nan, unit.x, accuracy: 1e-6)
                XCTAssertEqual(back?.y ?? .nan, unit.y, accuracy: 1e-6)
            }
        }
    }

    func testPointOnTheBorderIsNil() {
        let view = makeView()
        let corner = CGPoint(x: view.clipLayer.bounds.maxX, y: view.clipLayer.bounds.maxY)
        XCTAssertNil(view.unitPoint(at: view.layer!.convert(corner, from: view.clipLayer)))
    }

    func testPointOutsideTheCropIsNil() {
        let crop = CropSettings(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let view = makeView(crop: crop)
        XCTAssertNil(view.unitPoint(at: viewPoint(CGPoint(x: 0.1, y: 0.1), in: view)))
        XCTAssertNotNil(view.unitPoint(at: viewPoint(CGPoint(x: 0.5, y: 0.5), in: view)))
    }
}

extension CanvasGestureTests {
    func testDoubleClickZoomsAboutTheClickedPoint() {
        _ = NSApplication.shared
        let scroll = ImageScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.contentView = CenteringClipView()
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        scroll.fitting = true
        scroll.layoutSubtreeIfNeeded()
        scroll.applyZoom()
        let point = CGPoint(x: 700, y: 200)
        let before = scroll.contentView.convert(point, from: scroll.documentView)
        scroll.toggleZoom(about: point)
        XCTAssertFalse(scroll.fitting)
        let after = scroll.contentView.convert(point, from: scroll.documentView)
        XCTAssertEqual(before.x, after.x, accuracy: 1)
        XCTAssertEqual(before.y, after.y, accuracy: 1)
        // A second double-click fits the whole photograph again.
        scroll.toggleZoom(about: point)
        XCTAssertTrue(scroll.fitting)
    }

    private func surface(
        width: Int, height: Int, _ pixel: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)
    ) throws -> IOSurface {
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]))
        surface.lock(options: [], seed: nil)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let point = base + y * surface.bytesPerRow + x * 4
                point[0] = b; point[1] = g; point[2] = r; point[3] = 255
            }
        }
        surface.unlock(options: [], seed: nil)
        return surface
    }
    // MARK: The overlay

    private func makeCanvas(rotation: Int = 0, crop: CropSettings = CropSettings(), viewport: CGFloat = 600, frame: CGSize? = nil) -> (ImageScrollView, PhotographView) {
        _ = NSApplication.shared
        let scroll = ImageScrollView(frame: NSRect(x: 0, y: 0, width: viewport, height: viewport))
        scroll.allowsMagnification = true; scroll.minMagnification = 0.01; scroll.maxMagnification = 16
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        let cropped = crop.size(of: size)
        let display = frame ?? (rotation % 2 != 0 ? CGSize(width: cropped.height, height: cropped.width) : cropped)
        let view = PhotographView(frame: CGRect(origin: .zero, size: display))
        scroll.documentView = view
        scroll.tile()
        view.show(NSImage(size: size), size: size, rotation: rotation, crop: crop)
        view.layout()
        return (scroll, view)
    }

    private func overlayPoint(_ unit: CGPoint, _ scroll: ImageScrollView, _ view: PhotographView) -> CGPoint {
        scroll.overlay.convert(viewPoint(unit, in: view), from: view)
    }

    /// Set up as the app does: the clip view, scrollers and document all arrive
    /// after the overlay, which must still end up on top and tracking the clip.
    func testTheOverlayStaysOnTopOfTheAppsScrollViewSetup() throws {
        _ = NSApplication.shared
        let scroll = ImageScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        let view = PhotographView(frame: CGRect(origin: .zero, size: size))
        scroll.documentView = view
        scroll.tile()
        view.show(NSImage(size: size), size: size, rotation: 0)
        view.layout()
        XCTAssertTrue(scroll.subviews.last === scroll.overlay, "\(scroll.subviews)")
        XCTAssertEqual(scroll.overlay.frame, scroll.bounds)
        scroll.overlay.showFileName("ramp.png")
        let before = try XCTUnwrap(scroll.overlay.detailsFrame)
        scroll.contentView.scroll(to: CGPoint(x: 40, y: 0))
        XCTAssertEqual(try XCTUnwrap(scroll.overlay.detailsFrame).minX, max(before.minX - 40, CanvasOverlayView.exifGap * 2), accuracy: 0.5,
                       "It follows the app's own clip view")
    }

    // MARK: Pointer and wheel

    private func scrollEvent(_ delta: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// A plain drag selects the box the histogram counts, live; a click clears it.
    func testAPlainDragSelectsARegionAndAClickClearsIt() throws {
        let (_, view) = makeCanvas()
        var regions: [CGRect?] = []
        view.onSelectRegion = { regions.append($0) }
        let a = viewPoint(CGPoint(x: 0.2, y: 0.2), in: view), b = viewPoint(CGPoint(x: 0.6, y: 0.7), in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, at: a))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: b))
        view.mouseUp(with: try mouse(.leftMouseUp, at: b))
        let last = try XCTUnwrap(regions.last ?? nil)
        XCTAssertEqual(last.minX, 0.2, accuracy: 0.01); XCTAssertEqual(last.maxY, 0.7, accuracy: 0.01)
        view.mouseDown(with: try mouse(.leftMouseDown, at: a))
        view.mouseUp(with: try mouse(.leftMouseUp, at: a))
        XCTAssertEqual(regions.last, .some(nil), "A click goes back to the whole photograph")
    }

    /// A selected region stays outlined on the photograph.
    func testASelectedRegionIsOutlined() throws {
        let (scroll, view) = makeCanvas()
        view.region = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        scroll.overlay.redraw()
        let box = try XCTUnwrap(scroll.overlay.selectionBounds)
        let a = overlayPoint(CGPoint(x: 0.2, y: 0.2), scroll, view), b = overlayPoint(CGPoint(x: 0.6, y: 0.7), scroll, view)
        XCTAssertEqual(box.width, abs(b.x - a.x), accuracy: 1)
        XCTAssertEqual(box.height, abs(b.y - a.y), accuracy: 1)
    }

    /// A click on the canvas around the photograph clears the selection too.
    func testAClickBesideThePhotographClearsTheSelection() throws {
        _ = NSApplication.shared
        let scroll = ImageScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        scroll.contentView = CenteringClipView()
        let view = PhotographView(frame: CGRect(origin: .zero, size: size))
        scroll.documentView = view
        var regions: [CGRect?] = []
        view.onSelectRegion = { regions.append($0) }
        let clip = scroll.contentView
        clip.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2)))
        XCTAssertEqual(regions, [nil])
    }

    /// A ⌃-click reads 3 × 3 of the preview's pixels around it, ⌃⌥ 7 × 7, and
    /// a ⌃-drag the box it draws.
    func testControlClickAndDragReportTheAreaToRead() throws {
        let (_, view) = makeCanvas()
        var areas: [(CGPoint, CGPoint)] = []
        view.onPickZone = { areas.append(($0, $1)) }
        let centre = viewPoint(CGPoint(x: 0.5, y: 0.5), in: view)
        for flags in [[.control], [.control, .option]] as [NSEvent.ModifierFlags] {
            view.mouseDown(with: try mouse(.leftMouseDown, at: centre, flags: flags))
            view.mouseUp(with: try mouse(.leftMouseUp, at: centre, flags: flags))
        }
        let corner = viewPoint(CGPoint(x: 0.75, y: 0.75), in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, at: centre, flags: .control))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: corner, flags: .control))
        view.mouseUp(with: try mouse(.leftMouseUp, at: corner, flags: .control))
        XCTAssertEqual(areas.count, 3)
        XCTAssertEqual(areas[0].1.x - areas[0].0.x, 3 / size.width, accuracy: 1e-3)
        XCTAssertEqual(areas[1].1.y - areas[1].0.y, 7 / size.height, accuracy: 1e-3)
        XCTAssertEqual(areas[2].0.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(areas[2].1.x, 0.75, accuracy: 0.01)
        XCTAssertEqual(areas[2].1.y, 0.75, accuracy: 0.01)
    }

    /// The photograph takes the keyboard focus when it appears, so with Keyboard
    /// Navigation on, AppKit doesn't put a focus ring on a toolbar button instead.
    func testThePhotographTakesTheKeyboardFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let view = PhotographView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertTrue(window.initialFirstResponder === view)
    }

    /// It never takes the focus from a field being edited.
    func testThePhotographLeavesAFieldBeingEditedAlone() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = host
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        host.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        host.addSubview(PhotographView(frame: NSRect(x: 0, y: 40, width: 100, height: 100)))
        XCTAssertTrue(window.firstResponder === text)
    }

    /// A drop maps from the canvas's top left to the photograph; the border and
    /// the panel are not drop targets.
    func testADropOffThePhotographIsNil() throws {
        let (scroll, view) = makeCanvas()
        let scale = CanvasScale()
        scale.view = scroll
        // A canvas point is from the top left. The overlay is the one view here
        // known to be y-up, whichever way the scroll view runs.
        let inOverlay = scroll.overlay.convert(viewPoint(CGPoint(x: 0.25, y: 0.75), in: view), from: view)
        let centre = try XCTUnwrap(scale.unitPoint(canvasPoint: CGPoint(x: inOverlay.x, y: scroll.overlay.bounds.height - inOverlay.y)))
        XCTAssertEqual(centre.x, 0.25, accuracy: 0.01)
        XCTAssertEqual(centre.y, 0.75, accuracy: 0.01)
        XCTAssertNil(scale.unitPoint(canvasPoint: CGPoint(x: -10, y: scroll.overlay.bounds.height / 2)), "Over the panel")
        XCTAssertNil(scale.unitPoint(canvasPoint: CGPoint(x: inOverlay.x + 500, y: scroll.overlay.bounds.height - inOverlay.y)), "On the empty canvas beside the photograph")
    }

    /// The unit point reads the photograph as shown: near the top of a
    /// top-black gradient is a dark tone, near the bottom a light one.
    func testUnitPointIsNotMirrored() throws {
        _ = NSApplication.shared
        let (w, h) = (Int(size.width), Int(size.height))
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: w, .height: h, .bytesPerElement: 4,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4),
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]))
        surface.lock(options: [], seed: nil)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let value = UInt8(y * 255 / (h - 1))
            for x in 0..<w {
                let p = base + y * surface.bytesPerRow + x * 4
                p[0] = value; p[1] = value; p[2] = value; p[3] = 255
            }
        }
        surface.unlock(options: [], seed: nil)

        let view = PhotographView(frame: CGRect(origin: .zero, size: size))
        view.show(surface, size: size, rotation: 0)
        view.layout()
        let top = try XCTUnwrap(view.unitPoint(at: viewPoint(CGPoint(x: 0.5, y: 0.1), in: view)))
        let sample = try XCTUnwrap(TonePick.circle(centre: top, radius: 0).sample(surface))
        XCTAssertLessThan(sample.lstar, 35, "the top of the file is dark: \(top)")
    }
}
