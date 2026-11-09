import AppKit
import QuartzCore
import SwiftUI

/// AppKit owns scrolling and trackpad magnification, including gesture inertia.
/// Core Animation composites the photograph, so zoom and pan never redraw it.
struct PreviewCanvas: NSViewRepresentable {
    /// An IOSurface or CGImage, scaled to fill the photograph's layout size.
    let image: AnyObject
    let size: CGSize
    let rotation: Int
    let crop: CropSettings
    let border: BorderSettings?
    let filmTexture: CGImage?
    let filmStrip: FilmStrip?
    let zoomCommand: UUID
    let fit: Bool
    var scale: CanvasScale?
    /// In a proof, the pixels the export writes: they alone set the photograph's size.
    var proofPixels: CGSize? = nil
    /// Steps of ⌘+ and ⌘− away from that size.
    var zoomSteps = 0
    /// The camera details shown under the photograph.
    var exif: PhotoExif? = nil
    var fileName: String? = nil
    /// ⌘-click or ⌘-drag: the area to make neutral, as two corners in
    /// fractions of the uncropped photograph from its top left.
    var onPickWhiteBalance: ((CGPoint, CGPoint) -> Void)? = nil
    /// ⌃-click or ⌃-drag: the area to read against the zones, as two corners
    /// in fractions of the uncropped photograph from its top left.
    var onPickZone: ((CGPoint, CGPoint) -> Void)? = nil
    /// A plain drag: the region the histogram counts, in fractions of the
    /// uncropped photograph from its top left; nil for a plain click.
    var onSelectRegion: ((CGRect?) -> Void)? = nil
    /// The region selected now, drawn on the photograph.
    var region: CGRect? = nil
    /// Esc on the photograph: drop the zone reading.
    var onEscapeKey: (() -> Void)? = nil
    /// Called when the user changes between fit and a zoomed view.
    var onFitChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.allowsMagnification = true; scroll.minMagnification = 0.005; scroll.maxMagnification = 16
        scroll.documentView = PhotographView()
        scroll.setAccessibilityLabel("Photograph preview")
        scroll.setAccessibilityHelp("Pinch to zoom, drag to select an area for the histogram, drag with the middle button to pan, Control-click or Control-drag to read a tone against the zones, Command-click or Command-drag to set the white balance, double-click to fit or show actual size.")
        scroll.onFitChanged = onFitChanged
        return scroll
    }

    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        scale?.view = scroll
        scroll.onFitChanged = onFitChanged
        let photo = scroll.documentView as! PhotographView
        photo.onEscapeKey = onEscapeKey
        photo.onPickWhiteBalance = onPickWhiteBalance
        photo.onPickZone = onPickZone
        photo.onSelectRegion = onSelectRegion
        if photo.region != region { photo.region = region; scroll.overlay.redraw() }
        scroll.proofPixels = proofPixels
        scroll.zoomSteps = zoomSteps
        scroll.exif = exif
        scroll.overlay.showFileName(fileName)
        let cropped = crop.size(of: size)
        let displaySize = rotation % 2 != 0 ? CGSize(width: cropped.height, height: cropped.width) : cropped
        let documentSize = border.map { border in
            let canvas = border.canvas(for: displaySize, strip: filmStrip)
            return border.instagram ? border.instagramCanvas(for: canvas) : canvas
        } ?? displaySize
        // Room to show its details above it.
        scroll.automaticallyAdjustsContentInsets = false
        let insets = NSEdgeInsets(top: CanvasOverlayView.exifMargin, left: 0, bottom: 0, right: 0)
        if insets.top != scroll.contentInsets.top || insets.left != scroll.contentInsets.left
            || insets.bottom != scroll.contentInsets.bottom {
            scroll.contentInsets = insets
            if scroll.fitting { scroll.applyZoom() }
            scroll.overlay.redraw()
        }
        let oldSize = photo.frame.size, oldPhotoSize = photo.displaySize
        let commanded = scroll.lastCommand != zoomCommand
        // A different crop (such as an undone one) is a new picture: fit it.
        let recropped = photo.crop != crop && oldSize.width != 0
        if recropped { scroll.fitting = true }
        // The same picture at another resolution, as during a slider drag: a
        // proof looks the same, and stays where it's been panned to.
        let sameProof = proofPixels != nil && !commanded && !recropped && oldSize.width > 0 && oldSize != documentSize
            && abs(oldSize.width / oldSize.height - documentSize.width / documentSize.height) < 0.01
        photo.show(image, size: size, rotation: rotation, crop: crop, border: border, filmTexture: filmTexture, filmStrip: filmStrip)
        if oldSize != documentSize {
            if sameProof {
                scroll.keepVisibleContent(resizingDocumentFrom: oldSize, to: documentSize)
            } else if commanded || scroll.fitting || oldSize.width == 0 {
                photo.setFrameSize(documentSize)
            } else if oldPhotoSize != displaySize {
                scroll.keepVisibleContent(resizingDocumentFrom: oldSize, to: documentSize)
            } else {
                // Only the border changed: keep the photograph where it is.
                scroll.keepPhotographInPlace(resizingDocumentFrom: oldSize, to: documentSize)
            }
        }
        if commanded {
            scroll.lastCommand = zoomCommand; scroll.fitting = fit || proofPixels != nil
            scroll.applyZoom()
        } else if oldSize != documentSize || recropped, scroll.fitting, !sameProof { scroll.applyZoom() }
    }
}

