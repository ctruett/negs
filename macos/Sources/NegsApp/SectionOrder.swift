import SwiftUI
import UniformTypeIdentifiers

/// The order of a tab's sections, which a section's title can be dragged to
/// change. Each tab keeps its own, across launches; a section the saved order
/// doesn't know (a new one, or one that only shows sometimes) keeps the place
/// it was built in.
enum SectionOrder {
    static func key(_ tab: InspectorTab) -> String { "sectionOrder." + tab.rawValue }

    /// `shipped`, the sections as the tab builds them, in the `saved` order:
    /// the places the saved sections hold are refilled in that order, and
    /// every other section keeps its place.
    static func arranged(_ shipped: [String], saved: [String]) -> [String] {
        let present = Set(shipped)
        var queue = saved.filter(present.contains)
        let listed = Set(queue)
        return shipped.map { key in
            guard listed.contains(key) else { return key }
            return queue.removeFirst()
        }
    }

    /// `order` with `key` moved to just before `target`.
    static func moving(_ key: String, before target: String, in order: [String]) -> [String] {
        guard key != target, order.contains(key), let _ = order.firstIndex(of: target) else { return order }
        var out = order.filter { $0 != key }
        out.insert(key, at: out.firstIndex(of: target)!)
        return out
    }

    /// `order` with `key` moved to just after `target`.
    static func moving(_ key: String, after target: String, in order: [String]) -> [String] {
        guard key != target, order.contains(key), order.contains(target) else { return order }
        var out = order.filter { $0 != key }
        out.insert(key, at: out.firstIndex(of: target)! + 1)
        return out
    }

    static func decode(_ stored: String) -> [String] { stored.split(separator: "\n").map(String.init) }
}

/// The tab whose order the sections inside belong to, with how to change it;
/// nil where sections can't be moved (Simple, the grid's panel).
struct SectionOrdering {
    let tab: InspectorTab
    let move: (_ key: String, _ target: String, _ after: Bool) -> Void
    let reset: () -> Void
    let isCustom: Bool
}

extension EnvironmentValues {
    @Entry var sectionOrdering: SectionOrdering? = nil
}

/// A section's key on the layout, for [`OrderedStack`].
private struct SectionKey: LayoutValueKey {
    static let defaultValue: String? = nil
}

/// The sections' keys in the order the tab builds them.
private struct SectionKeys: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

/// A vertical stack, like a `VStack` with no spacing, that puts its keyed
/// subviews in `order`; unkeyed ones keep their places.
private struct OrderedStack: Layout {
    let order: [String]

    private func arranged(_ subviews: Subviews) -> [LayoutSubview] {
        let keys = subviews.map { $0[SectionKey.self] }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var keyed = subviews.indices.filter { keys[$0] != nil }
        let slots = keyed
        keyed.sort { (rank[keys[$0]!] ?? .max, $0) < (rank[keys[$1]!] ?? .max, $1) }
        var result = Array(subviews)
        for (slot, index) in zip(slots, keyed) { result[slot] = subviews[index] }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
        var height: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            height += size.height
            widest = max(widest, size.width)
        }
        return CGSize(width: width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for view in arranged(subviews) {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
        }
    }
}

/// A tab's sections, in the order they've been dragged into.
struct OrderedSections<Content: View>: View {
    let tab: InspectorTab
    @ViewBuilder let content: Content
    @AppStorage private var stored: String
    @State private var shipped: [String] = []

    init(tab: InspectorTab, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
        _stored = AppStorage(wrappedValue: "", SectionOrder.key(tab))
    }

    var body: some View {
        let order = SectionOrder.arranged(shipped, saved: SectionOrder.decode(stored))
        OrderedStack(order: order) { content }
            .onPreferenceChange(SectionKeys.self) { shipped = $0 }
            .environment(\.sectionOrdering, SectionOrdering(
                tab: tab,
                move: { key, target, after in
                    let moved = after ? SectionOrder.moving(key, after: target, in: order)
                                      : SectionOrder.moving(key, before: target, in: order)
                    stored = moved.joined(separator: "\n")
                },
                reset: { stored = "" },
                isCustom: !stored.isEmpty))
    }
}

/// Makes a section movable within its tab: it takes its place from the
/// tab's order, its title can be dragged, and a title dropped on it lands
/// before it, or after it on its lower half.
struct MovableSection: ViewModifier {
    let key: String?
    @Environment(\.sectionOrdering) private var ordering
    @State private var height: CGFloat = 0
    @State private var targeted = false

    func body(content: Content) -> some View {
        if let key, let ordering {
            content
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { height = geometry.size.height }
                        .onChange(of: geometry.size.height) { height = geometry.size.height }
                })
                .overlay(alignment: .top) { if targeted { Ink.amber.frame(height: 2) } }
                .dropDestination(for: String.self) { keys, location in
                    guard let dragged = keys.first, dragged != key else { return false }
                    ordering.move(dragged, key, location.y > height / 2)
                    return true
                } isTargeted: { targeted = $0 }
                .preference(key: SectionKeys.self, value: [key])
                .layoutValue(key: SectionKey.self, value: key)
        } else {
            content
        }
    }
}

/// The title a section is dragged by.
struct SectionHandle: ViewModifier {
    let key: String?
    @Environment(\.sectionOrdering) private var ordering

    func body(content: Content) -> some View {
        if let key, ordering != nil {
            content.draggable(key) {
                Text(key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key)
                    .font(.system(size: 12, weight: .semibold)).padding(6)
            }
        } else {
            content
        }
    }
}

extension View {
    func movableSection(_ key: String?) -> some View { modifier(MovableSection(key: key)) }
    func sectionHandle(_ key: String?) -> some View { modifier(SectionHandle(key: key)) }
}
