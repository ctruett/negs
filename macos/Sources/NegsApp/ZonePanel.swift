import AppKit
import SwiftUI

/// Adams' zones, black at the left. Drag one onto the photograph and that spot's
/// tone becomes that zone. It floats in its own window over the top of the
/// canvas, so a drag's position goes through the screen to reach the canvas.
struct ZonePanel: View {
    let model: EditorModel
    /// The bar's own space, which `CanvasScale` carries to the canvas's.
    static let coordinateSpace = "zoneBar"
    /// A faint translucent grey, which shows on a white mat and on dark tiles alike.
    static let edgeColour = Color(white: 0.5, opacity: 0.3)

    static func label(for zone: Zone, placed: Bool) -> String {
        "Zone \(zone.numeral), \(zone.name), \(placed ? "placed" : "not placed")"
    }

    static func tooltip(for zone: Zone) -> String {
        "Zone \(zone.numeral): \(zone.name)\n\(zone.note)\nDrag onto the photograph to make that tone this zone."
    }

    var body: some View {
        let pins = model.pins
        let selected = model.selectedPin.flatMap { pins.indices.contains($0) ? pins[$0].zone : nil }
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Capsule().fill(.secondary).frame(width: 3, height: 18).opacity(0.6)
                PanelGrip()
            }
            .frame(width: ZoneGeometry.gripWidth)
            .accessibilityHidden(true)
            ForEach(ZoneScale.zones) { zone in
                ZoneTile(zone: zone, placed: pins.contains { $0.zone == zone.index }, selected: selected == zone.index) { point in
                    guard let canvas = model.canvasScale.canvasPoint(barPoint: point) else { return }
                    model.zoneDrag = ZoneDrag(zone: zone.index, point: canvas)
                } onDrop: { point in
                    model.zoneDrag = nil
                    guard let unit = model.canvasScale.unitPoint(barPoint: point) else { return }
                    Task { await model.placeZone(zone.index, at: unit) }
                }
                .frame(width: ZoneGeometry.tileWidth)
                .allowsHitTesting(model.canPlaceZones)
                .opacity(model.canPlaceZones ? 1 : 0.5)
            }
        }
        .frame(width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
        .coordinateSpace(name: Self.coordinateSpace)
        .floatingPanelShape()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zones")
    }
}

/// One zone: its grey, its numeral, and a dot once it's placed.
private struct ZoneTile: View {
    let zone: Zone
    let placed: Bool
    let selected: Bool
    let onDrag: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Void
    @State private var hovering = false

    private var ink: Color { zone.target < 55 ? .white : .black }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(Color(nsColor: ZoneScale.grey(zone.index)))
            Text(zone.numeral)
                .font(.system(size: 14, weight: zone.index == 5 ? .heavy : .medium))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if placed {
                Circle()
                    .fill(selected ? Color.accentColor : ink)
                    .frame(width: 6, height: 6)
                    .padding(6)
            }
        }
        .frame(maxHeight: .infinity)
        .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2.5) } }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(ZonePanel.coordinateSpace))
                .onChanged { onDrag($0.location) }
                .onEnded { onDrop($0.location) }
        )
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        // Hiding the panel under the pointer sends no hover event.
        .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
        .help(ZonePanel.tooltip(for: zone))
        .accessibilityElement()
        .accessibilityLabel(ZonePanel.label(for: zone, placed: placed))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
