import Foundation

/// What the render ends on (`io.output_route`): the developed film read by a
/// lab scanner, or the film printed on paper. They don't overlap: a lab scan
/// never uses paper, and a paper print has no scanner.
enum OutputRoute: String, CaseIterable {
    case labScan = "lab_scan"
    case paperPrint = "paper_print"

    static let path = "io.output_route"
    /// What edits from before `io.output_route` say instead.
    static let legacyPath = "io.scan_film"

    static func of(_ params: JSONValue) -> OutputRoute {
        OutputRoute(rawValue: params[path].string) ?? .paperPrint
    }

    var title: String { self == .labScan ? "Lab scan" : "Paper print" }
}

/// The lab scanner and its operator's keys (`scanner.*`).
enum ScannerKeys {
    static let modelPath = "scanner.model"
    static let models = ["frontier", "noritsu"]
    /// Density, then cyan, magenta and yellow, as the labs list them.
    static let keys: [(path: String, title: String)] = [
        ("scanner.density_key", "Density"), ("scanner.cyan_key", "Cyan"),
        ("scanner.magenta_key", "Magenta"), ("scanner.yellow_key", "Yellow"),
    ]
    static let densityPath = "scanner.density_key"
    static let colourPaths = ["scanner.cyan_key", "scanner.magenta_key", "scanner.yellow_key"]
    /// The contrast (gradation) key: set up in the scanner's software, not on its keypad.
    static let contrastPath = "scanner.contrast_key"
    static let range: ClosedRange<Double> = -20...20
    /// Contrast's clicks are bigger, 10% of slope each, so it runs ±10.
    static let contrastRange: ClosedRange<Double> = -10...10

    static func range(of path: String) -> ClosedRange<Double> { path == contrastPath ? contrastRange : range }

    static func title(_ model: String) -> String { model == "noritsu" ? "Noritsu" : "Frontier" }

    static func model(_ params: JSONValue) -> String {
        let model = params[modelPath].string
        return models.contains(model) ? model : "frontier"
    }

    /// A key as a whole number of clicks within ±20.
    static func clamped(_ value: Double, to range: ClosedRange<Double> = range) -> Double {
        min(max(value.rounded(), range.lowerBound), range.upperBound)
    }
}
