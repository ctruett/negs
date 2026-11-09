import SwiftUI

enum Adjustment: Identifiable {
    case slider(String, String, ClosedRange<Double>, Double)
    case toggle(String, String)
    case choice(String, String, [String])
    /// One lane (index) of an engine array that stays null until edited, so
    /// the film's grain preset from the catalog applies. B&W films have one
    /// emulsion: they show the lane under `bw`, or hide it when that is nil.
    case stockSlider(String, String, Int, ClosedRange<Double>, Double, bw: String?)
    /// One slider for several lanes, which a chip splits apart. It moves them
    /// together, keeping any differences between them. A B&W film has one
    /// emulsion, so it shows only the first lane, under `bw`.
    case linked(String, chip: String, [ChannelLane], ClosedRange<Double>, Double, bw: String?)

    var id: String {
        switch self {
        case .slider(_, let path, _, _), .toggle(_, let path), .choice(_, let path, _): return path
        case .stockSlider(_, let path, let index, _, _, _): return "\(path).\(index)"
        case .linked(let title, _, let lanes, _, _, _): return "\(lanes.first?.id ?? "").\(title)"
        }
    }
}

/// One lane of a linked slider: its own parameter, or one index of an engine
/// array that stays null until edited.
struct ChannelLane {
    let title: String
    let path: String
    var stockIndex: Int?

    var id: String { stockIndex.map { "\(path).\($0)" } ?? path }
}

/// A red, green and blue lane of one engine array.
private func stockLanes(_ path: String) -> [ChannelLane] {
    ["Red", "Green", "Blue"].enumerated().map { ChannelLane(title: $0.element, path: path, stockIndex: $0.offset) }
}
/// Red, green and blue gamma, each its own parameter.
private func gammaLanes(_ root: String) -> [ChannelLane] {
    ["Red", "Green", "Blue"].map { ChannelLane(title: $0, path: "\(root).gamma_factor_\($0.lowercased())") }
}

enum InspectorSection: String, CaseIterable {
    case camera = "Camera", film = "Film", print = "Print", scan = "Scan & Color"
}

/// How much of the inspector shows: everything on its tabs, the everyday
/// controls on one page, or every control down one column. Only the controls
/// change, never the photograph.
enum InspectorMode: String, CaseIterable {
    case simple, advanced, all

    var title: String { rawValue.capitalized }
}

/// The inspector's workflow steps, in the order the light takes them: how the
/// camera saw the photograph, the film and print that carry it, the scanner
/// that reads it, the finishing edits, and the export.
enum InspectorTab: String, CaseIterable, Identifiable {
    case camera, film, print, scan, export

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// What a right-click hides it by (see [`HiddenParts`]).
    var hideKey: String { "stage:" + title }

    /// Printing is skipped while the film is scanned directly, since there is
    /// no print to make. Such a tab stays visible, dimmed and struck through.
    func isSkipped(scanning: Bool) -> Bool { self == .print && scanning }

    /// The controls on this tab that count as edits. Export's settings are the
    /// file's, not the photograph's look, so they don't.
    var editableControls: [Adjustment] {
        let section: InspectorSection?
        switch self {
        case .camera: section = .camera
        case .film: section = .film
        case .print: section = .print
        case .scan: section = .scan
        case .export: section = nil
        }
        let groups = adjustmentGroups.filter { $0.section == section }
        let switches = groups.compactMap(\.enable).map { Adjustment.toggle($0, $0) }
        let extras: [Adjustment]
        switch self {
        case .camera: extras = cameraEditControls
        case .scan: extras = scanDetailControls + toneControls
        default: extras = []
        }
        return groups.flatMap(\.controls) + switches + extras
    }
}

/// Prep's exposure: the light on the film, which the print doesn't make up
/// for. Placing a zone reading adds to it.
let zoneShiftControl = Adjustment.slider("Zone Shift (EV)", EditorModel.zoneShiftPath,
                                         EditorModel.zoneShiftRange, 0.01)

/// Detail lives in Scan, though the engine applies it to the scene before the
/// film; the newest controls call it Midtone Detail.
let scanDetailControls: [Adjustment] = [
    .slider("Midtone Detail", "prep.midtone_detail", -100...100, 1)
]

/// Camera's own controls, outside its effect groups.
private let cameraEditControls: [Adjustment] = [
    .toggle("Auto exposure", "camera.auto_exposure"),
    .choice("Metering", "camera.auto_exposure_method", []),
    .slider("Exposure (EV)", "camera.exposure_compensation_ev", -5...5, 0.1),
    zoneShiftControl,
    .slider("Lens blur (µm)", "camera.lens_blur_um", 0...100, 0.1),
    .slider("Long edge (mm)", "camera.film_format_mm", 4...120, 0.1)
]

/// Tone lives in Scan, and on Simple's page.
let toneControls: [Adjustment] = [
    .slider("Brightness", "post.brightness", -100...100, 1),
    .slider("Contrast", "post.contrast", -100...100, 1),
    .slider("Whites", "post.whites", -100...100, 1),
    .slider("Blacks", "post.blacks", -100...100, 1),
    .slider("Saturation", "post.saturation", -100...100, 1),
    .slider("Local Contrast", "post.local_contrast", 0...100, 1)
]

struct AdjustmentGroup: Identifiable {
    let title: String
    let section: InspectorSection
    /// Switches the whole effect on and off from the group's header.
    var enable: String?
    /// How many controls show before "more controls"; all of them if nil.
    var primary: Int?
    let controls: [Adjustment]
    var id: String { title }
}

/// A density curve's controls: the main gamma and the colour lanes first.
private func curveControls(_ root: String) -> [Adjustment] {
    [
        .slider("Gamma", "\(root).gamma_factor", 0.5...2, 0.01),
        .linked("Colour gamma", chip: "RGB", gammaLanes(root), 0.5...2, 0.01, bw: nil),
        .slider("Fast gamma", "\(root).gamma_factor_fast", 0.5...2, 0.01),
        .slider("Slow gamma", "\(root).gamma_factor_slow", 0.5...2, 0.01),
        .slider("Developer exhaustion", "\(root).developer_exhaustion", 0...1, 0.01)
    ]
}

