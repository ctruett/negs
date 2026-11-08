import AppKit
import SwiftUI

/// The curve the pins make, to draw while it's being edited. The same rule as
/// the engine's `AnchorCurve`, which is what the photograph develops with:
/// `testTheCurveMatchesTheEngine` holds the two to the same numbers.
struct ToneCurve: Equatable {
    private let black: Double, white: Double
    private let points: [(input: Double, target: Double)]
    private let tangents: [Double]

    static func == (a: ToneCurve, b: ToneCurve) -> Bool {
        a.black == b.black && a.white == b.white && a.points.elementsEqual(b.points) { $0 == $1 }
    }

    /// `soft` says which anchors are pins measured on the photograph; see
    /// `relaxed`. Without it, every anchor lands exactly.
    init(anchors: [(input: Double, target: Double)], soft softAnchors: [Bool] = []) {
        // Pins on one target are one reading of that tone.
        var zones: [Int: (sum: Double, count: Int, soft: Bool)] = [:]
        for (index, anchor) in anchors.enumerated() where anchor.input.isFinite && anchor.target.isFinite && (0..<100).contains(anchor.input) {
            let key = Int((min(max(anchor.target, 0), 100) * 2).rounded())
            zones[key, default: (0, 0, false)].sum += anchor.input
            zones[key, default: (0, 0, false)].count += 1
            if softAnchors.indices.contains(index), softAnchors[index] { zones[key, default: (0, 0, false)].soft = true }
        }
        var (black, white) = (0.0, 100.0)
        var interior: [(input: Double, target: Double, soft: Bool)] = []
        for (key, zone) in zones {
            let (input, target) = (zone.sum / Double(zone.count), Double(key) / 2)
            if target <= 0 { black = input } else if target >= 100 { white = input } else { interior.append((input, target, zone.soft)) }
        }
        if white <= black + 0.5 { white = 100 }
        interior.sort { ($0.input, $0.target) < ($1.input, $1.target) }
        // The curve must rise, so a zone that would turn it back has no effect.
        var kept: [(input: Double, target: Double, soft: Bool)] = []
        for point in interior where point.input > black + 0.5 && point.input < white - 0.5 {
            if let last = kept.last, point.input - last.input < 0.5 || point.target - last.target < 0.5 { continue }
            kept.append(point)
        }
        self.black = black; self.white = white
        points = Self.relaxed(black: black, white: white, points: kept)
        tangents = Self.tangents(black: black, white: white, points: points)
    }

    /// How steep or flat soft pins may make the curve, as the engine's `SOFT_SLOPE`.
    static let softSlope = (flat: 0.35, steep: 1.8)

