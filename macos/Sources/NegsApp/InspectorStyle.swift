import AppKit
import SwiftUI

/// The inspector's inks. Full amber means live or changed: the active tab, an
/// edited value, a switch that's on, the primary action. Everything else stays
/// in warm tints of it, so edits are what stand out on an untouched panel.
enum Ink {
    static let amber = EdgePrint.amber
    /// What's being read: stock names, module titles, chosen options.
    static let paper = Color(red: 0.957, green: 0.922, blue: 0.863)
    /// Control labels.
    static let label = Color(red: 0.737, green: 0.682, blue: 0.592)
    /// Values at their default, section heads and captions.
    static let dim = Color(red: 0.561, green: 0.510, blue: 0.431)
    static let track = Color(red: 0.216, green: 0.196, blue: 0.165)
    static let line = Color(red: 0.149, green: 0.133, blue: 0.110)
    static let well = Color(red: 0.078, green: 0.071, blue: 0.063)

    static let paperColour = NSColor(srgbRed: 0.957, green: 0.922, blue: 0.863, alpha: 1)
    static let labelColour = NSColor(srgbRed: 0.737, green: 0.682, blue: 0.592, alpha: 1)
    static let dimColour = NSColor(srgbRed: 0.561, green: 0.510, blue: 0.431, alpha: 1)
    static let trackColour = NSColor(srgbRed: 0.216, green: 0.196, blue: 0.165, alpha: 1)

    static func print(_ size: CGFloat) -> Font { Font(EdgePrint.font(size: size)) }
}

/// The inspector's measures.
enum InkLayout {
    static let gutter: CGFloat = 16
    static let rowHeight: CGFloat = 28
    static let labelWidth: CGFloat = 116
    static let valueWidth: CGFloat = 40
    static let resetWidth: CGFloat = 16
    static let cardGap: CGFloat = 6
}

/// What's folded in the all-controls column, where a double-click on a
/// heading folds that part away and another brings it back. Kept across launches.
struct AllFolds {
    static let key = "foldedInAllControls"
    let storage: Binding<String>

    private var keys: [String] { storage.wrappedValue.split(separator: "\n").map(String.init) }
    func contains(_ key: String) -> Bool { keys.contains(key) }
    func toggle(_ key: String) {
        storage.wrappedValue = (contains(key) ? keys.filter { $0 != key } : keys + [key]).joined(separator: "\n")
    }
}

/// The sidebar's parts hidden with a right-click, kept across launches. The
/// eye above the histogram, open, shows them all again.
struct HiddenParts {
    static let key = "hiddenSidebarParts"
    static let revealKey = "showHiddenSidebarParts"
    let storage: Binding<String>
    var revealed: Bool

    private var keys: [String] { storage.wrappedValue.split(separator: "\n").map(String.init) }
    var any: Bool { !keys.isEmpty }
    func isHidden(_ key: String) -> Bool { keys.contains(key) }
    func shows(_ key: String) -> Bool { revealed || !isHidden(key) }
    func toggle(_ key: String) {
        storage.wrappedValue = (isHidden(key) ? keys.filter { $0 != key } : keys + [key]).joined(separator: "\n")
    }

    /// The stages shown, in order; the first stays even if all are hidden.
    var visibleTabs: [InspectorTab] {
        let shown = InspectorTab.allCases.filter { shows($0.hideKey) }
        return shown.isEmpty ? [InspectorTab.allCases[0]] : shown
    }

    /// `groups` without their hidden stocks, or groups left empty, but always
    /// with `keeping`, the stock in use.
    func visible(_ groups: [StockGroup], keeping: String) -> [StockGroup] {
        groups.compactMap { group in
            let stocks = group.stocks.filter { $0.id == keeping || shows(Stock.hideKey($0.id)) }
            return stocks.isEmpty ? nil : StockGroup(title: group.title, stocks: stocks)
        }
    }

    /// `tab`, or the first stage shown if it's hidden.
    func visibleTab(_ tab: InspectorTab) -> InspectorTab {
        visibleTabs.contains(tab) ? tab : visibleTabs[0]
    }
}

/// A sidebar part that a right-click can hide, or with the eye open, show again.
struct Hideable: ViewModifier {
    /// Nil leaves the part as it is: an untitled section has nothing to name it by.
    let key: String?
    @AppStorage(HiddenParts.key) private var storage = ""
    @AppStorage(HiddenParts.revealKey) private var revealed = false
    @Environment(\.sectionOrdering) private var ordering

    func body(content: Content) -> some View {
        let parts = HiddenParts(storage: $storage, revealed: revealed)
        if let key {
            if parts.shows(key) {
                content.contextMenu {
                    Button(parts.isHidden(key) ? "Show Section" : "Hide Section") { parts.toggle(key) }
                    if let ordering, ordering.isCustom, !key.hasPrefix("stage:") {
                        Button("Reset Section Order", action: ordering.reset)
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// See [`Hideable`]: `key` names the part, as "section:Tone".
    func hideable(_ key: String?) -> some View { modifier(Hideable(key: key)) }
}

/// The eye above the histogram: open shows every part, hidden ones included.
struct HiddenPartsEye: View {
    @AppStorage(HiddenParts.key) private var storage = ""
    @AppStorage(HiddenParts.revealKey) private var revealed = false

    var body: some View {
        let any = HiddenParts(storage: $storage, revealed: revealed).any
        Button { revealed.toggle() } label: {
            Image(systemName: revealed ? "eye" : "eye.slash")
                .font(.system(size: 12))
                .foregroundStyle(any ? (revealed ? Ink.amber : Ink.label) : Ink.dim.opacity(0.5))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(revealed ? "Hide the sections you've hidden" : "Show the sections you've hidden. Right-click a section to hide it.")
        .accessibilityLabel(revealed ? "Hide hidden sections" : "Show hidden sections")
    }
}

/// The mark on a heading folded in the all-controls column.
struct FoldChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Ink.dim)
            .frame(width: 10)
    }
}

/// A titled run of rows, with a line under it. `action` sits opposite the title.
struct InkSection<Content: View, Action: View>: View {
    let title: String?
    var footer: String?
    let action: Action
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder action: () -> Action = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.action = action()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(Ink.print(13)).tracking(0.9).foregroundStyle(Ink.dim)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    action
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .sectionHandle("section:" + title)
            }
            content
            if let footer { InkNote(footer) }
        }
        .padding(.horizontal, InkLayout.gutter)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
        .hideable(title.map { "section:" + $0 })
        .movableSection(title.map { "section:" + $0 })
    }
}

