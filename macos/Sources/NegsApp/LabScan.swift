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
    static let range: ClosedRange<Double> = -20...20

    static func title(_ model: String) -> String { model == "noritsu" ? "Noritsu" : "Frontier" }

    static func model(_ params: JSONValue) -> String {
        let model = params[modelPath].string
        return models.contains(model) ? model : "frontier"
    }

    /// A key as a whole number of clicks within ±20.
    static func clamped(_ value: Double) -> Double {
        min(max(value.rounded(), range.lowerBound), range.upperBound)
    }
}
