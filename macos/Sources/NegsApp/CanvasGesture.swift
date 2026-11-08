import AppKit

/// What a mouse-down on the photograph starts. Pure, so the map from clicks
/// to gestures is testable without events.
struct CanvasGesture {
    enum Start: Equatable {
        /// Toggle between fit and 1:1, about the click.
        case zoomToggle
        /// Scroll when there's somewhere to go; without a move it's a click
        /// on empty photograph.
        case pan
        /// ⌘: a click picks a neutral for the white balance, a drag an area to average.
        case pickWhiteBalance
        /// ⌃: a click reads a tone against the zones, a drag an area. With ⌥ a
        /// click reads a larger patch.
        case pickZone(large: Bool)
    }

    static func start(clickCount: Int, command: Bool = false, control: Bool = false, option: Bool = false) -> Start {
        if command { return .pickWhiteBalance }
        if control { return .pickZone(large: option) }
        if clickCount == 2 { return .zoomToggle }
        return .pan
    }
}
