import AppKit
import SwiftUI

/// AppKit runs the application, menus, window, and toolbar; the canvas and
/// inspector inside the window are SwiftUI. A SwiftUI scene with the same
/// toolbar and inspector took about twice as long to show the window
/// (docs/native-macos-ui.md, Startup).
@main enum NegsMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = ApplicationDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = EditorModel()
    let updates = UpdateController()
    private let sessions = SessionStore()
    private var menu: MainMenu?
    private var editor: EditorWindowController?
    private var terminating = false
    private var removingAppData = false
    private var appDataRemovalFinished = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The helper starts while AppKit builds the window, and the cached
        // catalog fills in the inspector's first frame. With that catalog the
        // session restores before the window is built, so its saved frame and
        // adjustments are in the window's first frames; the main actor's tasks
        // only run after AppKit's launch passes. Without a cached catalog, or
        // if the session isn't read within 0.1 s, it restores once the helper
        // answers and reports any error then. Benchmarks and explicit
        // launches must not reopen a previous photograph.
        model.launch()
        let benchmark = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] != nil
        var store: SessionStore? = benchmark ? nil : sessions
        #if SPEKTRAFILM_BENCHMARK
        if let path = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_SESSION"] {
            store = SessionStore(file: URL(fileURLWithPath: path))
        }
        #endif
        var restoration: Task<EditorSession?, Error>?
        if let store, Self.pathArgument != nil || !(Self.readSession(store, timeout: 0.1).map(model.restoreAtLaunch) ?? false) {
            restoration = Task { try await store.load() }
        }
        Task { await model.start(restoration: restoration) }
        menu = MainMenu(model: model, updates: updates) { [weak self] in self?.removeAllAppData() }
        NSApp.mainMenu = menu?.menu
        editor = EditorWindowController(model: model)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // The saved frame has usually been read while AppKit built the
        // window; waiting briefly puts it in the window's first frame. A
        // Finder open may have undone the restore that titled the window.
        model.finishLaunching(waitingUpTo: 0.15)
        editor?.refresh()
        editor?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Finder opens arrive through application(_:open:); a path argument is for `swift run`.
        if let path = Self.pathArgument { model.open(URL(fileURLWithPath: path)) }
        #if SPEKTRAFILM_BENCHMARK
        InteractionBenchmark.start(model)
        StockPreviewBenchmark.start(model)
        #endif
        updates.schedule(afterStartupOf: model)
    }
    /// The session, read on another thread and waited for at most `timeout`,
    /// so a photograph on an unresponsive volume never holds up launch. Nil
    /// if there's none, it can't be read, or it takes longer.
    private static func readSession(_ store: SessionStore, timeout: TimeInterval) -> EditorSession? {
        final class Result: @unchecked Sendable { var session: EditorSession? }
        let result = Result(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.session = try? store.read()
            done.signal()
        }
        // The semaphore orders the write before this read.
        return done.wait(timeout: .now() + timeout) == .success ? result.session : nil
    }
    private static var pathArgument: String? {
        CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: \.isFileURL) { model.open(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cleanup intentionally discards the session. Never recreate it here.
        if removingAppData { return appDataRemovalFinished ? .terminateNow : .terminateCancel }
        guard !terminating else { return .terminateLater }
        if model.saving || (updates.installing && model.exporting) { return .terminateCancel }
        if model.exporting {
            let alert = NSAlert()
            alert.messageText = "An export is still in progress."
            alert.informativeText = "Quitting cancels it. Any existing file at the destination is left unchanged."
            alert.addButton(withTitle: "Continue Exporting")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        // Save once at quit/relaunch, not on slider changes or the rendering path.
        // A failed write cancels termination instead of silently losing the edit.
        guard let session = model.session,
              ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_PHOTO"] == nil else { return .terminateNow }
        terminating = true
        Task {
            do {
                try await sessions.save(session)
                await model.flushPreviewCache()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
                model.error = "Could not save the editing session. Negs stayed open. \(error.localizedDescription)"
            }
        }
        return .terminateLater
    }

    private func removeAllAppData() {
        guard !removingAppData, !terminating, !model.saving, !model.exporting, !updates.installing, !updates.sessionInProgress else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove all Negs app data and quit?"
        alert.informativeText = "This removes your settings, presets, saved editing session, recent-file history, and caches. Your current adjustments will be discarded. Original photographs and exported images are kept.\n\nNegs remains installed. You can move it to the Trash after it quits."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove App Data and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        removingAppData = true
        updates.stopForAppDataRemoval()
        editor?.prepareForAppDataRemoval()
        menu?.prepareForAppDataRemoval()
        model.shutdown()
        Task {
            await model.flushPreviewCache()
            // Wait for an in-flight startup load before deleting session files.
            await sessions.finishPendingIO()
            let locations = AppDataLocations.current
            while true {
                NSDocumentController.shared.clearRecentDocuments(nil)
                var failures = await Task.detached(priority: .userInitiated) { AppDataCleaner.removeFiles(at: locations) }.value
                if !AppDataCleaner.removePreferences(domain: locations.preferencesDomain) {
                    failures.append("The saved preferences could not be cleared.")
                }
                if failures.isEmpty { break }
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = "Some app data could not be removed."
                failed.informativeText = failures.joined(separator: "\n\n")
                failed.addButton(withTitle: "Retry")
                failed.addButton(withTitle: "Quit")
                if failed.runModal() != .alertFirstButtonReturn { break }
            }
            appDataRemovalFinished = true
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { updates.stop(); model.shutdown() }
}

/// The window's main column: the zones and the photograph with its drop target,
/// the film roll under them, and the status bar.
struct EditorCanvas: View {
    let model: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.gridVisible, let source = model.source {
                PhotoGrid(model: model, directory: source.deletingLastPathComponent())
                    // A scroll view runs its rows up under the transparent title bar otherwise.
                    .clipped()
            } else {
                CanvasArea(model: model)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, url.isFileURL else { return false }
                        model.open(url); return true
                    } isTargeted: { dropTargeted = $0 }
                    .overlay {
                        if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(EdgePrint.amber, lineWidth: 3).allowsHitTesting(false).padding(4) }
                    }
                if model.filmstripVisible, !model.imageOnly, let source = model.source {
                    PhotoBrowser(model: model, directory: source.deletingLastPathComponent())
                }
            }
            if !model.imageOnly, model.source != nil || model.exporting || (!model.status.isEmpty && model.status != "Starting…") {
                EdgeLine(horizontal: true)
                StatusBar(model: model)
            }
        }
        // With nothing else showing, the photograph centres in the whole window.
        .ignoresSafeArea(edges: model.imageOnly ? .top : [])
        // Under the toolbar too, which the content otherwise stops short of.
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        // Only under a title bar, so not in full screen.
        .overlay(alignment: .top) { if !model.windowFullScreen && !model.imageOnly { EdgeLine(horizontal: true) } }
        .alert("Negs", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

/// The 1-point line between the window's regions: under the toolbar and down
/// the sidebar's left edge.
struct EdgeLine: View {
    let horizontal: Bool

    var body: some View {
        Rectangle()
            .fill(EdgePrint.amber.opacity(0.35))
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// The inspector column: the adjustments, or the crop panel while cropping.
struct InspectorPanel: View {
    let model: EditorModel
    /// False until the window is on screen; see EditorWindowController.
    var built = true

    var body: some View {
        Group {
            if !built { Color.clear }
            else if let session = model.cropSession { CropInspector(model: model, session: session) }
            else {
                VStack(spacing: 0) {
                    PaneSwitch(model: model)
                    if model.inspectorPane == .presets { PresetInspector(model: model) }
                    else { AdjustmentInspector(model: model) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        // Black, whatever the viewer's colour, with amber on it throughout.
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(Ink.label)
        .tint(EdgePrint.amber)
        // Amber on black needs dark controls, whatever the system's set to.
        .environment(\.colorScheme, .dark)
        // The edge the film strip has on top, down the left.
        .overlay(alignment: .leading) { EdgeLine(horizontal: false) }
        // The line under the title bar, which continues the canvas's.
        .overlay(alignment: .top) { if !model.windowFullScreen { EdgeLine(horizontal: true) } }
    }
}

/// Swaps the sidebar between the adjustments and the presets.
struct PaneSwitch: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            ForEach([(InspectorPane.adjustments, "Adjustments"), (.presets, "Presets")], id: \.1) { pane, title in
                let selected = model.inspectorPane == pane
                Button { model.showPane(pane) } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Ink.paper : Ink.dim)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if model.inspectorPane == .adjustments, model.cropSession == nil {
                HiddenPartsEye()
                let edits = model.editCount
                if edits > 0 {
                    (Text("\(edits)").foregroundStyle(Ink.amber) + Text(edits == 1 ? " edit" : " edits").foregroundStyle(Ink.dim))
                        .font(.system(size: 11)).monospacedDigit()
                    Button("Reset", action: model.reset)
                        .buttonStyle(InkButtonStyle())
                        .help("Restore defaults on every tab while keeping the film, paper, rotation, crop, border, and Image Size. You can undo this.")
                }
            }
        }
        .padding(.horizontal, InkLayout.gutter)
        .frame(height: 40)
    }
}

/// Reads only the preview state, so edits don't re-evaluate the canvas.
struct CanvasArea: View {
    let model: EditorModel
    /// Settings › Viewer background.
    @AppStorage(ViewerBackground.customKey) private var customBackground = false
    @AppStorage(ViewerBackground.colorKey) private var backgroundHex = ViewerBackground.defaultHex

    var body: some View {
        ZStack {
            ViewerBackground.canvas(custom: customBackground, hex: backgroundHex)
            if let session = model.cropSession, let image = model.image {
                CropEditor(session: session, image: image)
            } else if let image = model.image {
                canvas(model.original ?? image, size: model.imageSize, rotation: model.imageRotation)
            } else if let placeholder = model.placeholder {
                canvas(placeholder, size: model.placeholderSize, rotation: model.imageRotation)
            } else if model.source == nil {
                EmptyState(model: model)
            }
        }
        .overlay(alignment: .top) { ActivityBadge(model: model) }
    }

    private func canvas(_ image: AnyObject, size: CGSize, rotation: Int) -> some View {
        PreviewCanvas(image: image, size: size, rotation: rotation, crop: model.crop, border: model.border.shown(for: model.crop.size(of: size)), filmTexture: model.filmTexture,
                      filmStrip: model.filmStrip, zoomCommand: model.zoomCommand, fit: model.fitImage, scale: model.canvasScale,
                      proofPixels: model.exportPixels,
                      zoomSteps: model.canvasZoomSteps,
                      exif: model.photoExif,
                      fileName: model.imageOnly ? nil : model.source?.lastPathComponent,
                      onPickWhiteBalance: { a, b in model.pickWhiteBalance(from: a, to: b) },
                      onPickZone: { a, b in model.pickZone(from: a, to: b) },
                      onEscapeKey: { model.clearZoneReading() },
                      onFitChanged: { model.fitImage = $0 })
    }
}

struct ActivityBadge: View {
    let model: EditorModel

    private var title: String? {
        if model.original != nil { return "Original" }
        if model.holdingOriginal { return "Loading Original" }
        guard model.source != nil, !model.renderFailed else { return nil }
        if model.image == nil { return "Developing" }
        return model.showsActivity ? "Updating" : nil
    }

    var body: some View {
        ZStack {
            if let title {
                let shown = model.original != nil
                Label(title, systemImage: model.holdingOriginal ? "square.split.diagonal.fill" : "camera.aperture")
                    .symbolEffect(.pulse, options: .repeating, isActive: !shown)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator))
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: title)
        .allowsHitTesting(false)
    }
}

struct EmptyState: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            Text("Open a Photograph").font(.title2.weight(.semibold))
            Text("Explore film stocks, shape the print, and make it your own.").foregroundStyle(.secondary)
            Button("Open Photograph…", action: model.openPanel).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
            Text("Or drop a RAW, TIFF, PNG, or JPEG file here").font(.caption).foregroundStyle(.tertiary)
            if !model.recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.recentFiles.prefix(5), id: \.self) { url in
                        Button { model.open(url) } label: { Label(url.lastPathComponent, systemImage: "photo") }
                            .buttonStyle(.link).help(url.path)
                    }
                }.padding(.top, 18)
            }
        }
        .multilineTextAlignment(.center)
        .padding(30)
    }
}

struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            if let caption = model.fullScreenCaption {
                Text(caption).lineLimit(1).truncationMode(.middle).fontWeight(.semibold)
            }
            if model.gridVisible {
                Text(verbatim: "\(model.gridSelection.count) selected · ⌘-click to add to the selection").lineLimit(1)
            } else if let reading = model.zoneReading, !model.cropping {
                ZoneReadingLine(reading: reading)
            } else {
                Text(model.status).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            // Only while the grid's waiting on it: otherwise it's quietly behind the scenes.
            if model.gridVisible, let roll = model.rollDeveloper, roll.isDeveloping {
                ProgressView().controlSize(.mini)
                Text("Developing · \(roll.finished) of \(roll.total)").monospacedDigit()
            }
            if model.exporting {
                ProgressView().controlSize(.mini)
                TimelineView(.periodic(from: model.exportStarted, by: 1)) { context in
                    Text("Exporting · \(Int(context.date.timeIntervalSince(model.exportStarted))) s").monospacedDigit()
                }
                Button("Cancel", action: model.cancelExport).controlSize(.small)
            }
            if model.gridVisible {
                ThumbnailSizeSlider(model: model)
            } else if model.source != nil {
                if model.canZoom {
                    StatusButton(title: "Fit", on: model.fitImage, help: "Fit the photograph in the window") { model.zoom(fit: true) }
                    StatusButton(title: "100%", on: !model.fitImage, help: "Show the photograph at its export size") { model.zoom(fit: false) }
                }
                OriginalButton(model: model)
            }
        }
        .font(.system(size: 11)).foregroundStyle(Ink.dim)
        .padding(.horizontal, 14).frame(height: 28)
        .background(Color.black)
        .accessibilityElement(children: .contain)
    }
}

