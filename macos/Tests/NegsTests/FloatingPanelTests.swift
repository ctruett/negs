import AppKit
import SwiftUI
import XCTest
@testable import NegsApp

final class FloatingLayoutTests: XCTestCase {
    private let content = CGRect(x: 100, y: 200, width: 1200, height: 800)

    /// The sidebar runs the window's height at its right, inside the margins.
    func testTheSidebarFloatsAtTheRight() {
        let frame = FloatingLayout.sidebar(in: content, offset: .zero)
        XCTAssertEqual(frame, CGRect(x: 1300 - 8 - 340, y: 208, width: 340, height: 784))
    }

    /// The zone bar is centred over the canvas, which stops at the sidebar's gutter.
    func testTheZoneBarIsCentredOverTheCanvas() {
        let beside = FloatingLayout.zoneBar(in: content, sidebarVisible: true, offset: .zero)
        XCTAssertEqual(beside.midX, 100 + (1200 - FloatingLayout.gutter) / 2, accuracy: 0.01)
        XCTAssertEqual(beside.maxY, 1000 - 8, accuracy: 0.01)
        XCTAssertEqual(beside.size, CGSize(width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight))
        let alone = FloatingLayout.zoneBar(in: content, sidebarVisible: false, offset: .zero)
        XCTAssertEqual(alone.midX, content.midX, accuracy: 0.01)
    }

    /// A panel the user has moved keeps its place relative to the window.
    func testAnOffsetCarriesThrough() {
        let moved = FloatingLayout.zoneBar(in: content, sidebarVisible: true, offset: CGVector(dx: 30, dy: -40))
        let home = FloatingLayout.zoneBar(in: content, sidebarVisible: true, offset: .zero)
        XCTAssertEqual(moved.origin, CGPoint(x: home.minX + 30, y: home.minY - 40))
    }

    /// Dark at the left, as on a histogram.
    func testTilesRunDarkToLight() {
        XCTAssertEqual(ZoneGeometry.tileCentreX(zone: 0), ZoneGeometry.gripWidth + ZoneGeometry.tileWidth / 2)
        XCTAssertEqual(ZoneGeometry.tileCentreX(zone: 10), ZoneGeometry.barWidth - ZoneGeometry.tileWidth / 2)
    }
}

/// The real windows.
@MainActor final class FloatingPanelTests: XCTestCase {
    private func makeController() -> (EditorWindowController, EditorModel) {
        _ = NSApplication.shared
        let model = EditorModel()
        let controller = EditorWindowController(model: model)
        controller.showWindow(nil)
        addTeardownBlock { @MainActor in
            controller.window?.orderOut(nil)
            model.shutdown()
        }
        return (controller, model)
    }

    /// Floating, with no title bar and nothing to close them with.
    func testThePanelsHaveNoTitleBarAndCantClose() throws {
        let (controller, _) = makeController()
        for panel in [controller.sidebar, controller.zoneBar] {
            XCTAssertFalse(panel.styleMask.contains(.titled))
            XCTAssertFalse(panel.styleMask.contains(.closable))
            XCTAssertTrue(panel.hasShadow)
            XCTAssertFalse(panel.isOpaque)
            XCTAssertNil(panel.standardWindowButton(.closeButton))
        }
        XCTAssertTrue(controller.sidebar.parent === controller.window, "It travels with the window")
        // ⌘W with a field in the panel goes to the window, taking the panel with it.
        controller.sidebar.performClose(nil)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
        XCTAssertFalse(controller.sidebar.isVisible)
    }

    /// Typing needs the key window, and sliders mustn't take it from the photograph.
    func testAPanelTakesKeyOnlyToType() {
        let (controller, _) = makeController()
        XCTAssertTrue(controller.sidebar.canBecomeKey)
        XCTAssertFalse(controller.sidebar.canBecomeMain)
        XCTAssertTrue(controller.sidebar.becomesKeyOnlyIfNeeded)
    }

    func testTheSidebarFollowsItsToggleAndTheBarFollowsThePhoto() {
        let (controller, model) = makeController()
        controller.refresh()
        XCTAssertTrue(controller.sidebar.isVisible)
        XCTAssertFalse(controller.zoneBar.isVisible, "No photograph, no zones")
        model.inspectorVisible = false
        controller.refresh()
        XCTAssertFalse(controller.sidebar.isVisible)
        model.inspectorVisible = true
        controller.refresh()
        XCTAssertTrue(controller.sidebar.isVisible)
    }

    /// A resized window takes the sidebar's height and right edge with it.
    func testPanelsFollowTheWindowsSize() throws {
        let (controller, _) = makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 60, y: 60, width: 1200, height: 700), display: true)
        window.setFrame(NSRect(x: 60, y: 60, width: 1300, height: 800), display: true)
        let content = window.convertToScreen(window.contentLayoutRect)
        XCTAssertEqual(controller.sidebar.frame, FloatingLayout.sidebar(in: content, offset: .zero))
    }

    /// The corners are see-through, so the shadow and what's behind show the curve.
    func testThePanelsHaveRoundedCorners() throws {
        _ = NSApplication.shared
        let model = EditorModel()
        defer { model.shutdown() }
        let host = NSHostingView(rootView: InspectorPanel(model: model, built: false))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 1, accuracy: 0.01)
    }
}

