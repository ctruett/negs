import Foundation
import IOSurface
import SwiftUI

/// The developed photograph's tones: 256 bins per channel of the cropped
/// photograph. The border is drawn on the canvas, never in the preview, so
/// it never counts.
struct Histogram: Equatable, Sendable {
    var red = [UInt32](repeating: 0, count: 256)
    var green = [UInt32](repeating: 0, count: 256)
    var blue = [UInt32](repeating: 0, count: 256)
    /// The pixels' luminance, by L\* 0…100 across the bins.
    var luminance = [UInt32](repeating: 0, count: 256)

    /// Counts the crop of a BGRA preview. A large crop is sampled on an even
    /// grid of at most `maxSamples` pixels, which keeps the shape and takes a
    /// few milliseconds at any preview size.
    static func of(_ surface: IOSurface, crop: CropSettings, maxSamples: Int = 1 << 20) -> Histogram {
        var histogram = Histogram()
        let size = CGSize(width: surface.width, height: surface.height)
        let area = crop.pixels(in: size)
        guard area.width >= 1, area.height >= 1 else { return histogram }
        let stride = max(1, Int((area.width * area.height / Double(maxSamples)).squareRoot().rounded(.up)))
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let (width, height, rowBytes) = (surface.width, surface.height, surface.bytesPerRow)
        // A straightened crop is in the turned frame: turn each sample back
        // to the photograph, as `CropGeometry.turn(_:by: -angle, about:)`.
        let (sin, cos) = (Foundation.sin(-crop.angle * .pi / 180), Foundation.cos(-crop.angle * .pi / 180))
        let (cx, cy) = (size.width / 2, size.height / 2)
        histogram.red.withUnsafeMutableBufferPointer { red in
            histogram.green.withUnsafeMutableBufferPointer { green in
                histogram.blue.withUnsafeMutableBufferPointer { blue in
                  histogram.luminance.withUnsafeMutableBufferPointer { luminance in
                    func count(_ x: Int, _ y: Int) {
                        let pixel = base + y * rowBytes + x * 4
                        blue[Int(pixel[0])] += 1; green[Int(pixel[1])] += 1; red[Int(pixel[2])] += 1
                        let weighted = 0.2126 * Tone.linear[Int(pixel[2])] + 0.7152 * Tone.linear[Int(pixel[1])] + 0.0722 * Tone.linear[Int(pixel[0])]
                        luminance[Tone.lstarBin[min(Int(weighted * Float(Tone.lstarBin.count - 1)), Tone.lstarBin.count - 1)]] += 1
                    }
                    for row in Swift.stride(from: 0, to: Int(area.height), by: stride) {
                        for column in Swift.stride(from: 0, to: Int(area.width), by: stride) {
                            let (dx, dy) = (area.minX + CGFloat(column) + 0.5 - cx, area.minY + CGFloat(row) + 0.5 - cy)
                            let (x, y) = (Int((cx + dx * cos - dy * sin).rounded(.down)), Int((cy + dx * sin + dy * cos).rounded(.down)))
                            if x >= 0, x < width, y >= 0, y < height { count(x, y) }
                        }
                    }
                  }
                }
            }
        }
        return histogram
    }

    /// The tallest bin, leaving out pure black and white so clipping doesn't
    /// flatten the rest; their spikes run off the top instead.
    var peak: UInt32 {
        let inner = [red, green, blue].map { $0[1..<255].max() ?? 0 }.max() ?? 0
        return inner > 0 ? inner : [red, green, blue].map { $0.max() ?? 0 }.max() ?? 0
    }
}

/// Lookup tables from sRGB values to L\*. The preview's own colour space may be
/// wider, which shifts a reading slightly; the histogram is a guide to tone.
private enum Tone {
    static let linear: [Float] = (0..<256).map { value in
        let c = Double(value) / 255
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }
    /// The L\* bin of a luminance, finely stepped so the shadows keep their shape.
    static let lstarBin: [Int] = (0..<4096).map { index in
        let lstar = ZoneScale.lstar(luminance: Double(index) / 4095)
        return min(max(Int((lstar / 100 * 255).rounded()), 0), 255)
    }
    /// The L\* bin of each 8-bit channel value.
    static let channelBin: [Int] = linear.map { lstarBin[min(Int($0 * 4095), 4095)] }
}