    /// The soft pins, moved as little as keeps every stretch within `softSlope`;
    /// the ends and hard points stay. Pins close together blend rather than
    /// stretching some tones and crushing others, and pins with room land exactly.
    /// The same steps as the engine's `AnchorCurve::relaxed`.
    private static func relaxed(black: Double, white: Double, points: [(input: Double, target: Double, soft: Bool)]) -> [(input: Double, target: Double)] {
        let plain = points.map { (input: $0.input, target: $0.target) }
        guard points.contains(where: \.soft) else { return plain }
        let (flat, steep) = softSlope
        let knots = [(input: black, target: 0.0, soft: false)] + points + [(input: white, target: 100.0, soft: false)]
        let count = knots.count
        var bounds = [(low: Double, high: Double)](repeating: (0, 0), count: count)
        for i in 0..<count {
            let knot = knots[i]
            guard knot.soft else { bounds[i] = (knot.target, knot.target); continue }
            let left = knots[..<i].last { !$0.soft }!, right = knots[(i + 1)...].first { !$0.soft }!
            let low = max(left.target + flat * (knot.input - left.input), right.target - steep * (right.input - knot.input))
            let high = min(left.target + steep * (knot.input - left.input), right.target - flat * (right.input - knot.input))
            // Hard points too close for the limits leave nothing to aim for: it stays.
            let stay = min(max(knot.target, left.target), right.target)
            bounds[i] = low <= high ? (low, high) : (stay, stay)
        }
        // Within what's allowed from its neighbour too, or if nothing is, its bounds.
        func place(_ y: Double, _ low: Double, _ high: Double, _ bound: (low: Double, high: Double)) -> Double {
            low <= high ? min(max(y, low), high) : min(max(y, bound.low), bound.high)
        }
        var forward = [Double](repeating: 0, count: count)
        forward[0] = knots[0].target
        for i in 1..<count {
            let d = knots[i].input - knots[i - 1].input
            let low = max(bounds[i].low, forward[i - 1] + flat * d)
            let high = min(bounds[i].high, forward[i - 1] + steep * d)
            forward[i] = knots[i].soft ? place(knots[i].target, low, high, bounds[i]) : knots[i].target
        }
        var backward = [Double](repeating: 0, count: count)
        backward[count - 1] = knots[count - 1].target
        for i in stride(from: count - 2, through: 0, by: -1) {
            let d = knots[i + 1].input - knots[i].input
            let low = max(bounds[i].low, backward[i + 1] - steep * d)
            let high = min(bounds[i].high, backward[i + 1] - flat * d)
            backward[i] = knots[i].soft ? place(knots[i].target, low, high, bounds[i]) : knots[i].target
        }
        // Between hard points too close for the limits, it must still rise.
        var result = zip(forward, backward).map { ($0 + $1) / 2 }
        if count > 2 {
            for i in 1..<(count - 1) where knots[i].soft {
                result[i] = min(max(result[i], result[i - 1]), max(result[i + 1], result[i - 1]))
            }
        }
        return (1..<(count - 1)).map { (input: knots[$0].input, target: result[$0]) }
    }

    private static func tangents(black: Double, white: Double, points: [(input: Double, target: Double)]) -> [Double] {
        let knots = [(input: black, target: 0.0)] + points + [(input: white, target: 100.0)]
        let widths = zip(knots, knots.dropFirst()).map { $1.input - $0.input }
        let slopes = zip(zip(knots, knots.dropFirst()), widths).map { ($0.1.target - $0.0.target) / $1 }
        func end(_ h0: Double, _ h1: Double, _ s0: Double, _ s1: Double) -> Double {
            min(max(((2 * h0 + h1) * s0 - h0 * s1) / (h0 + h1), 0), 3 * s0)
        }
        let last = slopes.count - 1
        var result = [Double](repeating: 0, count: knots.count)
        if slopes.count == 1 {
            result = [slopes[0], slopes[0]]
        } else {
            result[0] = end(widths[0], widths[1], slopes[0], slopes[1])
            result[last + 1] = end(widths[last], widths[last - 1], slopes[last], slopes[last - 1])
            for i in 1...last {
                let (h0, h1) = (widths[i - 1], widths[i])
                let (w0, w1) = (2 * h1 + h0, h1 + 2 * h0)
                result[i] = (w0 + w1) / (w0 / slopes[i - 1] + w1 / slopes[i])
            }
            // The ends of the axis don't flatten, which would crush the deepest
            // shadows and the brightest highlights together.
            result[0] = max(result[0], slopes[0] / 2)
            result[last + 1] = max(result[last + 1], slopes[last] / 2)
        }
        if black > 0 { result[0] = 0 }
        if white < 100 { result[last + 1] = 0 }
        return result
    }

    /// The printed L\* of a measured one.
    func map(_ value: Double) -> Double {
        if black <= 0, white >= 100, points.isEmpty { return value }
        if !value.isFinite || value <= black { return 0 }
        if value >= white { return 100 }
        let index = points.filter { $0.input <= value }.count
        func knot(_ i: Int) -> (input: Double, target: Double) {
            i == 0 ? (black, 0) : i > points.count ? (white, 100) : points[i - 1]
        }
        let (a, b) = (knot(index), knot(index + 1))
        let h = b.input - a.input, t = (value - a.input) / h
        let (t2, t3) = (t * t, t * t * t)
        let y = (2 * t3 - 3 * t2 + 1) * a.target + (t3 - 2 * t2 + t) * h * tangents[index]
            + (-2 * t3 + 3 * t2) * b.target + (t3 - t2) * h * tangents[index + 1]
        return min(max(y, a.target), b.target)
    }
}
