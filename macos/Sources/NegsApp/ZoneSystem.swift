import AppKit

/// One of the zones, as a tone of the print.
struct Zone: Identifiable, Hashable, Sendable {
    let index: Int
    let name: String
    /// What typically belongs in this zone.
    let note: String
    var id: Int { index }
    var numeral: String { ZoneScale.numerals[index] }
    /// The relative luminance at the middle of the zone: a stop per zone, with
    /// zone V at 18 % gray.
    private var luminance: Double { 0.18 * pow(2, Double(index) - 5) }
    /// The middle of the zone, in L\* 0…100: where ⇧ places a reading.
    var target: Double { ZoneScale.lstar(luminance: luminance) }
    /// Where a plain click places a reading: the start of the zone, as in the
    /// zone system's own readings. Zone 0 starts at black, which no exposure
    /// reaches, so it takes its middle.
    var start: Double { index == 0 ? target : band.lowerBound }
    /// The zone's band on the L\* axis, half a stop either side of its middle.
    /// Zone 0 runs down to black and the last zone up to white.
    var band: ClosedRange<Double> {
        let low = index == 0 ? 0 : ZoneScale.lstar(luminance: luminance / 2.0.squareRoot())
        return low...min(ZoneScale.lstar(luminance: luminance * 2.0.squareRoot()), 100)
    }
}

/// Zones 0 to VII: each a stop apart in luminance, from 18 % gray at zone V up
/// to the first stop past white, which the last band stops at.
enum ZoneScale {
    static let numerals = ["0", "I", "II", "III", "IV", "V", "VI", "VII"]
    static let zones: [Zone] = [
        ("Pure black", "No tone at all."),
        ("Near black", "A slight tonality, but no detail."),
        ("First texture", "Slight detail in the shadows."),
        ("Dark detail", "Shadows with distinct, visible texture."),
        ("Open shadow", "Slightly darker Black skin, dark foliage, landscape shadows."),
        ("Middle gray", "18% gray: darker tan white skin, lighter Black skin, light foliage, dark blue sky."),
        ("Light midtone", "Average white skin, light stone, shadow areas on snow."),
        ("Light texture", "Pale white skin, white walls in sunlight, detail in snow and bright surfaces.")
    ].enumerated().map { Zone(index: $0.offset, name: $0.element.0, note: $0.element.1) }

    /// CIE L\* of a relative luminance.
    static func lstar(luminance y: Double) -> Double {
        y > 216.0 / 24389 ? 116 * cbrt(y) - 16 : y * 24389 / 27
    }

    /// The grey a zone prints as.
    static func grey(_ zone: Int) -> NSColor { grey(lstar: zones[zone].target) }

    /// The sRGB grey of a tone, L\* 0…100.
    static func grey(lstar: Double) -> NSColor {
        let y = lstar > 8 ? pow((lstar + 16) / 116, 3) : lstar * 27.0 / 24389
        let encoded = y <= 0.003_130_8 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        let v = min(max(encoded, 0), 1)
        return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
    }
}

/// A ⌃-pick: an area of the photograph read against the zones.
struct ZoneReading: Equatable, Sendable {
    /// The area's corners, in fractions of the uncropped photograph from its top left.
    let from: CGPoint
    let to: CGPoint
    /// Where the area prints now, in L\*; nil until it's been read.
    var printed: Double?
    /// By zone, the stops of Zone Shift that print the area at the zone's
    /// start, and at its middle; empty until it's been read.
    var toStart: [Double] = []
    var toMiddle: [Double] = []

    var isRead: Bool { printed != nil && toStart.count == ZoneScale.zones.count && toMiddle.count == ZoneScale.zones.count }
    /// The zone the area prints in now.
    var zone: Int? {
        printed.flatMap { lstar in ZoneScale.zones.last { lstar >= $0.band.lowerBound }?.index }
    }
}