/// How many screen pixels a pixel of the photograph covers at the canvas's
/// zoom. A render this much smaller than the photograph looks the same on screen.
@MainActor final class CanvasScale {
    weak var view: ImageScrollView?
    var screenPixelsPerPhotoPixel: CGFloat? {
        guard let view, let window = view.window, view.magnification > 0 else { return nil }
        return view.magnification * window.backingScaleFactor
    }
    /// A point in the window, as a point of the canvas from its top left.
    func canvasPoint(window point: CGPoint) -> CGPoint? {
        guard let view else { return nil }
        let inOverlay = view.overlay.convert(point, from: nil)
        return CGPoint(x: inOverlay.x, y: view.overlay.bounds.height - inOverlay.y)
    }

    /// A point of the canvas, from its top left, as a fraction of the uncropped
    /// photograph. Nil on the border, outside the crop or off the canvas.
    func unitPoint(canvasPoint point: CGPoint) -> CGPoint? {
        guard let view, let photo = view.documentView as? PhotographView,
              point.x >= 0, point.y >= 0, point.x < view.bounds.width, point.y < view.bounds.height else { return nil }
        // Through the overlay, which is y-up: NSScrollView itself is flipped.
        let overlay = view.overlay
        return photo.unitPoint(at: photo.convert(CGPoint(x: point.x, y: overlay.bounds.height - point.y), from: overlay))
    }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        let frame = documentView.frame
        if bounds.width > frame.width {
            bounds.origin.x = -Self.leadingGap(space: bounds.width - frame.width, leading: contentInsets.left, trailing: contentInsets.right)
        }
        if bounds.height > frame.height {
            let space = bounds.height - frame.height
            let top = Self.leadingGap(space: space, leading: contentInsets.top, trailing: contentInsets.bottom)
            bounds.origin.y = isFlipped ? -top : top - space
        }
        return bounds
    }

    /// The gap before a document in `space` to spare: centred, unless what's
    /// kept clear at either end needs it off centre.
    static func leadingGap(space: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        var gap = space / 2
        if gap < leading { gap = min(leading, space) }
        if space - gap < trailing { gap = max(space - trailing, min(leading, space)) }
        return gap
    }
}

