import AppKit
import SwiftUI
import CoreText
import ImageIO

/// A photograph's camera details, for the lines printed beside it.
struct PhotoExif: Equatable, Sendable {
    var make: String?
    var model: String?
    var lens: String?
    var iso: Int?
    /// In seconds.
    var exposure: Double?
    var aperture: Double?
    var focalLength: Double?
    /// `yyyy:MM:dd HH:mm:ss`, as EXIF has it.
    var taken: String?

    /// The camera.
    var cameraLine: String {
        var camera = model ?? ""
        // "NIKON CORPORATION", "NIKON D750": the model usually says the make already.
        if let make, !make.isEmpty, !camera.localizedCaseInsensitiveContains(make.split(separator: " ").first ?? "") {
            camera = camera.isEmpty ? make : "\(make.split(separator: " ").first ?? "") \(camera)"
        }
        return camera.uppercased()
    }

    /// The exposure.
    var exposureLine: String {
        var parts: [String] = []
        if let iso { parts.append("ISO \(iso)") }
        if let exposure, exposure > 0 { parts.append(Self.shutter(exposure)) }
        if let aperture, aperture > 0 { parts.append("f/\(Self.trimmed(aperture))") }
        if let focalLength, focalLength > 0 { parts.append("\(Self.trimmed(focalLength)) MM") }
        return parts.joined(separator: "   ")
    }

    var isEmpty: Bool { cameraLine.isEmpty && exposureLine.isEmpty }

    /// The line above the photograph: camera, exposure and file name, with
    /// whichever it has.
    static func detailsLine(_ exif: PhotoExif?, fileName: String?) -> String {
        [exif?.cameraLine ?? "", exif?.exposureLine ?? "", fileName ?? ""]
            // Three em spaces: a gap that reads as a break between the parts,
            // well wider than the spaces within the exposure.
            .filter { !$0.isEmpty }.joined(separator: String(repeating: "\u{2003}", count: 3))
    }

    static func shutter(_ seconds: Double) -> String {
        if seconds >= 0.3 { return "\(trimmed(seconds))S" }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    private static func trimmed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    /// Read from the file's metadata, without decoding the photograph.
    nonisolated static func read(_ url: URL) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let found = PhotoExif(
            make: text(tiff[kCGImagePropertyTIFFMake]),
            model: text(tiff[kCGImagePropertyTIFFModel]),
            lens: text(exif[kCGImagePropertyExifLensModel]),
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue,
            exposure: (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
            aperture: (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
            focalLength: (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue,
            taken: text(exif[kCGImagePropertyExifDateTimeOriginal])
        )
        return found.isEmpty ? nil : found
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The film's edge print: its font and colour, for anything printed like it.
enum EdgePrint {
    static let fontName = "BarlowCondensed-SemiBold"
    /// A lighter cut, for names read at a larger size.
    static let mediumFontName = "BarlowCondensed-Medium"
    static let colour = NSColor(srgbRed: 0.97, green: 0.63, blue: 0.2, alpha: 1)
    /// The app's accent, everywhere: amber on black.
    static let amber = Color(nsColor: colour)

    /// Makes the bundled fonts available to this process. Once is enough.
    static func registerFont(data: URL) {
        for name in [fontName, mediumFontName] {
            let url = data.appendingPathComponent("fonts/\(name).ttf") as CFURL
            CTFontManagerRegisterFontsForURL(url, .process, nil)
        }
    }

    /// The lighter cut, or the edge print's own font if it's missing.
    static func mediumFont(size: CGFloat) -> NSFont {
        NSFont(name: mediumFontName, size: size) ?? font(size: size)
    }

    /// The edge print's font, or a condensed system one if the font is missing.
    static func font(size: CGFloat) -> NSFont {
        if let font = NSFont(name: fontName, size: size) { return font }
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        let condensed = system.fontDescriptor.withSymbolicTraits(.condensed)
        return NSFont(descriptor: condensed, size: size) ?? system
    }
}
