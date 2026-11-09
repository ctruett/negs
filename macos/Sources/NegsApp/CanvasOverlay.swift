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
    private let marqueeCasing = CAShapeLayer()
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
        // Every box on the photograph is drawn alike: a dashed amber line on a
        // dark casing, which reads on light and dark tones.
        for (casing, line) in [(marqueeCasing, marquee), (selectionCasing, selection)] {
            for shape in [casing, line] {
                shape.actions = none
                shape.fillColor = nil
                shape.lineJoin = .miter
                layer?.addSublayer(shape)
            }
            casing.strokeColor = NSColor.black.withAlphaComponent(0.7).cgColor
            casing.lineWidth = 4
            line.strokeColor = EdgePrint.colour.cgColor
            line.lineWidth = 2
            line.lineDashPattern = [6, 4]
        }
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
        marqueeCasing.path = marquee.path
    }
    var marqueeShown: Bool { marquee.path != nil }
    /// The selection's outline in this view, for tests; nil when none shows.
    var selectionBounds: CGRect? { selection.path?.boundingBoxOfPath }

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

