import AppKit
import QuartzCore

/// The camera details and the box being picked, over the canvas. It sits
/// above the document, so the photograph's zoom, rotation and crop never
/// touch it, and it takes no mouse events.
final class CanvasOverlayView: NSView {
    /// The camera, exposure and file name, on one line above the photograph.
    private let detailsLayer = CATextLayer()
    /// The line's height, and its gap from the photograph.
    static let exifHeight: CGFloat = 18, exifGap: CGFloat = 4
    /// How much room a fitted photograph leaves above and below for it.
    static var exifMargin: CGFloat { exifHeight + exifGap * 2 }
    private var exif: PhotoExif?
    private var fileName: String?
    var detailsLine: String { PhotoExif.detailsLine(exif, fileName: fileName) }
    /// The box being dragged for the white balance or a zone reading.
    private let marquee = CAShapeLayer()
    /// The region the histogram counts, kept on the photograph: amber on a
    /// dark casing, so it reads on light and dark tones alike.
    private let selection = CAShapeLayer()
    private let selectionCasing = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        let none = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        marquee.actions = none
        marquee.fillColor = EdgePrint.colour.withAlphaComponent(0.08).cgColor
        marquee.strokeColor = EdgePrint.colour.cgColor
        marquee.lineWidth = 2
        marquee.lineDashPattern = [5, 3]
        marquee.shadowColor = NSColor.black.cgColor
        marquee.shadowOpacity = 0.8
        marquee.shadowRadius = 1.5
        marquee.shadowOffset = .zero
        layer?.addSublayer(marquee)
        for shape in [selectionCasing, selection] {
            shape.actions = none
            shape.fillColor = nil
            shape.lineJoin = .miter
            layer?.addSublayer(shape)
        }
        selectionCasing.strokeColor = NSColor.black.withAlphaComponent(0.7).cgColor
        selectionCasing.lineWidth = 4
        selection.strokeColor = EdgePrint.colour.cgColor
        selection.lineWidth = 2
        detailsLayer.actions = none.merging(["string": NSNull(), "contents": NSNull(), "hidden": NSNull()]) { $1 }
        detailsLayer.foregroundColor = EdgePrint.colour.cgColor
        detailsLayer.truncationMode = .middle
        detailsLayer.isHidden = true
        layer?.insertSublayer(detailsLayer, at: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func showExif(_ exif: PhotoExif?) {
        guard exif != self.exif else { return }
        self.exif = exif
        redraw()
    }

    /// Draws the picking box, in this view's coordinates; nil takes it away.
    func showMarquee(_ rect: CGRect?) {
        marquee.path = rect.map { CGPath(rect: $0, transform: nil) }
    }
    var marqueeShown: Bool { marquee.path != nil }

    func showFileName(_ name: String?) {
        guard name != fileName else { return }
        fileName = name
        redraw()
    }

    /// The line's frame, for tests; nil while it isn't showing.
    var detailsFrame: CGRect? { detailsLayer.isHidden ? nil : detailsLayer.frame }

    /// Just above the photograph. Zoomed so far there's no room above it, the
    /// line goes rather than cover the photograph.
    private func layoutDetails(photo: PhotographView) {
        let rect = convert(photo.bounds, from: photo)
        let (height, gap) = (Self.exifHeight, Self.exifGap)
        let text = detailsLine
        let y = rect.maxY + gap
        detailsLayer.isHidden = text.isEmpty || y + height > bounds.height
        let left = max(rect.minX, gap * 2)
        detailsLayer.string = text
        detailsLayer.font = EdgePrint.font(size: 14)
        detailsLayer.fontSize = 14
        detailsLayer.contentsScale = window?.backingScaleFactor ?? 2
        detailsLayer.frame = CGRect(x: left, y: y, width: max(min(rect.maxX, bounds.width - gap * 2) - left, 1), height: height)
    }

    /// Draws again from the photograph's current zoom, scroll and crop.
    func redraw() {
        guard let scroll = enclosingScrollView ?? superview as? NSScrollView,
              let photo = scroll.documentView as? PhotographView else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutDetails(photo: photo)
        selection.path = photo.region.flatMap { region -> CGPath? in
            let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                           CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)]
            let points = corners.compactMap(photo.viewPoint(unit:)).map { convert($0, from: photo) }
            guard points.count == 4 else { return nil }
            let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
            return path
        }
        selectionCasing.path = selection.path
        CATransaction.commit()
    }

}