/// A histogram as the zone chart draws it: each channel and the luminance on
/// the L\* axis, smoothed, with the share of the photograph in each zone.
struct ZoneChartData: Equatable, Sendable {
    var red: [Double], green: [Double], blue: [Double], luminance: [Double]
    /// Each zone's share of the photograph, 0…1, by its index.
    var shares: [Double]
    /// The tallest bin, leaving out the deepest shadows so a spike at black
    /// doesn't flatten the rest; it runs off the top instead.
    var peak: Double

    init(_ histogram: Histogram) {
        func onAxis(_ bins: [UInt32]) -> [Double] {
            var out = [Double](repeating: 0, count: bins.count)
            for (index, count) in bins.enumerated() { out[Tone.channelBin[index]] += Double(count) }
            return Self.smoothed(out)
        }
        red = onAxis(histogram.red); green = onAxis(histogram.green); blue = onAxis(histogram.blue)
        luminance = Self.smoothed(histogram.luminance.map(Double.init))
        peak = max([red, green, blue].map { $0.dropFirst(16).max() ?? 0 }.max() ?? 0, 1)
        shares = ZoneScale.zones.map { Self.share(of: $0, in: histogram) }
    }

    /// Dark channel values land several bins apart on the L\* axis, so they need
    /// spreading before they read as a curve.
    private static func smoothed(_ bins: [Double]) -> [Double] {
        let weights = [1.0, 2, 3, 4, 5, 4, 3, 2, 1]
        return bins.indices.map { index in
            var sum = 0.0
            for (offset, weight) in weights.enumerated() {
                sum += bins[min(max(index + offset - 4, 0), bins.count - 1)] * weight
            }
            return sum / 25
        }
    }

    /// The share of the photograph's pixels in a zone, 0…1.
    static func share(of zone: Zone, in histogram: Histogram) -> Double {
        let total = histogram.luminance.reduce(0) { $0 + Double($1) }
        guard total > 0 else { return 0 }
        let last = zone.index == ZoneScale.zones.count - 1
        var sum = 0.0
        for (index, count) in histogram.luminance.enumerated() {
            let lstar = Double(index) / Double(histogram.luminance.count - 1) * 100
            if lstar >= zone.band.lowerBound, lstar < zone.band.upperBound || last { sum += Double(count) }
        }
        return sum / total
    }
}

/// The tones over the zones: each zone a band on the L\* axis that reads out on
/// hover. With a ⌃-picked reading, each band shows the stops of Zone Shift
/// that put it at the zone's start, and a click places it there, or with ⇧ at
/// the zone's middle.
struct ZoneHistogramView: View {
    let model: EditorModel
    @State private var hovered: Int?

    static let chartHeight: CGFloat = 96