let adjustmentGroups: [AdjustmentGroup] = [
    .init(title: "Lens Diffusion", section: .camera, enable: "camera.diffusion_filter.active", primary: 2, controls: [
        .choice("Filter", "camera.diffusion_filter.filter_family", ["black_pro_mist", "glimmerglass", "pro_mist", "cinebloom"]),
        .slider("Strength", "camera.diffusion_filter.strength", 0...2, 0.01),
        .slider("Spatial scale", "camera.diffusion_filter.spatial_scale", 0.1...3, 0.01),
        .slider("Halo warmth", "camera.diffusion_filter.halo_warmth", -1.5...1.5, 0.01),
        .slider("Core intensity", "camera.diffusion_filter.core_intensity", 0...2, 0.01),
        .slider("Halo intensity", "camera.diffusion_filter.halo_intensity", 0...2, 0.01),
        .slider("Bloom intensity", "camera.diffusion_filter.bloom_intensity", 0...2, 0.01),
        .slider("Halo size", "camera.diffusion_filter.halo_size", 0.1...3, 0.01),
        .slider("Bloom size", "camera.diffusion_filter.bloom_size", 0.1...3, 0.01)
    ]),
    .init(title: "Film Curves", section: .film, enable: "film_render.density_curves_morph.active", primary: 2, controls: curveControls("film_render.density_curves_morph")),
    .init(title: "Grain", section: .film, enable: "film_render.grain.active", primary: 3, controls: [
        .linked("Granularity", chip: "RGB", stockLanes("film_render.grain.rms_granularity"), 0...80, 0.1, bw: "Granularity"),
        .linked("Uniformity", chip: "RGB", stockLanes("film_render.grain.uniformity"), 0...1, 0.01, bw: "Uniformity"),
        .stockSlider("Coarse grain size", "film_render.grain.particle_scale_sublayers", 0, 0.05...2, 0.01, bw: "Coarse grain size"),
        .stockSlider("Medium grain size", "film_render.grain.particle_scale_sublayers", 1, 0.05...2, 0.01, bw: "Medium grain size"),
        .stockSlider("Fine grain size", "film_render.grain.particle_scale_sublayers", 2, 0.05...2, 0.01, bw: "Fine grain size"),
        .slider("Dye clouds (µm)", "film_render.grain.blur_dye_clouds_um", 0...5, 0.01),
        .slider("Blur (px)", "film_render.grain.blur", 0...3, 0.01),
        .slider("Sharpen amount", "film_render.grain.mult_usm_amount", 0...3, 0.01),
        .slider("Sharpen radius (px)", "film_render.grain.mult_usm_sigma", 0...3, 0.01),
        .slider("Clump blur (µm)", "film_render.grain.micro_structure.0", 0...1, 0.01),
        .slider("Clump size (nm)", "film_render.grain.micro_structure.1", 0...100, 1)
    ]),
    .init(title: "Halation", section: .film, enable: "film_render.halation.active", primary: 2, controls: [
        .slider("Amount", "film_render.halation.halation_amount", 0...3, 0.01),
        .slider("Spatial scale", "film_render.halation.halation_spatial_scale", 0.1...5, 0.01),
        .slider("Scatter amount", "film_render.halation.scatter_amount", 0...3, 0.01),
        .slider("Scatter scale", "film_render.halation.scatter_spatial_scale", 0.1...5, 0.01),
        .slider("Bounces", "film_render.halation.halation_n_bounces", 1...5, 1),
        .slider("Bounce decay", "film_render.halation.halation_bounce_decay", 0...1, 0.01)
    ]),
    .init(title: "DIR Couplers", section: .film, enable: "film_render.dir_couplers.active", primary: 2, controls: [
        .slider("Amount", "film_render.dir_couplers.amount", 0...2, 0.01),
        .slider("Diffusion (µm)", "film_render.dir_couplers.diffusion_size_um", 0...100, 0.1),
        .slider("Tail (µm)", "film_render.dir_couplers.diffusion_tail_um", 0...400, 1),
        .slider("Tail weight", "film_render.dir_couplers.diffusion_tail_weight", 0...1, 0.01)
    ]),
    .init(title: "Film Base", section: .film, enable: "film_render.base.active", primary: 2, controls: [
        .slider("Density", "film_render.base.scale", 0...2, 0.01),
        .slider("Tilt", "film_render.base.tilt", -1...1, 0.01),
        .slider("Cyan", "film_render.base.cyan", 0...2, 0.01),
        .slider("Magenta", "film_render.base.magenta", 0...2, 0.01),
        .slider("Yellow", "film_render.base.yellow", 0...2, 0.01)
    ]),
    .init(title: "Enlarger", section: .print, controls: [
        .slider("Print exposure", "enlarger.print_exposure", 0.1...5, 0.01),
        .toggle("Exposure compensation", "enlarger.print_exposure_compensation"),
        .slider("Magenta shift", "enlarger.m_filter_shift", -50...50, 0.1),
        .slider("Yellow shift", "enlarger.y_filter_shift", -50...50, 0.1),
        .slider("Preflash exposure", "enlarger.preflash_exposure", 0...0.5, 0.01),
        .slider("Preflash magenta", "enlarger.preflash_m_filter_shift", -50...50, 0.1),
        .slider("Preflash yellow", "enlarger.preflash_y_filter_shift", -50...50, 0.1)
    ]),
    .init(title: "Print Curves", section: .print, enable: "print_render.density_curves_morph.active", primary: 2, controls: curveControls("print_render.density_curves_morph")),
    .init(title: "Print Base", section: .print, enable: "print_render.base.active", controls: [
        .slider("Density", "print_render.base.scale", 0...2, 0.01),
        .slider("Cyan", "print_render.base.cyan", 0...2, 0.01),
        .slider("Magenta", "print_render.base.magenta", 0...2, 0.01),
        .slider("Yellow", "print_render.base.yellow", 0...2, 0.01)
    ]),
    .init(title: "Glare", section: .print, enable: "print_render.glare.active", controls: [
        .slider("Amount", "print_render.glare.percent", 0...0.2, 0.001),
        .slider("Roughness", "print_render.glare.roughness", 0...2, 0.01),
        .slider("Blur (px)", "print_render.glare.blur", 0...5, 0.01)
    ]),
    .init(title: "Scanner", section: .scan, controls: [
        .slider("Lens blur (px)", "scanner.lens_blur", 0...5, 0.01),
        .slider("Unsharp radius (px)", "scanner.unsharp_mask.0", 0...3, 0.01),
        .slider("Unsharp amount", "scanner.unsharp_mask.1", 0...2, 0.01),
        .toggle("White correction", "scanner.white_correction"),
        .slider("White level", "scanner.white_level", 0.5...1, 0.01),
        .toggle("Black correction", "scanner.black_correction"),
        .slider("Black level", "scanner.black_level", 0...0.5, 0.01)
    ]),
    .init(title: "Color Management", section: .scan, controls: [
        .choice("Output gamut", "io.output_gamut_compress.algorithm", ["off", "oklch", "oklrab", "cam16ucs", "aces_rgc"]),
        .choice("Input gamut", "io.input_gamut_compress.algorithm", ["off", "xy"]),
        .toggle("CAT16 adaptation", "settings.use_cat16"),
        .choice("Spectral upsampling", "settings.rgb_to_raw_method", ["hanatos2025", "arctic2026beta04", "mallett2019"])
    ])
]

/// Simple's sliders, found by path in Advanced's lists so the two can't disagree
/// about a range.
private func adjustments(_ paths: String...) -> [Adjustment] {
    let all = adjustmentGroups.flatMap(\.controls) + scanDetailControls
    return paths.compactMap { path in all.first { $0.id == path } }
}
let simplePrintControls = adjustments("enlarger.print_exposure")
let simpleDetailControls = adjustments("prep.midtone_detail", "scanner.unsharp_mask.0", "scanner.unsharp_mask.1")

struct AdjustmentControl: View {
    let model: EditorModel
    let adjustment: Adjustment

    var body: some View {
        switch adjustment {
        case .toggle(let title, let path):
            Toggle(title, isOn: model.toggle(path)).resettable(model, path)
        case .choice(let title, let path, let options):
            ChoiceRow(title, selection: model.choice(path)) {
                ForEach(options, id: \.self) { Text(optionTitle($0)).tag($0) }
            }.resettable(model, path)
        case .slider(let title, let path, let range, let step):
            SliderRow(model: model, title: title, path: path, range: range, step: step)
        case .stockSlider(let title, let path, let index, let range, let step, let bwTitle):
            if !model.filmIsBW || bwTitle != nil {
                LabeledSlider(title: model.filmIsBW ? bwTitle ?? title : title,
                              value: model.stockNumber(path, index, range: range, step: step), range: range, step: step,
                              defaultValue: model.stockDefault(path, index), modified: model.isStockModified(path, index),
                              reset: { model.resetStock(path, index) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() })
            }
        case .linked(let title, let chip, let lanes, let range, let step, let bw):
            LinkedSliders(model: model, title: title, chip: chip, lanes: lanes, range: range, step: step, bw: bw)
        }
    }
}

