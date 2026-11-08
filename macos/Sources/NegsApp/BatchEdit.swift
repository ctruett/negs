import Foundation

/// What changed between two edits, to carry across the photographs selected in
/// the grid. Pins are measured on one photograph, and a crop and rotation are
/// framing, so those stay with the photograph they were made on.
struct BatchEdit: Equatable {
    var film: String?
    var paper: String?
    /// Parameter paths and their new values, in a stable order.
    var params: [Change] = []

    struct Change: Equatable {
        let path: String
        let value: JSONValue
    }

    var isEmpty: Bool { film == nil && paper == nil && params.isEmpty }

    /// Parameters a batch never carries: Zone Shift places one photograph's tones.
    static let photographOwn: Set<String> = Set(EditorModel.photographOwnPaths + ["io.rotate_cw"])

    init(from old: EditState, to new: EditState) {
        film = old.film == new.film ? nil : new.film
        paper = old.paper == new.paper ? nil : new.paper
        Self.collect(old.params, new.params, path: "", into: &params)
        params.sort { $0.path < $1.path }
    }

    private static func collect(_ old: JSONValue, _ new: JSONValue, path: String, into changes: inout [Change]) {
        guard old != new, !photographOwn.contains(path) else { return }
        if case .object(let oldValues) = old, case .object(let newValues) = new {
            for key in Set(oldValues.keys).union(newValues.keys) {
                collect(oldValues[key] ?? .null, newValues[key] ?? .null, path: path.isEmpty ? key : "\(path).\(key)", into: &changes)
            }
        } else {
            changes.append(Change(path: path, value: new))
        }
    }

    /// Another photograph's edit with these changes made to it.
    func applied(to state: EditState) -> EditState {
        var next = state
        if let film { next.film = film }
        if let paper { next.paper = paper }
        for change in params { next.params[change.path] = change.value }
        return next
    }
}