    var body: some View {
        let chart = model.zoneChart
        let reading = model.zoneReading.flatMap { $0.isRead ? $0 : nil }
        let active = hovered.flatMap { ZoneScale.zones.indices.contains($0) ? ZoneScale.zones[$0] : nil }
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(ZoneScale.zones) { zone in
                            ZoneBand(zone: zone, hovered: hovered == zone.index, current: reading?.zone == zone.index,
                                     shift: reading?.toStart[zone.index], share: chart?.shares[zone.index]) {
                                model.placeReading(onZone: zone.index, centre: NSEvent.modifierFlags.contains(.shift))
                            }
                            .frame(width: geometry.size.width * (zone.band.upperBound - zone.band.lowerBound) / 100)
                            .onHover { inside in
                                if inside { hovered = zone.index } else if hovered == zone.index { hovered = nil }
                            }
                        }
                    }
                    if let chart { ZoneCurves(data: chart) }
                    if let printed = reading?.printed {
                        Ink.amber.frame(width: 1.5)
                            .offset(x: geometry.size.width * min(max(printed, 0), 100) / 100 - 0.75)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: Self.chartHeight)
            .background(Ink.well)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Exposure zones")
            HStack(spacing: 6) {
                if let active {
                    Text("Zone \(active.numeral)").fontWeight(.semibold).foregroundStyle(Ink.paper)
                    Text(active.name)
                    Spacer(minLength: 0)
                    if let reading {
                        Text(verbatim: "\(Self.stops(reading.toStart[active.index])) · ⇧ \(Self.stops(reading.toMiddle[active.index]))")
                            .monospacedDigit().foregroundStyle(Ink.amber)
                    } else if let chart {
                        Text(chart.shares[active.index], format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit().foregroundStyle(Ink.paper)
                    }
                } else if reading != nil {
                    Text("Click a zone to place the reading there")
                    Spacer(minLength: 0)
                } else {
                    Text("⌃-click the photograph to read a tone")
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(1)
            .frame(height: 24)
            .accessibilityElement(children: .combine)
        }
    }

    /// Stops as the zone system reads them: "+1.3", "−0.7", "0.0".
    static func stops(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return (rounded > 0 ? "+" : "−") + abs(rounded).formatted(.number.precision(.fractionLength(1)))
    }
}

private struct ZoneBand: View {
    let zone: Zone
    let hovered: Bool
    /// The reading prints in this zone now.
    let current: Bool
    /// The stops that place the reading at this zone's start, with a reading.
    let shift: Double?
    let share: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                Rectangle().fill(hovered ? Ink.paper.opacity(shift == nil ? 0.09 : 0.14) : .clear)
                Rectangle().fill(current ? Ink.amber : hovered ? Ink.paper.opacity(0.55) : .clear).frame(height: 2)
                Text(zone.numeral)
                    .font(Ink.print(11))
                    .foregroundStyle(current ? Ink.amber : hovered ? Ink.paper : Ink.dim)
                    .fixedSize()
                    .padding(.top, 3)
            }
            .overlay(alignment: .bottomLeading) {
                if let shift {
                    Text(verbatim: ZoneHistogramView.stops(shift))
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Ink.amber)
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .padding(.leading, 2).padding(.bottom, 3)
                }
            }
            .overlay(alignment: .trailing) { Ink.paper.opacity(0.05).frame(width: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(shift == nil ? "" : "Places the reading at the start of the zone; with Shift, its middle")
    }

    private var accessibilityText: String {
        var text = "Zone \(zone.numeral), \(zone.name)"
        if let share { text += ", \(share.formatted(.percent.precision(.fractionLength(1)))) of pixels" }
        if let shift { text += ", \(ZoneHistogramView.stops(shift)) stops to place the reading here" }
        return text
    }
}

/// The curves, over the bands, letting the pointer through to them.
struct ZoneCurves: View {
    let data: ZoneChartData
    private static let headroom: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            func point(_ bins: [Double], _ index: Int) -> CGPoint {
                // The baseline sits below the chart, so empty bins draw no line along it.
                let base = size.height + 2
                return CGPoint(x: CGFloat(index) / CGFloat(bins.count - 1) * size.width,
                               y: base - CGFloat(min(bins[index] / data.peak, 1)) * (base - Self.headroom))
            }
            context.blendMode = .screen
            for (bins, fill, stroke) in [(data.red, Color(red: 1, green: 0.27, blue: 0.23), 0.3),
                                         (data.green, Color(red: 0.2, green: 0.84, blue: 0.29), 0.3),
                                         (data.blue, Color(red: 0.04, green: 0.52, blue: 1), 0.34)] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height + 2))
                for index in bins.indices { path.addLine(to: point(bins, index)) }
                path.addLine(to: CGPoint(x: size.width, y: size.height + 2))
                path.closeSubpath()
                context.fill(path, with: .color(fill.opacity(stroke)))
                context.stroke(path, with: .color(fill.opacity(0.8)), lineWidth: 0.75)
            }
            context.blendMode = .normal
            var line = Path()
            line.move(to: point(data.luminance, 0))
            for index in data.luminance.indices.dropFirst() { line.addLine(to: point(data.luminance, index)) }
            context.stroke(line, with: .color(Ink.paper.opacity(0.9)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