/// One slider over several lanes, and the chip that splits them apart.
struct LinkedSliders: View {
    let model: EditorModel
    let title: String
    let chip: String
    let lanes: [ChannelLane]
    let range: ClosedRange<Double>
    let step: Double
    let bw: String?
    /// Which linked sliders are split, across launches.
    @AppStorage("splitSliders") private var split = ""
    @Environment(\.inspectorShowsEverything) private var everything

    private var isSplit: Bool { everything || split.split(separator: ",").contains(Substring(title)) }

    private func toggleSplit() {
        var titles = split.split(separator: ",").map(String.init).filter { $0 != title }
        if !isSplit { titles.append(title) }
        split = titles.joined(separator: ",")
    }

    var body: some View {
        if model.filmIsBW, lanes.first?.stockIndex != nil {
            if let bw, let lane = lanes.first { row(lane, title: bw, indented: false) }
        } else {
            let edits = lanes.map { model.laneValue($0) - model.laneDefault($0) }
            let average = lanes.map(model.laneValue).reduce(0, +) / Double(max(lanes.count, 1))
            let defaultAverage = lanes.map(model.laneDefault).reduce(0, +) / Double(max(lanes.count, 1))
            let mixed = edits.contains { abs($0 - (edits.first ?? 0)) > step / 2 }
            LabeledSlider(title: title,
                          value: Binding(get: { average }, set: { model.moveLanes(lanes, to: $0, range: range, step: step) }),
                          range: range, step: step, valueText: mixed ? "Mixed" : nil,
                          defaultValue: defaultAverage, modified: lanes.contains(where: model.isLaneModified),
                          reset: { lanes.forEach(model.resetLane) },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                          chip: everything ? nil : LabeledSlider.Chip(title: chip, on: isSplit, action: toggleSplit))
            if isSplit {
                ForEach(lanes, id: \.id) { row($0, title: $0.title, indented: true) }
            }
        }
    }

    private func row(_ lane: ChannelLane, title: String, indented: Bool) -> some View {
        LabeledSlider(title: title, value: model.laneNumber(lane, range: range, step: step), range: range, step: step,
                      defaultValue: model.laneDefault(lane), modified: model.isLaneModified(lane),
                      reset: { model.resetLane(lane) },
                      editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                      indented: indented)
    }
}

extension EnvironmentValues {
    /// The all-controls column: everything open, with nothing to fold.
    @Entry var inspectorShowsEverything = false
}

struct SliderRow: View {
    let model: EditorModel
    let title: String
    let path: String
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledSlider(title: title, value: model.number(path, range: range, step: step), range: range, step: step,
                      defaultValue: model.defaultValue(path).double, modified: model.isModified(path),
                      reset: { model.resetValue(path) },
                      editing: { $0 ? model.beginInteraction() : model.endInteraction() })
    }
}

/// The film frame as a stills format, which writes the frame's long edge in
/// mm; Custom shows the slider. A value no format has reads as Custom, so
/// presets and older edits need no setting of their own.
struct FilmFormatPicker: View {
    let model: EditorModel
    static let path = "camera.film_format_mm"
    static let range: ClosedRange<Double> = 4...120
    /// Long edges of the image area. 135 stays at the engine's 35 (not the
    /// gate's 36) so existing edits render as before; 6×4.5 and 6×6 share 56.
    static let formats: [(name: String, mm: Double)] = [
        ("110", 17), ("Half frame", 24), ("35 mm (135)", 35),
        ("6×4.5 / 6×6", 56), ("6×7", 70), ("6×9", 84), ("4×5", 120),
    ]
    static func format(mm: Double) -> String? { formats.first { abs($0.mm - mm) < 0.05 }?.name }
    private static let custom = "Custom"

    var body: some View {
        let mm = model.value(Self.path).double
        let custom = model.customFilmFormat || Self.format(mm: mm) == nil
        ChoiceRow("Film format", selection: Binding(get: { custom ? Self.custom : Self.format(mm: mm) ?? Self.custom }, set: { name in
            if let format = Self.formats.first(where: { $0.name == name }) {
                model.customFilmFormat = false
                model.set(Self.path, .number(format.mm))
            } else {
                model.customFilmFormat = true
            }
        })) {
            ForEach(Self.formats, id: \.name) { Text($0.name).tag($0.name) }
            Divider()
            Text("Custom…").tag(Self.custom)
        }
        .help("The film frame's long edge. 35 mm is 135 stills film; Custom shows the slider.")
        if custom {
            SliderRow(model: model, title: "Long edge (mm)", path: Self.path, range: Self.range, step: 0.1)
        }
    }
}

/// A slider on one row, between its title and value. Clicking the value types
/// one; off its default, a button resets it, and the value and fill turn amber.
struct LabeledSlider: View {
    /// A small button beside the title, such as RGB to split lanes apart.
    struct Chip {
        let title: String
        let on: Bool
        let action: () -> Void
    }

    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    /// Shown after the value, such as "%".
    var unit = ""
    /// Shown in place of the value, such as "Mixed".
    var valueText: String?
    let defaultValue: Double
    let modified: Bool
    let reset: () -> Void
    let editing: (Bool) -> Void
    var chip: Chip?
    var indented = false

    @State private var typing = false
    private var decimals: Int { max(0, Int(-log10(step).rounded(.down))) }
    private var format: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...decimals)) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(indented ? Ink.dim : modified ? Ink.paper : Ink.label)
                    .onTapGesture(count: 2) { reset() }
                if let chip {
                    Button(action: chip.action) {
                        Text(chip.title)
                            .font(Ink.print(10)).tracking(0.5)
                            .foregroundStyle(chip.on ? Ink.paper : Ink.dim)
                            .padding(.horizontal, 3)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(chip.on ? Ink.label : Ink.track))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(chip.on ? "Show \(title) as one slider" : "Show \(title)’s lanes separately")
                    .accessibilityLabel("Split \(title)")
                    .accessibilityAddTraits(chip.on ? .isSelected : [])
                }
            }
            .padding(.leading, indented ? 10 : 0)
            .frame(width: InkLayout.labelWidth, alignment: .leading)
            ResettableSlider(title: title, value: value, range: range, defaultValue: defaultValue, editing: editing, reset: reset)
            // A field only while typing, so the window never focuses one by default.
            if typing {
                ValueField(title: title, value: value, decimals: decimals) { typing = false }
                    .frame(width: 56)
            } else {
                Text(valueText ?? "\(value.wrappedValue.formatted(format))\(unit)")
                    .font(Ink.print(14)).monospacedDigit()
                    .foregroundStyle(modified ? Ink.amber : Ink.dim)
                    .lineLimit(1)
                    .frame(width: InkLayout.valueWidth, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { typing = true }
                    .help("Click to type a value")
            }
            ZStack {
                if modified {
                    Button { reset() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Ink.dim)
                        .help("Reset to \(defaultValue.formatted(format))\(unit)")
                        .accessibilityLabel("Reset \(title)")
                }
            }
            .frame(width: InkLayout.resetWidth)
        }
        .frame(height: InkLayout.rowHeight)
        .resettable(modified: modified, reset: reset)
        .accessibilityElement(children: .contain)
    }
}

