import AppKit
import SwiftUI

/// Where the floating panels sit, in screen coordinates, from the main window's
/// content below the toolbar. A panel the user has moved keeps its offset from here.
enum FloatingLayout {
    static let margin: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    /// Wide enough for the six workflow tabs and their labels.
    static let sidebarWidth: CGFloat = 340
    /// The room the window keeps free at its right for the sidebar.
    static var gutter: CGFloat { sidebarWidth + margin * 2 }
    /// The room a fitted photograph leaves above itself for the zone bar.
    static var zoneBarInset: CGFloat { ZoneGeometry.barHeight + margin * 2 }

    static func sidebar(in content: CGRect, offset: CGVector) -> CGRect {
        CGRect(x: content.maxX - margin - sidebarWidth + offset.dx, y: content.minY + margin + offset.dy,
               width: sidebarWidth, height: content.height - margin * 2)
    }

    static func zoneBar(in content: CGRect, sidebarVisible: Bool, offset: CGVector) -> CGRect {
        let canvasWidth = content.width - (sidebarVisible ? gutter : 0)
        return CGRect(x: content.minX + (canvasWidth - ZoneGeometry.barWidth) / 2 + offset.dx,
                      y: content.maxY - margin - ZoneGeometry.barHeight + offset.dy,
                      width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
    }
}

/// A floating window with no title bar and nothing to close it with. It's a child
/// of the main window, so it travels and minimises with it. It takes the keyboard
/// only to type in a field, leaving the photograph its keys the rest of the time.
@MainActor final class FloatingPanel: NSPanel {
    /// The user finished dragging it by its grip.
    var onUserMove: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(origin: .zero, size: content.view.frame.size), styleMask: [.borderless], backing: .buffered, defer: true)
        contentViewController = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘W with a field in the panel closes the main window, never the panel.
    override func performClose(_ sender: Any?) { parent?.performClose(sender) }

    override func sendEvent(_ event: NSEvent) {
        commitFieldEditing(in: self, before: event)
        super.sendEvent(event)
    }

    /// Clicking the photograph ends typing here, as clicking elsewhere in one window does.
    override func resignKey() {
        super.resignKey()
        makeFirstResponder(nil)
    }

    func drag(with event: NSEvent) {
        performDrag(with: event)
        onUserMove?()
    }
}

/// The part of a panel that moves it, since there's no title bar to hold.
struct PanelGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class GripView: NSView {
        override func mouseDown(with event: NSEvent) { (window as? FloatingPanel)?.drag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

extension View {
    /// A floating panel's rounded shape, with an edge that shows on any background.
    func floatingPanelShape() -> some View {
        clipShape(RoundedRectangle(cornerRadius: FloatingLayout.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: FloatingLayout.cornerRadius)
                    .strokeBorder(ZonePanel.edgeColour, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// Ends field editing even when the clicked view doesn't take keyboard focus.
@MainActor func commitFieldEditing(in window: NSWindow, before event: NSEvent) {
    guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
          let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
          let field = editor.delegate as? NSTextField,
          !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else { return }
    // Commit before dispatch so the clicked control sees the typed value.
    window.makeFirstResponder(nil)
}