final class ImageScrollView: NSScrollView {
    var lastCommand: UUID?
    var fitting = true
    var onFitChanged: ((Bool) -> Void)?
    /// One step of ⌘+ or ⌘−.
    static let zoomStep: CGFloat = 2.0.squareRoot()
    /// In a proof, the pixels the export writes, shown one to a screen pixel.
    /// Only they and ⌘+ and ⌘− set the zoom: the window's size doesn't.
    var proofPixels: CGSize? {
        didSet {
            guard proofPixels != oldValue else { return }
            if proofPixels != nil { setFitting(true) }
            applyZoom()
        }
    }
    private var isProof: Bool { proofPixels != nil }
    /// A fitted photograph leaves room for its details above it, and is centred.
    var exif: PhotoExif? {
        didSet {
            guard exif != oldValue else { return }
            overlay.showExif(exif)
            if (exif == nil) != (oldValue == nil), fitting { applyZoom() }
        }
    }
    /// The zoom that makes the document the export's size. By the long edges, so
    /// a photograph of another orientation that's still arriving has the same scale.
    private func proofMagnification(document size: CGSize) -> CGFloat? {
        guard let proofPixels, max(size.width, size.height) > 0 else { return nil }
        let long = max(proofPixels.width, proofPixels.height)
        guard long > 0 else { return nil }
        // The photograph alone sets the scale: a border only adds to the canvas.
        let photo = (documentView as? PhotographView)?.displaySize ?? .zero
        let shown = max(photo.width, photo.height) > 0 ? photo : size
        return long / max(shown.width, shown.height) / (window?.backingScaleFactor ?? 2) * pow(Self.zoomStep, CGFloat(zoomSteps))
    }