/// A zone dragged out of its window lands where the pointer is on the canvas.
@MainActor final class ZoneBarDragTests: XCTestCase {
    private func canvas() throws -> (NSWindow, ImageScrollView, CanvasScale) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = ImageScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.contentView = CenteringClipView()
        scroll.allowsMagnification = true; scroll.minMagnification = 0.005; scroll.maxMagnification = 16
        let photo = PhotographView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = photo
        window.contentView = scroll
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        let scale = CanvasScale()
        scale.view = scroll
        return (window, scroll, scale)
    }

    /// The bar's top-left-based point goes through the screen to the canvas's
    /// top-left-based point. Both are y-down, the screen is y-up.
    func testABarPointBecomesACanvasPoint() throws {
        let (window, _, scale) = try canvas()
        // The bar sits 10 down and 20 in from the canvas's top left corner.
        let top = window.frame.maxY
        scale.zoneBarFrame = CGRect(x: window.frame.minX + 20, y: top - 10 - ZoneGeometry.barHeight, width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
        let point = try XCTUnwrap(scale.canvasPoint(barPoint: CGPoint(x: 5, y: 200)))
        XCTAssertEqual(point.x, 25, accuracy: 0.01)
        XCTAssertEqual(point.y, 210, accuracy: 0.01, "Down the bar is down the canvas")
    }

    /// Letting go over the bar itself cancels, even with photograph under it.
    func testADropOnTheBarPlacesNothing() throws {
        let (window, _, scale) = try canvas()
        scale.zoneBarFrame = CGRect(x: window.frame.minX + 20, y: window.frame.maxY - 10 - ZoneGeometry.barHeight, width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
        XCTAssertNil(scale.unitPoint(barPoint: CGPoint(x: 30, y: 10)))
    }

    /// A link starts at the bottom of its tile, wherever the bar has been dragged.
    func testALinkStartsUnderItsTile() throws {
        let (window, scroll, scale) = try canvas()
        let bar = CGRect(x: window.frame.minX + 30, y: window.frame.maxY - 100, width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
        scale.zoneBarFrame = bar
        scroll.overlay.zoneBarFrame = { [scale] in scale.zoneBarFrame }
        let photo = try XCTUnwrap(scroll.documentView as? PhotographView)
        photo.show(NSImage(size: photo.frame.size), size: photo.frame.size, rotation: 0)
        photo.layout()
        let marker = TonePinMarker(index: 0, zone: 3, source: PinSource(centre: CGPoint(x: 0.5, y: 0.5), radius: 0), selected: false)
        scroll.showPins([marker], dragged: nil)
        let link = try XCTUnwrap(scroll.overlay.links[0])
        XCTAssertEqual(link.from.x, 30 + ZoneGeometry.tileCentreX(zone: 3), accuracy: 0.5)
        XCTAssertEqual(link.from.y, scroll.overlay.bounds.height - 100, accuracy: 0.5, "Its bottom edge, y-up")
    }
}

/// The photograph makes room for the bar, and goes under it only when zoomed.
@MainActor final class CanvasTopInsetTests: XCTestCase {
    private func canvas(viewport: CGSize, photo: CGSize) -> ImageScrollView {
        _ = NSApplication.shared
        let scroll = ImageScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.contentView = CenteringClipView()
        scroll.allowsMagnification = true; scroll.minMagnification = 0.005; scroll.maxMagnification = 16
        scroll.documentView = PhotographView(frame: CGRect(origin: .zero, size: photo))
        scroll.tile()
        return scroll
    }

    private func edges(_ scroll: ImageScrollView) throws -> (top: CGFloat, bottom: CGFloat) {
        let photo = try XCTUnwrap(scroll.documentView)
        let overlay = scroll.overlay
        let a = overlay.convert(CGPoint.zero, from: photo).y
        let b = overlay.convert(CGPoint(x: 0, y: photo.frame.height), from: photo).y
        return (overlay.bounds.height - max(a, b), min(a, b))
    }

    /// Fit keeps all of it below the bar, centred in what's left.
    func testFitLeavesRoomForTheBar() throws {
        let scroll = canvas(viewport: CGSize(width: 1000, height: 600), photo: CGSize(width: 4000, height: 4000))
        scroll.topInset = 60
        scroll.applyZoom()
        XCTAssertEqual(scroll.magnification, 540.0 / 4000, accuracy: 0.001)
        let gaps = try edges(scroll)
        XCTAssertEqual(gaps.top, 60, accuracy: 0.5)
        XCTAssertEqual(gaps.bottom, 0, accuracy: 0.5)
    }

    /// A small photograph is centred in the room below the bar.
    func testASmallPhotographCentresBelowTheBar() throws {
        let scroll = canvas(viewport: CGSize(width: 1000, height: 600), photo: CGSize(width: 100, height: 100))
        scroll.topInset = 60
        scroll.magnification = 1
        scroll.pan(to: scroll.contentView.bounds.origin)
        let gaps = try edges(scroll)
        XCTAssertEqual(gaps.top - 60, gaps.bottom, accuracy: 0.5)
    }

    /// Zoomed in, every edge can be reached: its top can come down clear of the bar.
    func testPanningReachesTheTopBelowTheBar() throws {
        let scroll = canvas(viewport: CGSize(width: 500, height: 500), photo: CGSize(width: 2000, height: 2000))
        scroll.topInset = 60
        scroll.setFitting(false)
        scroll.magnification = 1
        scroll.pan(to: CGPoint(x: 0, y: 99_999))
        XCTAssertEqual(try edges(scroll).top, 60, accuracy: 0.5)
        scroll.pan(to: CGPoint(x: 0, y: -99_999))
        XCTAssertEqual(try edges(scroll).bottom, 0, accuracy: 0.5)
    }

    /// It pans when the room below the bar is too small, even if the canvas isn't.
    func testItCanPanWhenOnlyTheBarMakesItOverflow() {
        let scroll = canvas(viewport: CGSize(width: 800, height: 500), photo: CGSize(width: 400, height: 480))
        scroll.setFitting(false)
        scroll.magnification = 1
        XCTAssertFalse(scroll.canScroll)
        scroll.topInset = 60
        XCTAssertTrue(scroll.canScroll)
    }
}