/// A small slider that double-click or Option-click resets, as in Lightroom
/// and Capture One. AppKit, because NSSlider tracks the mouse itself and
/// SwiftUI's tap gestures on a Slider never fire. A double-click's first
/// click still moves the knob; the second resets.
struct ResettableSlider: NSViewRepresentable {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// Where the fill starts, so an untouched slider shows no amber.
    var defaultValue: Double?
    let editing: (Bool) -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = Control()
        slider.cell = Cell()
        slider.trackFillColor = EdgePrint.colour
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        let slider = slider as! Control
        slider.editing = editing
        slider.reset = reset
        slider.setAccessibilityLabel(title)
        // SwiftUI applies its environment's control size after makeNSView.
        if slider.controlSize != .small { slider.controlSize = .small }
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        if let cell = slider.cell as? Cell, cell.defaultValue != defaultValue {
            cell.defaultValue = defaultValue
            slider.needsDisplay = true
        }
        slider.wanted = value.wrappedValue
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            parent.value.wrappedValue = slider.doubleValue
            // Read back the snapped value at once rather than waiting for
            // updateNSView, so the knob's target is current when a drag ends.
            (slider as! Control).wanted = parent.value.wrappedValue
        }
    }

    /// A hairline track with a tick at the default, filled from the default to
    /// the value, and a small rectangular knob: amber once it's moved.
    final class Cell: NSSliderCell {
        var defaultValue: Double?
        private var modified: Bool {
            guard let defaultValue else { return true }
            return abs(doubleValue - defaultValue) > max(maxValue - minValue, 1e-9) / 2000
        }

        private func x(_ value: Double, in rect: NSRect) -> CGFloat {
            let inset = Self.knobWidth / 2
            let fraction = maxValue > minValue ? (min(max(value, minValue), maxValue) - minValue) / (maxValue - minValue) : 0
            return rect.minX + inset + CGFloat(fraction) * (rect.width - inset * 2)
        }

        private static let knobWidth: CGFloat = 8, knobHeight: CGFloat = 12

        override func knobRect(flipped: Bool) -> NSRect {
            guard let bounds = controlView?.bounds else { return super.knobRect(flipped: flipped) }
            return NSRect(x: x(doubleValue, in: bounds) - Self.knobWidth / 2, y: bounds.midY - Self.knobHeight / 2,
                          width: Self.knobWidth, height: Self.knobHeight)
        }

        override func drawBar(inside rect: NSRect, flipped: Bool) {
            guard let bounds = controlView?.bounds else { return }
            let y = bounds.midY
            Ink.trackColour.setFill()
            NSRect(x: bounds.minX + Self.knobWidth / 2, y: y - 1, width: bounds.width - Self.knobWidth, height: 2).fill()
            if let defaultValue {
                (isEnabled ? Ink.dimColour : Ink.trackColour).setFill()
                NSRect(x: (x(defaultValue, in: bounds) - 0.5).rounded(), y: y - 4, width: 1, height: 8).fill()
                if modified, isEnabled {
                    let (a, b) = (x(defaultValue, in: bounds), x(doubleValue, in: bounds))
                    EdgePrint.colour.setFill()
                    NSRect(x: min(a, b), y: y - 1, width: abs(a - b), height: 2).fill()
                }
            }
        }

        override func drawKnob(_ knobRect: NSRect) {
            let colour = !isEnabled ? Ink.trackColour : defaultValue != nil && modified ? EdgePrint.colour : Ink.labelColour
            NSColor.black.setFill()
            NSBezierPath(roundedRect: knobRect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).fill()
            colour.setFill()
            NSBezierPath(roundedRect: knobRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    final class Control: NSSlider {
        var editing: (Bool) -> Void = { _ in }
        var reset: () -> Void = {}
        /// The model's value, snapped to the step, which the knob shows.
        var wanted = 0.0 {
            didSet { if !tracking { show() } }
        }
        private var tracking = false
        private var settling: Timer?

        private func show() {
            if doubleValue != wanted { doubleValue = wanted }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 || event.modifierFlags.contains(.option) {
                reset()
                return
            }
            settling?.invalidate()
            // NSSlider tracks the drag inside mouseDown, so it returns when the mouse is released.
            tracking = true
            editing(true)
            super.mouseDown(with: event)
            tracking = false
            editing(false)
            show()
            // On macOS 26 the slider writes its last tracked value back about
            // 0.25 s after release, which undoes the step snap and a
            // double-click's reset. Keep showing the model's value until then.
            // A default-mode timer, so it never fires during a drag.
            let until = Date(timeIntervalSinceNow: 0.6)
            settling = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
                guard let self, Date() < until else { return timer.invalidate() }
                self.show()
            }
        }
    }
}

/// The number field shown while typing a slider's value. AppKit, because
/// SwiftUI's focus never reaches a field in the inspector column; the field
/// takes focus as it appears, which selects the value so typing replaces it.
private struct ValueField: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let decimals: Int
    let onEnd: () -> Void

    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = decimals
        formatter.isLenient = true
        return formatter
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField()
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.alignment = .right
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = formatter.string(from: value as NSNumber) ?? "" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ValueField
        private var cancelled = false
        init(_ parent: ValueField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            cancelled = true
            control.window?.makeFirstResponder(nil)
            return true
        }

        /// Return, Tab, clicking elsewhere and Escape all end here; only Escape discards the typing.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if !cancelled, let number = parent.formatter.number(from: field.stringValue) { parent.value = number.doubleValue }
            parent.onEnd()
        }
    }
}

/// Takes focus as it appears, selecting its text, in the inspector column
/// where SwiftUI focus doesn’t reach.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// The photograph's resolution before the film develops it, and the size it's
/// exported at. Reads only its own parameters, the crop and the source's size,
/// so other edits don't redraw it.
struct ImageSizeRows: View {
    let model: EditorModel
    @State private var fieldError: String?