    /// ⌘+ and ⌘− from the export's size, about the middle of what's on screen.
    /// Counted in whole steps, so stepping back lands exactly on one to one.
    var zoomSteps = 0 {
        didSet {
            guard zoomSteps != oldValue, let documentView,
                  let wanted = proofMagnification(document: documentView.frame.size) else { return }
            let visible = contentView.bounds
            setMagnification(min(max(wanted, minMagnification), maxMagnification), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
            // Constraining again centres whatever is smaller than the window.
            contentView.scroll(to: contentView.bounds.origin)
            reflectScrolledClipView(contentView)
        }
    }
    /// The camera details and the box being picked, above the document.
    let overlay = CanvasOverlayView(frame: .zero)
    private var lastViewport = CGSize.zero
    private weak var observedClip: NSClipView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The details follow every pan and zoom, which all move the clip view's bounds.
    override func tile() {
        super.tile()
        // The clip view and scrollers arrive after the overlay does.
        if subviews.last !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.frame = bounds
        guard observedClip !== contentView else { return }
        if let observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
        observedClip = contentView
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    @objc private func clipMoved() { overlay.redraw() }

    override func layout() {
        super.layout()
        if lastViewport != contentSize {
            lastViewport = contentSize
            if isProof, let documentView, let wanted = proofMagnification(document: documentView.frame.size), abs(magnification - wanted) < 0.0001 {
                // A new window size doesn't change the zoom, only what's centred.
                contentView.scroll(to: contentView.bounds.origin)
                reflectScrolledClipView(contentView)
            } else if fitting || isProof {
                applyZoom()
            } else {
                // Set by hand, the zoom stays, and a photograph smaller than the canvas stays centred.
                contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
                reflectScrolledClipView(contentView)
            }
            // The canvas moved under the camera details, whether or not
            // the view of the photograph did: nothing else tells them.
            overlay.redraw()
        }
    }
    /// Moved to a screen with another scale, a proof stays one pixel to a pixel.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if isProof { applyZoom() }
    }
    func applyZoom() {
        guard let documentView, documentView.frame.width > 0, contentSize.width > 0 else { return }
        let size = documentView.frame.size
        // 1:1 is one photograph pixel per screen pixel. Fitting shows the whole
        // photograph, but never enlarges it past 1:1.
        let oneToOne = 1 / (window?.backingScaleFactor ?? 2)
        // Room for the details; the clip view places it.
        let margin = max(overlay.detailsLine.isEmpty ? 0 : CanvasOverlayView.exifMargin * 2, contentInsets.top + contentInsets.bottom)
        let fit = min(contentSize.width / size.width, max(contentSize.height - margin, 1) / size.height)
        let amount = proofMagnification(document: size) ?? (fitting ? min(fit, oneToOne) : oneToOne)
        setMagnification(min(max(amount, minMagnification), maxMagnification), centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        // Constraining again centres whatever is smaller than the window.
        contentView.scroll(to: contentView.bounds.origin)
        reflectScrolledClipView(contentView)
    }
    /// Whether the photograph is larger than the viewport, so panning has
    /// somewhere to go.
    var canScroll: Bool {
        guard let documentView else { return false }
        let visible = contentView.bounds.size
        return documentView.frame.width > visible.width + 0.5
            || documentView.frame.height > visible.height + 0.5
    }
    /// Double-click: fit the whole photograph, or show it at 1:1 about the
    /// clicked point, which then stays under the pointer.
    func toggleZoom(about point: CGPoint) {
        guard !isProof else { return }
        if fitting {
            setFitting(false)
            let oneToOne = 1 / (window?.backingScaleFactor ?? 2)
            setMagnification(
                min(max(oneToOne, minMagnification), maxMagnification),
                centeredAt: point
            )
        } else {
            setFitting(true)
            applyZoom()
        }
    }
    /// A higher-resolution render of the same photograph replaces the shown
    /// one; keep the same region on screen at the same apparent scale.
    func keepVisibleContent(resizingDocumentFrom old: CGSize, to new: CGSize) {
        guard let documentView else { return }
        let visible = contentView.bounds
        let center = CGPoint(x: visible.midX / old.width, y: visible.midY / old.height)
        let ratio = old.width / new.width
        documentView.setFrameSize(new)
        magnification = min(max(magnification * ratio, minMagnification), maxMagnification)
        let bounds = contentView.bounds
        contentView.scroll(to: CGPoint(x: center.x * new.width - bounds.width / 2, y: center.y * new.height - bounds.height / 2))
        reflectScrolledClipView(contentView)
    }
    func keepPhotographInPlace(resizingDocumentFrom old: CGSize, to new: CGSize) {
        guard let documentView else { return }
        let origin = contentView.bounds.origin
        documentView.setFrameSize(new)
        contentView.scroll(to: CGPoint(x: origin.x + (new.width - old.width) / 2, y: origin.y + (new.height - old.height) / 2))
        reflectScrolledClipView(contentView)
    }
    /// Records a zoom the user made by hand, so changing photographs keeps
    /// the same fit or 1:1 setting.
    func setFitting(_ value: Bool) {
        guard fitting != value else { return }
        fitting = value
        onFitChanged?(value)
    }
    override func magnify(with event: NSEvent) {
        guard !isProof else { return }
        setFitting(false)
        super.magnify(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            guard !isProof else { return }
            setFitting(false)
            let center = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
            setMagnification(min(max(magnification * exp(-event.scrollingDeltaY * 0.01), minMagnification), maxMagnification), centeredAt: center)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class PhotographView: NSView {
    /// The crop: it clips the photograph and takes the quarter turns.
    private let clip = CALayer()
    /// The whole photograph, straightened inside the crop.
    private let photo = CALayer()
    private var borderLayers: BorderLayers!
    private var image: AnyObject?
    private var size = CGSize.zero
    private var rotation = 0
    private(set) var crop = CropSettings()
    private var border: BorderSettings?
    private var filmTexture: CGImage?
    private var filmStrip: FilmStrip?
    var onPickWhiteBalance: ((CGPoint, CGPoint) -> Void)?
    var onPickZone: ((CGPoint, CGPoint) -> Void)?
    var onSelectRegion: ((CGRect?) -> Void)?
    /// The selected region, which the overlay outlines.
    var region: CGRect?
    var onEscapeKey: (() -> Void)?
    /// The drag in progress.
    private enum Drag {
        /// A plain press: a click if it doesn't move, a pan if it can.
        case press(start: CGPoint, moved: Bool, canScroll: Bool)
        /// ⌘ or ⌃ held: a box from `start`, drawn on the overlay as it's dragged.
        /// A click without a drag reads the few pixels around it.
        case pick(Pick, start: CGPoint)
        /// A plain press: a box from `start` selecting what the histogram counts.
        case select(start: CGPoint)
    }
    private enum Pick { case whiteBalance, zone(large: Bool) }
    private var drag: Drag?
    private var cursorPushed = false
    /// The photograph's size on the canvas, after cropping and rotation.
    var displaySize: CGSize {
        let cropped = crop.size(of: size)
        return rotation % 2 != 0 ? CGSize(width: cropped.height, height: cropped.width) : cropped
    }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photo.magnificationFilter = .linear
        photo.isOpaque = true
        let none = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        photo.actions = none; clip.actions = none
        clip.masksToBounds = true
        clip.addSublayer(photo)
        layer?.addSublayer(clip)
        borderLayers = BorderLayers(in: layer!, around: clip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: AnyObject, size: CGSize, rotation: Int, crop: CropSettings = CropSettings(), border: BorderSettings? = nil, filmTexture: CGImage? = nil, filmStrip: FilmStrip? = nil) {
        guard image !== self.image || size != self.size || rotation != self.rotation || crop != self.crop
            || border != self.border || filmTexture !== self.filmTexture || filmStrip != self.filmStrip else { return }
        self.image = image; self.size = size; self.rotation = rotation; self.crop = crop
        self.border = border; self.filmTexture = filmTexture; self.filmStrip = filmStrip
        photo.contents = image
        needsLayout = true
    }

    /// The photograph point under `viewPoint`, as unit coordinates of the
    /// uncropped photograph with the origin at its top left. Nil outside the
    /// crop or the photograph.
    func unitPoint(at viewPoint: CGPoint) -> CGPoint? {
        guard let root = layer, size.width > 0, size.height > 0 else { return nil }
        let inClip = clip.convert(viewPoint, from: root)
        guard inClip.x >= 0, inClip.y >= 0,
              inClip.x < clip.bounds.width, inClip.y < clip.bounds.height
        else { return nil }
        // The photo layer carries the straightening, so its own space is the
        // photograph's: y runs up from the bottom left.
        let inPhoto = photo.convert(viewPoint, from: root)
        let x = inPhoto.x / size.width, y = 1 - inPhoto.y / size.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private var overlay: CanvasOverlayView? { (enclosingScrollView as? ImageScrollView)?.overlay }

    /// Takes the keyboard focus on appearing. Nothing else claims it, and with
    /// Keyboard Navigation on AppKit would otherwise ring a toolbar button.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        if !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onEscapeKey?()
            return
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        switch CanvasGesture.start(clickCount: event.clickCount,
                                   command: flags.contains(.command) && onPickWhiteBalance != nil,
                                   control: flags.contains(.control) && onPickZone != nil,
                                   option: flags.contains(.option)) {
        case .pickWhiteBalance:
            drag = .pick(.whiteBalance, start: point)
            pushCursor(.crosshair)
        case .pickZone(let large):
            drag = .pick(.zone(large: large), start: point)
            pushCursor(.crosshair)
        case .zoomToggle:
            (enclosingScrollView as? ImageScrollView)?.toggleZoom(about: point)
        case .select:
            drag = .select(start: point)
            pushCursor(.crosshair)
        case .pan:
            startPan(at: point)
        }
    }

    private func startPan(at point: CGPoint) {
        let canScroll = (enclosingScrollView as? ImageScrollView)?.canScroll ?? false
        drag = .press(start: point, moved: false, canScroll: canScroll)
        if canScroll { pushCursor(.closedHand) }
    }

    /// The middle button pans, as in RPP.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        startPan(at: convert(event.locationInWindow, from: nil))
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDragged(with: event) }
        mouseDragged(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        drag = nil
        popCursor()
    }

    /// The box between two view points, as a region of the uncropped photograph.
    private func region(from a: CGPoint, to b: CGPoint) -> CGRect? {
        guard let p = unitPoint(clampedFrom: a), let q = unitPoint(clampedFrom: b) else { return nil }
        let r = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
        return r.width > 0 && r.height > 0 ? r : nil
    }

    /// Where a point of the uncropped photograph, in fractions from its top
    /// left, sits in this view.
    func viewPoint(unit: CGPoint) -> CGPoint? {
        guard let root = layer, size.width > 0 else { return nil }
        let inClip = clip.convert(CGPoint(x: unit.x * size.width, y: (1 - unit.y) * size.height), from: photo)
        return root.convert(inClip, from: clip)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .select(let start):
            guard hypot(point.x - start.x, point.y - start.y) > 3, let selected = region(from: start, to: point) else { return }
            onSelectRegion?(selected)
        case .pick(_, let start):
            guard hypot(point.x - start.x, point.y - start.y) > 3, let overlay else { return }
            let (a, b) = (overlay.convert(start, from: self), overlay.convert(point, from: self))
            overlay.showMarquee(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
        case .press(let start, let moved, let canScroll):
            // A small wobble while clicking is still a click.
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            drag = .press(start: start, moved: true, canScroll: canScroll)
            guard canScroll, let scroll = enclosingScrollView else { return }
            var origin = scroll.contentView.bounds.origin
            origin.x -= event.deltaX / scroll.magnification
            origin.y += event.deltaY / scroll.magnification
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .select(let start):
            let end = convert(event.locationInWindow, from: nil)
            // A click without a drag goes back to the whole photograph.
            onSelectRegion?(hypot(end.x - start.x, end.y - start.y) > 3 ? region(from: start, to: end) : nil)
        case .pick(let pick, let start):
            overlay?.showMarquee(nil)
            let end = convert(event.locationInWindow, from: nil)
            let dragged = hypot(end.x - start.x, end.y - start.y) > 3
            // A corner off the photograph stops at its edge; a click is its one point.
            guard var a = unitPoint(clampedFrom: start), var b = unitPoint(clampedFrom: dragged ? end : start) else { break }
            switch pick {
            case .whiteBalance:
                onPickWhiteBalance?(a, b)
            case .zone(let large):
                // A click reads 3 × 3 of the preview's pixels, or 7 × 7 with ⌥.
                if !dragged, size.width > 0, size.height > 0 {
                    let half = large ? 3.5 : 1.5
                    let (dx, dy) = (half / size.width, half / size.height)
                    a = CGPoint(x: max(a.x - dx, 0), y: max(a.y - dy, 0))
                    b = CGPoint(x: min(b.x + dx, 1), y: min(b.y + dy, 1))
                }
                onPickZone?(a, b)
            }
        default:
            break
        }
        drag = nil
        popCursor()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The crop's pixels, as the exporter cuts them. Layers are y-up, so
        // the rectangle's top-left origin flips, and clockwise is negative.
        let pixels = crop.pixels(in: size)
        clip.bounds = CGRect(origin: .zero, size: pixels.size)
        clip.position = CGPoint(x: bounds.midX, y: bounds.midY)
        clip.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(rotation)))
        photo.bounds = CGRect(origin: .zero, size: size)
        photo.position = CGPoint(x: size.width / 2 - pixels.minX, y: pixels.height - (size.height / 2 - pixels.minY))
        photo.setAffineTransform(CGAffineTransform(rotationAngle: -crop.angle * .pi / 180))
        borderLayers.layout(border, photo: displaySize, host: layer!, texture: filmTexture, filmStrip: filmStrip)
        CATransaction.commit()
        overlay?.redraw()
    }

    /// The layers the canvas builds, so tests can drive its coordinate map.
    var photographLayer: CALayer { photo }
    var clipLayer: CALayer { clip }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Holding ⌘ or ⌃ over the photograph shows the picker's crosshair.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard drag == nil, onPickWhiteBalance != nil || onPickZone != nil, let window else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let picking = event.modifierFlags.contains(.command) && onPickWhiteBalance != nil
            || event.modifierFlags.contains(.control) && onPickZone != nil
        (picking && inside ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    /// The unit point at `viewPoint`, or if it's off the photograph, the nearest
    /// point on it, found by stepping back towards the photograph's middle.
    func unitPoint(clampedFrom viewPoint: CGPoint) -> CGPoint? {
        if let unit = unitPoint(at: viewPoint) { return unit }
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        guard unitPoint(at: middle) != nil else { return nil }
        var (inside, outside) = (middle, viewPoint)
        for _ in 0..<24 {
            let mid = CGPoint(x: (inside.x + outside.x) / 2, y: (inside.y + outside.y) / 2)
            if unitPoint(at: mid) != nil { inside = mid } else { outside = mid }
        }
        return unitPoint(at: inside)
    }

    private func pushCursor(_ cursor: NSCursor) {
        guard !cursorPushed else { return }
        cursorPushed = true
        cursor.push()
    }

    private func popCursor() {
        guard cursorPushed else { return }
        cursorPushed = false
        NSCursor.pop()
    }
}