/// A caption under a row.
struct InkNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Ink.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}

/// A small, quiet button, like Balance Print and Reset.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(configuration.isPressed ? Ink.paper : Ink.label)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.track))
            .contentShape(Rectangle())
    }
}

/// A label with the amber switch opposite it.
struct InkSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            InkSwitch(isOn: configuration.$isOn)
        }
        .frame(minHeight: InkLayout.rowHeight)
    }
}

/// The switch itself: amber when on, the track colour when off.
struct InkSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Ink.amber : Ink.track)
                Circle().fill(isOn ? Color.black : Ink.label).padding(2)
            }
            .frame(width: 26, height: 14)
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A label with its content opposite, on a row's height.
struct InkRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content.foregroundStyle(Ink.paper)
        }
        .frame(minHeight: InkLayout.rowHeight)
    }
}

/// A pop-up on a row: its title, and the chosen option in paper opposite.
struct ChoiceRow<Selection: Hashable, Options: View>: View {
    let title: String
    let selection: Binding<Selection>
    let options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        self.selection = selection
        self.options = options()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Picker(title, selection: selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .foregroundStyle(Ink.paper)
                .tint(Ink.paper)
                .fixedSize()
        }
        .frame(minHeight: InkLayout.rowHeight)
    }
}

/// A row of a few exclusive choices side by side: its title, then the segments.
struct SegmentedRow<Selection: Hashable>: View {
    let title: String
    let selection: Binding<Selection>
    let options: [(value: Selection, title: String)]

    var body: some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Picker(title, selection: selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .frame(minHeight: InkLayout.rowHeight)
    }
}

/// A lab operator's key: its name, − and + buttons a click apiece, and the
/// clicks between them. ⌥-click either button to go back to 0.
struct KeyStepperRow: View {
    let title: String
    let value: Double
    let step: (Double) -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            button("−", -1)
            Text(value == 0 ? "0" : String(format: "%+.0f", value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(value == 0 ? Ink.dim : Ink.paper)
                .frame(minWidth: 28)
            button("+", 1)
        }
        .frame(minHeight: InkLayout.rowHeight)
    }

    private func button(_ label: String, _ clicks: Double) -> some View {
        Button(label) {
            if NSEvent.modifierFlags.contains(.option) { reset() } else { step(clicks) }
        }
        .buttonStyle(Keycap())
        .frame(width: 34)
        .help("\(clicks > 0 ? "More" : "Less") \(title.lowercased()), a click. ⌥-click to reset.")
        .accessibilityLabel("\(clicks > 0 ? "More" : "Less") \(title)")
    }
}

/// A card for the film or the paper: the stock's name, and which it is.
struct StockCard: View {
    let name: String
    let kind: String
    var open = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Font(EdgePrint.mediumFont(size: 22))).foregroundStyle(Ink.paper)
                    .lineLimit(1).truncationMode(.tail)
                Text(kind).font(.system(size: 11)).foregroundStyle(Ink.dim)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(open ? Ink.amber : Ink.dim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.well, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open ? Ink.amber : hovering ? Ink.dim : Ink.track))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The stock card that opens a menu of the stocks, for when previews are off.
/// The menu is AppKit's, so the inspector's control styles can't reach its rows.
struct StockMenuCard: View {
    let name: String
    let kind: String
    let label: String
    let groups: [StockGroup]
    let selected: String
    let choose: (String) -> Void
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.show(StockMenu.make(groups: groups, selected: selected, choose: choose))
        } label: {
            StockCard(name: name, kind: kind)
        }
        .buttonStyle(.plain)
        .background(MenuAnchor.Representable(anchor: anchor))
        .accessibilityLabel(label)
        .accessibilityValue(name)
    }
}

/// Builds the menu of stocks: a heading for each group and a check on the chosen one.
enum StockMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func chooseStock() { run() }
    }

    static func make(groups: [StockGroup], selected: String, choose: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: group.title))
            for stock in group.stocks {
                let action = Action { choose(stock.id) }
                let item = NSMenuItem(title: stock.name, action: #selector(Action.chooseStock), keyEquivalent: "")
                item.target = action
                // A menu item only holds its target weakly.
                item.representedObject = action
                item.state = stock.id == selected ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// Where a menu opens: just under the view it's attached to.
final class MenuAnchor {
    fileprivate weak var view: NSView?

    func show(_ menu: NSMenu) {
        guard let view else { return }
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }

    struct Representable: NSViewRepresentable {
        let anchor: MenuAnchor
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}