/// A quiet text button in the status bar; amber when its state is on.
private struct StatusButton: View {
    let title: String
    var on = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11))
                .foregroundStyle(on ? Ink.amber : Ink.label)
                .padding(.horizontal, 6).frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What the ⌃-picked area reads, and how to place it.
private struct ZoneReadingLine: View {
    let reading: ZoneReading

    var body: some View {
        if let printed = reading.printed, let zone = reading.zone {
            Text(verbatim: "Reading in zone \(ZoneScale.zones[zone].numeral), L* \(Int(printed.rounded()))")
                .monospacedDigit().fontWeight(.semibold).foregroundStyle(Ink.paper).lineLimit(1)
            Text("Click a zone or press 0–7 to place it there, with ⇧ for the middle of the zone · Esc to clear")
                .foregroundStyle(Ink.amber).lineLimit(1).truncationMode(.tail)
        } else {
            Text("Reading…").foregroundStyle(Ink.amber)
        }
    }
}

/// How large the grid's thumbnails are: fewer columns, larger.
private struct ThumbnailSizeSlider: View {
    let model: EditorModel

    var body: some View {
        let range = EditorModel.gridColumnRange
        Text("Thumbnail size")
        Slider(value: Binding(get: { Double(range.lowerBound + range.upperBound - model.gridColumns) },
                              set: { model.gridColumns = range.lowerBound + range.upperBound - Int($0.rounded()) }),
               in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            .labelsHidden().controlSize(.mini).frame(width: 100)
            .accessibilityLabel("Thumbnail size")
    }
}

/// Grid or Photo, in the title bar.
struct ViewSwitch: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            option("Grid", selected: model.gridVisible)
            option("Photo", selected: !model.gridVisible)
        }
        .padding(.trailing, 8)
        .frame(height: 28)
        .environment(\.colorScheme, .dark)
    }

    private func option(_ title: String, selected: Bool) -> some View {
        Button { if !selected { model.toggleGrid() } } label: {
            Text(title).font(.system(size: 12))
                .foregroundStyle(selected ? Ink.amber : Ink.label)
                .padding(.horizontal, 10).frame(height: 24)
                .background(selected ? Ink.well : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.source == nil || model.cropping)
        .opacity(model.source == nil ? 0.5 : 1)
        .help(title == "Grid" ? "Every photograph in the folder (G)" : "The open photograph (G)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Press and hold to compare with the photograph before developing, like
/// Lightroom's Show Original. The decode starts when the pointer arrives.
struct OriginalButton: View {
    let model: EditorModel
    @State private var pressed = false

    var body: some View {
        let enabled = model.canShowOriginal
        Image(systemName: "square.split.diagonal.fill")
            .font(.system(size: 13))
            .foregroundStyle(model.original != nil ? AnyShapeStyle(EdgePrint.amber) : AnyShapeStyle(EdgePrint.amber.opacity(0.6)))
            .frame(width: 24, height: 20)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onHover { if $0 { model.prepareOriginal() } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; model.holdOriginal(true) } }
                .onEnded { _ in pressed = false; model.holdOriginal(false) })
            .allowsHitTesting(enabled)
            .help("Hold to show the original (\\)")
            .accessibilityElement()
            .accessibilityLabel("Show Original")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(model.original != nil ? "On" : "Off")
            // VoiceOver can't hold, so activating it toggles.
            .accessibilityAction { model.holdOriginal(!model.holdingOriginal) }
    }
}