    var body: some View {
        let params: JSONValue = .object(["io": .object(["photo_long_side_px": model.value(ImageSize.targetPath)])])
        let mode = ImageSize.mode(of: params)
        let source = model.sourceSize
        let working = source == .zero ? CGSize.zero : ImageSize.working(source: source, params: params, crop: model.crop)
        let photograph = model.crop.size(of: working)
        ChoiceRow("Develop at", selection: Binding(get: { mode }, set: { fieldError = nil; model.chooseImageSize($0) })) {
            Text("Original").tag(ImageSize.Mode.original)
            Text("Longest side").tag(ImageSize.Mode.longestSide)
        }
        .help("Original develops the photograph’s own pixels. Longest side enlarges or reduces it first, so the cropped photograph has that many pixels on its longest side.")
        if mode == .longestSide {
            LabeledContent("Longest side") {
                HStack(spacing: 4) {
                    PixelField(title: "Longest side", value: ImageSize.target(of: params) ?? 0) { pixels in
                        fieldError = model.setLongestSide(pixels)
                        return fieldError == nil
                    }
                    .frame(width: 72)
                    Text("px").foregroundStyle(Ink.dim)
                }
            }
            .help("The cropped photograph’s longest side, before any border. Exports can still be reduced in the save panel.")
            if let fieldError {
                Text(fieldError).font(.caption).foregroundStyle(.red)
            }
        }
        LabeledContent("Photograph") {
            // Verbatim, so pixel counts read like the status bar's, without grouping.
            Text(verbatim: photograph == .zero ? "—" : "\(Int(photograph.width)) × \(Int(photograph.height)) · \(ImageSize.megapixels(photograph)) MP")
                .font(Ink.print(14)).monospacedDigit()
        }
        .help("The exported photograph, cropped, before rotation, the border, and any export size.")
        if ImageSize.exceedsLimit(working: working, source: source) {
            Label(ImageSize.limitMessage(working: working), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if model.previewScale < 1, model.image != nil {
            InkNote("The preview shows \(EditorModel.percent(model.previewScale)) of these pixels. Exports develop all of them; inspect grain in an exported file.")
        }
    }
}

/// A whole number of pixels, committed on Return or when focus leaves. An
/// invalid value stays in the field until corrected; Escape restores the
/// current one. AppKit, like `ValueField`, so the inspector column can focus it.
private struct PixelField: NSViewRepresentable {
    let title: String
    let value: Int
    /// Applies a typed value; false keeps the typing for correction.
    let commit: (Int) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.alignment = .right
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, !context.coordinator.rejected { field.stringValue = "\(value)" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PixelField
        /// The field holds a value that wasn't applied.
        var rejected = false
        init(_ parent: PixelField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            rejected = false
            (control as? NSTextField)?.stringValue = "\(parent.value)"
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            guard text != "\(parent.value)" || rejected else { return }
            rejected = !parent.commit(Int(text) ?? -1)
        }
    }
}

private extension View {
    func resettable(_ model: EditorModel, _ path: String) -> some View {
        resettable(modified: model.isModified(path)) { model.resetValue(path) }
    }
    func resettable(modified: Bool, reset: @escaping () -> Void) -> some View {
        contextMenu {
            Button("Reset to Default", action: reset).disabled(!modified)
        }
    }
}

/// Six equal workflow tabs in edge print, with a dot on any that holds edits.
/// Print strikes through while the film is scanned directly.
struct InspectorTabBar: View {
    let model: EditorModel
    @AppStorage(HiddenParts.key) private var hidden = ""
    @AppStorage(HiddenParts.revealKey) private var revealed = false

    var body: some View {
        let scanning = model.labScan
        let parts = HiddenParts(storage: $hidden, revealed: revealed)
        HStack(spacing: 0) {
            ForEach(parts.visibleTabs) { tab in
                let selected = parts.visibleTab(model.inspectorTab) == tab
                let skipped = tab.isSkipped(scanning: scanning)
                let edited = model.editCount(on: tab) > 0
                Button {
                    model.inspectorTab = tab
                } label: {
                    Text(tab.title.uppercased())
                        .font(Ink.print(14)).tracking(0.7)
                        .foregroundStyle(selected ? Ink.amber : Ink.dim)
                        .strikethrough(skipped)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(alignment: .bottom) { if selected { Ink.amber.frame(height: 2) } }
                        .overlay(alignment: .topTrailing) {
                            if edited { Circle().fill(Ink.amber).frame(width: 4, height: 4).padding(.top, 7).padding(.trailing, 5) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Equal shares of the bar, so the columns never shift.
                .frame(maxWidth: .infinity)
                .help(skipped ? "Print is skipped while Scan film directly is on." : tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityValue([skipped ? "Skipped" : selected ? "Selected" : "", edited ? "Has edits" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
                .hideable(tab.hideKey)
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
        .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
    }
}

/// A heading for one stage in the all-controls column.
private struct StageHeading: View {
    let title: String
    let edited: Bool
    var folded = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(Ink.print(16)).tracking(1).foregroundStyle(Ink.paper)
                .accessibilityAddTraits(.isHeader)
            if edited { Circle().fill(Ink.amber).frame(width: 4, height: 4).accessibilityHidden(true) }
            Spacer(minLength: 0)
            if folded { FoldChevron() }
        }
        .padding(.horizontal, InkLayout.gutter)
        .frame(height: 36)
        .background(Ink.well)
        .contentShape(Rectangle())
        .accessibilityValue(folded ? "Collapsed" : "Expanded")
    }
}

struct AdjustmentInspector: View {
    let model: EditorModel
    @AppStorage("expandedAdjustments") private var expanded = "Lens Diffusion,Grain,Halation"
    /// Modules showing their "more controls".
    @AppStorage("expandedMoreControls") private var expandedMore = ""
    @AppStorage(AllFolds.key) private var allFoldsStorage = ""
    private var allFolds: AllFolds { AllFolds(storage: $allFoldsStorage) }
    @AppStorage(HiddenParts.key) private var hiddenStorage = ""
    @AppStorage(HiddenParts.revealKey) private var revealHidden = false
    private var hiddenParts: HiddenParts { HiddenParts(storage: $hiddenStorage, revealed: revealHidden) }

    /// The selected tab lives on the model, so changing photos or switching
    /// to Presets keeps it for this session without carrying it into the next.
    /// A hidden one gives way to the first stage shown.
    private var tab: InspectorTab { hiddenParts.visibleTab(model.inspectorTab) }
    /// The grid's panel is always the everyday controls.
    private var simple: Bool { model.inspectorMode == .simple || model.gridVisible }
    private var everything: Bool { model.inspectorMode == .all && !model.gridVisible }

    var body: some View {
        // The histogram and workflow tabs stay put above the tab's scrolling sections.
        VStack(spacing: 0) {
            ZoneHistogramView(model: model)
                .padding(.horizontal, InkLayout.gutter)
                .padding(.bottom, 4)
                .hideable("histogram")
            stockCards
                .hideable("stocks")
            if model.gridVisible {
                let count = model.gridSelection.count
                Text((count == 1 ? "Editing 1 photo" : "Editing \(count) photos").uppercased())
                    .font(Ink.print(14)).foregroundStyle(Ink.amber)
                    .padding(.horizontal, InkLayout.gutter)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .overlay(alignment: .top) { Ink.line.frame(height: 1) }
                    .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
            } else if !simple && !everything {
                InspectorTabBar(model: model)
            } else {
                Ink.line.frame(height: 1)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if simple {
                        simplePage
                    } else if everything {
                        ForEach(hiddenParts.visibleTabs) { stage in
                            let key = stage.hideKey
                            StageHeading(title: stage.title, edited: model.editCount(on: stage) > 0, folded: allFolds.contains(key))
                                .onTapGesture(count: 2) { allFolds.toggle(key) }
                                .hideable(key)
                            if !allFolds.contains(key) { OrderedSections(tab: stage) { page(stage) } }
                        }
                    } else {
                        OrderedSections(tab: tab) { page(tab) }
                    }
                }
            }
            // A fresh page per tab starts at the top rather than inheriting
            // the last tab's scroll offset.
            .id(simple ? "simple" : everything ? "all" : tab.rawValue)
            if simple || everything || tab == .export { exportFooter }
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.label)
        .toggleStyle(InkSwitchStyle())
        .labeledContentStyle(InkRowStyle())
        .environment(\.inspectorShowsEverything, everything)
        .disabled(!model.hasCatalog)
    }

    /// The film and paper, above the tabs, to change from any of them. There's
    /// no paper to choose on a lab scan.
    private var stockCards: some View {
        let scanning = model.labScan
        return VStack(spacing: InkLayout.cardGap) {
            filmPicker
            paperPicker
                .opacity(scanning ? 0.45 : 1)
                .disabled(scanning)
                .help(scanning ? "Lab scans don’t use paper. Choose Paper print in Print to print the film." : "")
        }
        .padding(.horizontal, InkLayout.gutter)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
    }

    @ViewBuilder private func page(_ tab: InspectorTab) -> some View {
        switch tab {
        case .camera: cameraTab
        case .film: filmTab
        case .print: printTab
        case .scan: scanTab
        case .export: exportTab
        }
    }

    /// What will be written, and the button that writes it, pinned below the page.
    private var exportFooter: some View {
        VStack(spacing: 8) {
            Text(verbatim: exportSummary).font(Ink.print(14)).monospacedDigit().foregroundStyle(Ink.label)
            Button { model.savePanel(export: true) } label: {
                Text("Export Image…").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(Ink.amber, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.source == nil || !model.ready || model.exporting || model.saving)
            .opacity(model.source == nil || !model.ready || model.exporting || model.saving ? 0.5 : 1)
            .help("Export the photograph (⇧⌘E).")
        }
        .padding(.horizontal, InkLayout.gutter)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
    }

    private var exportSummary: String {
        let format = model.exportFormat.title.split(separator: " ").first.map(String.init) ?? model.exportFormat.title
        let size = model.photoSize == .zero ? "" : "\(Int(model.photoSize.width)) × \(Int(model.photoSize.height)) · "
        return "\(size)\(format) \(model.exportBitDepth)-bit · \(model.previewSpace)"
    }

    // MARK: Simple

    /// The everyday controls on one page, from the film to the export. Whatever
    /// Advanced has set still applies.
    @ViewBuilder private var simplePage: some View {
        let scanning = model.labScan
        InkSection("Print") {
            outputPicker
            if scanning { scannerPicker }
            Group {
                ForEach(simplePrintControls) { control($0) }
            }
            .opacity(scanning ? 0.45 : 1)
            .disabled(scanning)
            if scanning { InkNote("Lab scans don’t use paper.") }
        }
        if model.isRaw { whiteBalanceSection }
        InkSection("Tone") {
            ForEach(toneControls) { control($0) }
        }
        module("Detail", summary: summary(of: simpleDetailControls.first), edited: isEdited(simpleDetailControls)) {
            ForEach(simpleDetailControls) { control($0) }
        }
        module("Output", summary: "\(model.exportFormat.title) · \(model.exportBitDepth)-bit") {
            ImageSizeRows(model: model)
            fileRows
        }
    }

    // MARK: Camera

    /// A RAW file's white balance, on Simple's page and in Advanced's Camera tab.
    @ViewBuilder private var whiteBalanceSection: some View {
        InkSection("White Balance") {
            control(.choice("RAW white balance", "io.raw_white_balance.mode", ["as_shot", "daylight", "tungsten", "custom"]))
            if model.value("io.raw_white_balance.mode").string == "custom" {
                control(.slider("Temperature (K)", "io.raw_white_balance.temperature", 1667...25000, 1))
                control(.slider("Tint", "io.raw_white_balance.tint", 0.01...4, 0.01))
            }
        }
    }

    @ViewBuilder private var cameraTab: some View {
        InkSection("Exposure") {
            control(.slider("Exposure (EV)", "camera.exposure_compensation_ev", -5...5, 0.1))
            control(zoneShiftControl)
                .help("Moves the light on the film without the print making up for it. ⌃-click the photograph, then click a zone in the histogram, to set it from a reading.")
            Toggle("Auto exposure", isOn: model.toggle("camera.auto_exposure"))
            dependent(on: "camera.auto_exposure") {
                control(.choice("Metering", "camera.auto_exposure_method", ["average", "median", "center_weighted", "partial", "matrix", "multi_zone", "highlight_weighted"]))
            }
        }
        if model.isRaw {
            whiteBalanceSection
        } else {
            inputColour
        }
        InkSection("Lens") {
            FilmFormatPicker(model: model)
            control(.slider("Lens blur (µm)", "camera.lens_blur_um", 0...100, 0.1))
            if model.isRaw, model.lensCorrectionSupported {
                control(.toggle("Lens corrections", EditorModel.lensCorrectionPath))
                    .help("Corrects distortion and vignetting with the data the camera recorded for its lens.")
            }
        }
        group("Lens Diffusion")
    }

    // MARK: Film

    @ViewBuilder private var filmTab: some View {
        InkSection {
            developmentTime(stock: model.films.first { $0.id == model.film }, path: "film_render.development_time", label: "Development")
        }
        // The controls people reach for first, at the top.
        group("Grain")
        group("Halation")
        group("DIR Couplers")
        group("Film Curves")
        group("Film Base")
    }

    @ViewBuilder private var filmPicker: some View {
        // Preview grids, or the plain menus when Settings turns them off.
        if model.previews.enabled {
            StockFoldout(model: model, paper: false)
        } else {
            StockMenuCard(name: model.filmName, kind: "Film stock", label: "Film", groups: hiddenParts.visible(model.filmGroups, keeping: model.film), selected: model.film, choose: model.chooseFilm)
        }
    }

    // MARK: Print

    /// Lab scan or Paper print. A slide can only be scanned.
    private var outputPicker: some View {
        SegmentedRow(title: "Output",
                     selection: Binding(get: { OutputRoute.of(model.state.params) }, set: { model.chooseOutput($0) }),
                     options: OutputRoute.allCases.map { ($0, $0.title) })
            .disabled(model.filmIsPositive)
            .help(model.filmIsPositive
                  ? "A slide is scanned: it can’t be printed on paper here."
                  : "Lab scan reads the developed film on a Frontier or Noritsu. Paper print prints it, then scans the print.")
    }

    private var scannerPicker: some View {
        SegmentedRow(title: "Scanner",
                     selection: Binding(get: { ScannerKeys.model(model.state.params) },
                                        set: { model.set(ScannerKeys.modelPath, .string($0)) }),
                     options: ScannerKeys.models.map { ($0, ScannerKeys.title($0)) })
            .help("The lab scanner whose colour the scan takes.")
    }

    @ViewBuilder private var printTab: some View {
        let scanning = model.labScan
        InkSection {
            outputPicker
            if scanning { InkNote("Lab scans don’t use paper.") }
        }
        if !scanning {
            if let paper = model.papers.first(where: { $0.id == model.paper }), paper.times.count > 1 {
                InkSection {
                    developmentTime(stock: paper, path: "print_render.development_time", label: "Print development")
                }
            }
            InkSection("Enlarger") {
                control(.slider("Print exposure", "enlarger.print_exposure", 0.1...5, 0.01))
                control(.toggle("Exposure compensation", "enlarger.print_exposure_compensation"))
            }
            InkSection("Filtration", action: {
                Button(model.balancingPrint ? "Balancing…" : "Balance Print") { model.balancePrint() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(!model.canBalancePrint)
                    .help("Sets the magenta and yellow shifts so a mid-grey prints neutral with the current film, bases, paper and enlarger. Use it after changing the film base.")
            }) {
                control(.slider("Magenta shift", "enlarger.m_filter_shift", -50...50, 0.1))
                control(.slider("Yellow shift", "enlarger.y_filter_shift", -50...50, 0.1))
            }
            let preflash = [
                Adjustment.slider("Preflash exposure", "enlarger.preflash_exposure", 0...0.5, 0.01),
                .slider("Preflash magenta", "enlarger.preflash_m_filter_shift", -50...50, 0.1),
                .slider("Preflash yellow", "enlarger.preflash_y_filter_shift", -50...50, 0.1)
            ]
            module("Preflash", summary: summary(of: preflash.first), edited: isEdited(preflash)) {
                ForEach(preflash) { control($0) }
            }
            group("Print Curves")
            group("Print Base")
            group("Glare")
        }
    }

    @ViewBuilder private var paperPicker: some View {
        if model.previews.enabled {
            StockFoldout(model: model, paper: true)
        } else {
            StockMenuCard(name: model.paperName, kind: "Paper", label: "Paper", groups: hiddenParts.visible(model.paperGroups, keeping: model.paper), selected: model.paper, choose: model.choosePaper)
        }
    }

    // MARK: Scan

    @ViewBuilder private var scanTab: some View {
        if model.labScan {
            InkSection("Lab Scanner", footer: "The lab balances every frame for density and colour, as Frontier and Noritsu operators’ machines do. The keys correct on top, in clicks of about 1/12 stop: Density darkens, and Cyan, Magenta and Yellow add that colour.") {
                scannerPicker
                ForEach(ScannerKeys.keys, id: \.path) { key in
                    KeyStepperRow(title: key.title, value: model.value(key.path).double,
                                  step: { model.stepKey(key.path, by: $0) },
                                  reset: { model.set(key.path, .number(0)) })
                }
            }
        }
        InkSection("Tone", footer: "These shape the tones the film produced. To recover a clipped highlight, use Exposure in Camera.") {
            ForEach(toneControls) { control($0) }
        }
        InkSection("Sharpness") {
            control(.slider("Unsharp radius (px)", "scanner.unsharp_mask.0", 0...3, 0.01))
            control(.slider("Unsharp amount", "scanner.unsharp_mask.1", 0...2, 0.01))
            ForEach(scanDetailControls) { control($0) }
            control(.slider("Lens blur (px)", "scanner.lens_blur", 0...5, 0.01))
        }
        InkSection("Levels") {
            control(.toggle("White correction", "scanner.white_correction"))
            dependent(on: "scanner.white_correction") {
                control(.slider("White level", "scanner.white_level", 0.5...1, 0.01))
            }
            control(.toggle("Black correction", "scanner.black_correction"))
            dependent(on: "scanner.black_correction") {
                control(.slider("Black level", "scanner.black_level", 0...0.5, 0.01))
            }
        }
        module("Border", enable: model.border(\.enabled), summary: model.border.style.title) {
            let photo = model.photoSize == .zero ? nil : model.photoSize
            BorderStylePicker(selection: model.border(\.style), photo: photo, colors: (model.border.color, model.border.lineColor))
            if let photo, !BorderStyle.film35.fits(photo) {
                InkNote("35mm needs a 3:2 or 3:4 photograph. This one is \(Self.ratio(photo)); crop it to 3:2 or 4:3 to use it.")
            }
            borderControls
            Toggle("Extend to 3:4 for Instagram", isOn: model.border(\.instagram))
                .help("Adds white above and below, or at the sides, so Instagram shows the whole photograph in a 3:4 portrait post.")
        }
        group("Color Management")
    }

    // MARK: Export

    @ViewBuilder private var exportTab: some View {
        InkSection("Resolution", footer: "Develop size is applied first, so film simulation, halation and grain render at it.") {
            ImageSizeRows(model: model)
            ChoiceRow("Export at", selection: Binding(get: { model.exportSize.edge }, set: { model.exportSize.edge = $0 })) {
                ForEach(ExportSize.Edge.allCases, id: \.rawValue) { edge in
                    Text(edge.title).tag(edge)
                }
            }
            .help("Fits the finished file, border included, to this many pixels. Never enlarges.")
            if model.exportSize.edge != .full {
                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("", value: Binding(
                            get: { model.exportSize.pixels },
                            set: { model.exportSize.pixels = min(max($0, ExportSize.pixelRange.lowerBound), ExportSize.pixelRange.upperBound) }
                        ), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .accessibilityLabel(model.exportSize.edge == .long ? "Long edge in pixels" : "Short edge in pixels")
                        Text("px").foregroundStyle(Ink.dim)
                    }
                } label: {
                    Text(model.exportSize.edge == .long ? "Long edge" : "Short edge")
                }
            }
        }
        InkSection("File") {
            fileRows
            ChoiceRow("Colour space", selection: Binding(get: { model.previewSpace }, set: model.choosePreviewSpace)) {
                ForEach(SaveSettings.colorSpaces, id: \.self) { Text($0).tag($0) }
            }
            .help("The preview develops in this colour space, and exports are written in it. ProPhoto RGB needs 16 bits.")
            Toggle("Encode with the colour space’s curve", isOn: model.toggle("io.output_cctf_encoding"))
                .help("Off writes linear values, for further processing.")
            Toggle("Include border", isOn: model.border(\.export))
                .help("Adds the border to exported photographs and saved previews.")
                .disabled(!model.border.enabled)
        }
        module("Performance", summary: model.exportEngine.title) {
            ChoiceRow("Engine", selection: Binding(get: { model.exportEngine }, set: { model.exportEngine = $0 })) {
                ForEach(ExportEngine.allCases, id: \.rawValue) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .help("Reference develops the photo again with extra precision. Fast uses the preview's result and looks the same.")
            Toggle("Limit preview to 12 MP", isOn: Binding(get: { model.limitsPreview }, set: model.limitPreview))
                .help("Develops the preview faster on large photographs. Export keeps the full Image Size.")
            Toggle("Use less memory for export", isOn: model.toggle("settings.serial_grain"))
                .help("Processes grain channels one at a time. Same result, less memory, longer export.")
        }
    }

    @ViewBuilder private var fileRows: some View {
        ChoiceRow("Format", selection: Binding(get: { model.exportFormat }, set: { model.exportFormat = $0 })) {
            ForEach(OutputFormat.allCases, id: \.rawValue) { format in
                Text(format.title).tag(format)
            }
        }
        .help("The file type, and the extension the save panel offers.")
        ChoiceRow("Bit depth", selection: Binding(get: { model.exportBitDepth }, set: { model.exportBitDepth = $0 })) {
            Text("8-bit").tag(8)
            Text("16-bit").tag(16)
        }
        .disabled(model.exportFormat == .jpeg)
        .help(model.exportFormat == .jpeg ? "JPEG is 8-bit only." : "Bits per channel, for PNG and TIFF.")
        if model.exportFormat == .jpeg {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(model.exportQuality) },
                                          set: { model.exportQuality = Int($0.rounded()) }),
                           in: Double(SaveSettings.qualityRange.lowerBound)...Double(SaveSettings.qualityRange.upperBound),
                           step: 1)
                    .controlSize(.small)
                    .frame(width: 140)
                    Text("\(model.exportQuality)").font(Ink.print(14)).monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            } label: { Text("JPEG quality") }
        }
        if model.exportBitDepth == 8, model.previewSpace == SaveSettings.colorSpaces[SaveSettings.prophoto] {
            InkNote("ProPhoto RGB needs 16 bits; exports use Adobe RGB (1998) at 8 bits.")
        }
    }

    /// How a non-RAW photograph's values are read: automatically from its
    /// profile and tags, as an assumed colour space, or (Manual) by the input
    /// colour space and curve, as Negs 0.8 read every file.
    @ViewBuilder private var inputColour: some View {
        module("Input Colour") {
            ChoiceRow("Read as", selection: model.inputInterpretation) {
                Text("Automatic").tag("auto")
                Section("Assume") {
                    ForEach(["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ITU-R BT.2020"], id: \.self) { Text($0).tag("assume:" + $0) }
                }
                Text("Manual").tag("manual")
            }
            .help("Automatic reads the embedded profile or tags; untagged files are read as sRGB. Assume overrides them. Manual uses the colour space and curve below, as Negs 0.8 did.")
            switch model.value("io.input_interpretation.mode").string {
            case "assume":
                Toggle("Linear values", isOn: model.toggle("io.input_interpretation.linear"))
            case "manual":
                control(.choice("Colour space", "io.input_color_space", ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ITU-R BT.2020", "ACES2065-1", "ACEScg"]))
                Toggle("Decode the curve", isOn: model.toggle("io.input_cctf_decoding"))
            default: EmptyView()
            }
            let colour = model.inputColour
            if colour != .null {
                VStack(alignment: .leading, spacing: 2) {
                    Text(colour["summary"].string)
                    if colour["automatic"].string != colour["summary"].string { Text("Automatic: \(colour["automatic"].string)") }
                    if !colour["warning"].string.isEmpty { Text(colour["warning"].string).foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(Ink.dim)
            }
        }
    }

    /// The chosen style's width and colours. Solid and Keyline share the
    /// mat; the film frame's width adds black around it.
    @ViewBuilder private var borderControls: some View {
        switch model.border.style {
        case .solid, .keyline:
            let keyline = model.border.style == .keyline
            borderSlider("Width", \.width, 0...15, step: 0.1)
            if keyline { borderSlider("Line width", \.line, 0.05...2, step: 0.05) }
            ColorPicker("Color", selection: model.borderColor(\.color), supportsOpacity: false)
            if keyline { ColorPicker("Line color", selection: model.borderColor(\.lineColor), supportsOpacity: false) }
        case .film:
            borderSlider("Width", \.filmWidth, 0...15, step: 0.1)
                .help("Adds black around the film frame.")
        case .film35:
            EmptyView()
        }
    }

    /// A border width in percent of the photograph's long edge.
    private func borderSlider(_ title: String, _ setting: WritableKeyPath<BorderSettings, Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        let initial = BorderSettings()[keyPath: setting]
        return LabeledSlider(title: title, value: model.borderPercent(setting, range: range, step: step), range: range, step: step, unit: "%",
                             defaultValue: initial * 100, modified: abs(model.border[keyPath: setting] - initial) > 1e-9,
                             reset: { model.border(setting).wrappedValue = initial },
                             editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Border") })
    }

    private func control(_ adjustment: Adjustment) -> some View { AdjustmentControl(model: model, adjustment: adjustment) }
    /// A photograph's aspect ratio as people name it, such as 16:9.
    static func ratio(_ size: CGSize) -> String {
        let ratio = max(size.width, size.height) / min(size.width, size.height)
        let named = [(1.0, "1:1"), (5.0 / 4, "5:4"), (7.0 / 5, "7:5"), (16.0 / 9, "16:9"), (2.0, "2:1"), (21.0 / 9, "21:9")]
        if let (_, name) = named.first(where: { abs(ratio / $0.0 - 1) <= 0.01 }) { return name }
        return String(format: "%.2f:1", Double(ratio))
    }

    /// A control that only counts while `path` is on: hidden otherwise, or
    /// dimmed in the all-controls column, which shows everything.
    @ViewBuilder private func dependent<Content: View>(on path: String, @ViewBuilder content: () -> Content) -> some View {
        let on = model.value(path).bool
        if on || everything {
            content().opacity(on ? 1 : 0.5).disabled(!on)
        }
    }

    /// A control's value as text, for a collapsed module's summary.
    private func summary(of control: Adjustment?) -> String? {
        switch control {
        case .slider(_, let path, _, let step):
            let decimals = max(0, Int(-log10(step).rounded(.down)))
            return model.value(path).double.formatted(.number.precision(.fractionLength(0...decimals)))
        case .choice(_, let path, _): return optionTitle(model.value(path).string)
        case .stockSlider(_, let path, let index, let range, let step, _):
            return model.stockNumber(path, index, range: range, step: step).wrappedValue.formatted(.number.precision(.fractionLength(0...2)))
        case .linked(_, _, let lanes, _, _, _):
            return lanes.first.map { model.laneValue($0).formatted(.number.precision(.fractionLength(0...2))) }
        case .toggle(_, let path): return model.value(path).bool ? "On" : "Off"
        case nil: return nil
        }
    }

    private func isEdited(_ controls: [Adjustment]) -> Bool {
        controls.contains { control in
            switch control {
            case .slider(_, let path, _, _), .toggle(_, let path), .choice(_, let path, _): model.isModified(path)
            case .stockSlider(_, let path, let index, _, _, _): model.isStockModified(path, index)
            case .linked(_, _, let lanes, _, _, _): lanes.contains(where: model.isLaneModified)
            }
        }
    }

    /// One effect group's module, by title, so each tab can order them. Its
    /// first controls show; the rest wait behind "more controls".
    @ViewBuilder private func group(_ title: String) -> some View {
        if let group = adjustmentGroups.first(where: { $0.title == title }) {
            let primary = min(group.primary ?? group.controls.count, group.controls.count)
            let rest = Array(group.controls[primary...])
            let showingRest = everything || expandedMore.split(separator: ",").contains(Substring(title))
            // A filter's name and its strength say something; two numbers in a row don't.
            let picks: [Adjustment] = { if case .choice = group.controls.first { return Array(group.controls.prefix(2)) }; return Array(group.controls.prefix(1)) }()
            module(group.title, enable: group.enable.map { model.toggle($0) },
                   summary: picks.compactMap(summary(of:)).joined(separator: " · "),
                   edited: isEdited(group.controls)) {
                ForEach(group.controls.prefix(primary)) { control($0) }
                if !rest.isEmpty {
                    if showingRest { ForEach(rest) { control($0) } }
                    if !everything {
                        Button(showingRest ? "Fewer controls" : "\(rest.count) more controls") {
                            var titles = expandedMore.split(separator: ",").map(String.init).filter { $0 != title }
                            if !showingRest { titles.append(title) }
                            expandedMore = titles.joined(separator: ",")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Ink.dim)
                        .frame(height: 24)
                        .accessibilityAddTraits(showingRest ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// A foldable module: a title with a summary while closed, and a switch if
    /// the effect can be turned off. Clicking a switched-off module's title
    /// turns it on. The all-controls column keeps every module open.
    private func module<Content: View>(_ title: String, enable: Binding<Bool>? = nil, summary: String? = nil, edited: Bool = false,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        let isOpen = expanded.split(separator: ",").contains(Substring(title))
        let on = enable?.wrappedValue ?? true
        let foldKey = "module:" + title
        let showsBody = everything ? !allFolds.contains(foldKey) : isOpen && on
        func setOpen(_ open: Bool) {
            var titles = expanded.split(separator: ",").map(String.init).filter { $0 != title }
            if open { titles.append(title) }
            expanded = titles.joined(separator: ",")
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    guard !everything else { return }
                    if !on { enable?.wrappedValue = true; setOpen(true) } else { setOpen(!isOpen) }
                } label: {
                    HStack(spacing: 8) {
                        if !everything {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Ink.dim)
                                .rotationEffect(.degrees(showsBody ? 90 : 0))
                                .frame(width: 10)
                        }
                        Text(title)
                            .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Ink.paper : Ink.dim)
                            .lineLimit(1).layoutPriority(1)
                        if edited, !showsBody { Circle().fill(Ink.amber).frame(width: 4, height: 4).accessibilityHidden(true) }
                        Spacer(minLength: 8)
                        if !showsBody {
                            Text(on ? summary ?? "" : "Off")
                                .font(.system(size: 11)).foregroundStyle(Ink.dim)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        if everything, !showsBody { FoldChevron() }
                    }
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sectionHandle("module:" + title)
                .simultaneousGesture(TapGesture(count: 2).onEnded { if everything { allFolds.toggle(foldKey) } })
                .accessibilityLabel(title)
                .accessibilityValue(on ? (showsBody ? "Expanded" : "Collapsed") : "Off")
                if let enable {
                    InkSwitch(isOn: Binding(get: { enable.wrappedValue }, set: { turning in
                        enable.wrappedValue = turning
                        if turning { setOpen(true) }
                    }))
                    .accessibilityLabel("Enable \(title)")
                }
            }
            if showsBody {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .opacity(on ? 1 : 0.5)
                    .disabled(!on)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, InkLayout.gutter)
        .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
        .hideable("module:" + title)
        .movableSection("module:" + title)
    }

    @ViewBuilder private func developmentTime(stock: Stock?, path: String, label: String) -> some View {
        if let stock, stock.times.count > 1 {
            ChoiceRow(label, selection: Binding(get: { model.value(path).double }, set: { model.set(path, $0 == 0 ? .null : .number($0)) })) {
                Text("Profile default").tag(0.0)
                ForEach(stock.times, id: \.self) { Text("\($0.formatted()) min").tag($0) }
            }
        }
    }
}
