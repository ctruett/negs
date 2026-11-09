import SwiftUI

/// The lab scanner's keys, laid out as on a Frontier's operator keypad:
/// −C −M −Y over +C +M +Y, then −3D −D N +D +3D and COLOR KEY CANCEL. Each
/// colour key's label is the colour it turns the photograph, as on the
/// machine: +C cyan, and −C its complement, red.
struct LabKeypad: View {
    let model: EditorModel

    private static let colours: [(path: String, letter: String, plus: Color, minus: Color)] = [
        ("scanner.cyan_key", "C", Keycap.cyan, Keycap.red),
        ("scanner.magenta_key", "M", Keycap.magenta, Keycap.green),
        ("scanner.yellow_key", "Y", Keycap.yellow, Keycap.blue),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ForEach(Self.colours, id: \.path) { key in
                        colourKey(key.path, "−" + key.letter, key.minus, -1, "Less \(name(key.letter)): the photograph goes \(complement(key.letter)).")
                    }
                }
                GridRow {
                    ForEach(Self.colours, id: \.path) { key in
                        colourKey(key.path, "+" + key.letter, key.plus, 1, "More \(name(key.letter)).")
                    }
                }
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    densityKey("−3D", -3, "Three clicks lighter.")
                    densityKey("−D", -1, "A click lighter, about 1/12 stop.")
                    Button("N") { model.normalDensity() }
                        .buttonStyle(Keycap())
                        .help("Normal: the density key back to 0.")
                    densityKey("+D", 1, "A click darker, about 1/12 stop.")
                    densityKey("+3D", 3, "Three clicks darker.")
                }
            }
            Button { model.cancelColourKeys() } label: {
                Text("COLOR KEY\nCANCEL").multilineTextAlignment(.center)
            }
            .buttonStyle(Keycap(wide: true))
            .help("The cyan, magenta and yellow keys back to 0.")
        }
        .padding(.vertical, 4)
    }

    /// Where the keys stand, in clicks.
    private var readout: some View {
        HStack(spacing: 14) {
            ForEach(Self.colours, id: \.path) { key in clicks(key.letter, model.value(key.path).double) }
            clicks("D", model.value(ScannerKeys.densityPath).double)
        }
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
    }

    private func clicks(_ letter: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(letter).foregroundStyle(Ink.dim)
            Text(value == 0 ? "0" : String(format: "%+.0f", value)).foregroundStyle(value == 0 ? Ink.dim : Ink.paper)
        }
    }

    private func colourKey(_ path: String, _ label: String, _ colour: Color, _ clicks: Double, _ help: String) -> some View {
        Button { model.stepKey(path, by: clicks) } label: { KeyChip(text: label, colour: colour) }
            .buttonStyle(Keycap())
            .help(help)
            .accessibilityLabel(label)
    }

    private func densityKey(_ label: String, _ clicks: Double, _ help: String) -> some View {
        Button(label) { model.stepKey(ScannerKeys.densityPath, by: clicks) }
            .buttonStyle(Keycap())
            .help(help)
    }

    private func name(_ letter: String) -> String { ["C": "cyan", "M": "magenta", "Y": "yellow"][letter] ?? letter }
    private func complement(_ letter: String) -> String { ["C": "red", "M": "green", "Y": "blue"][letter] ?? letter }
}

/// A colour key's legend: its sign and letter on a block of the colour it
/// turns the photograph.
struct KeyChip: View {
    let text: String
    let colour: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 2.5).fill(colour))
    }
}

/// An off-white keycap with a darker skirt, as on the lab's keypad; pressed,
/// it sinks.
struct Keycap: ButtonStyle {
    var wide = false

    static let cyan = Color(red: 0.24, green: 0.72, blue: 0.85)
    static let magenta = Color(red: 0.88, green: 0.19, blue: 0.48)
    static let yellow = Color(red: 0.93, green: 0.73, blue: 0.10)
    static let red = Color(red: 0.91, green: 0.25, blue: 0.18)
    static let green = Color(red: 0.17, green: 0.67, blue: 0.58)
    static let blue = Color(red: 0.30, green: 0.61, blue: 0.88)

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: wide ? 10.5 : 13, weight: .medium))
            .foregroundStyle(Color(red: 0.16, green: 0.20, blue: 0.27))
            .lineSpacing(-1)
            .frame(maxWidth: .infinity, minHeight: wide ? 34 : 30)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: pressed
                                         ? [Color(white: 0.80), Color(white: 0.86)]
                                         : [Color(white: 0.96), Color(white: 0.86)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.62), lineWidth: 0.75))
            .background(
                // The skirt under the cap.
                RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.55)).offset(y: pressed ? 0.5 : 2)
            )
            .offset(y: pressed ? 1.5 : 0)
            .contentShape(Rectangle())
    }
}
