import AppKit
import Observation
import SwiftUI

/// End field editing even when the clicked view doesn't take keyboard focus.
@MainActor final class EditorWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        commitFieldEditing(in: self, before: event)
        super.sendEvent(event)
    }
}

/// The editing window: a unified toolbar over the canvas, with the sidebar and
/// the zone bar floating in their own panels over it. The windows and toolbar
/// are AppKit; the canvas and panels' contents are SwiftUI. They follow the model through
/// Observation, like the views.
@MainActor final class EditorWindowController: NSWindowController, NSToolbarDelegate {
    private let model: EditorModel
    private let panel: NSHostingController<InspectorPanel>
    let sidebar: FloatingPanel
    let zoneBar: FloatingPanel
    /// How far the user has moved each panel from its usual place.
    private var sidebarOffset = CGVector.zero
    private var zoneBarOffset = CGVector.zero
    private var windowObservers: [NSObjectProtocol] = []
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private lazy var cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop))
    private lazy var doneButton = NSButton(title: "Done", target: self, action: #selector(applyCrop))
    private var appearing: NSObjectProtocol?
    private var resigning: NSObjectProtocol?
    private var keyMonitor: Any?
    /// The key held to show the original, so its release is found even if
    /// a modifier (⌥⇧ on some layouts) was let go first.
    private var originalKey: UInt16?

    init(model: EditorModel) {
        self.model = model
        // The windows size the content, so SwiftUI never measures it for their limits.
        let canvas = NSHostingController(rootView: EditorCanvas(model: model))
        canvas.sizingOptions = []
        // The adjustments take about a third of the time to the first frame,
        // so the panel starts empty and fills in once the window is on screen.
        panel = NSHostingController(rootView: InspectorPanel(model: model, built: false))
        panel.sizingOptions = []
        panel.view.frame.size = NSSize(width: FloatingLayout.sidebarWidth, height: 860)
        sidebar = FloatingPanel(content: panel)
        let bar = NSHostingController(rootView: ZonePanel(model: model))
        bar.sizingOptions = []
        bar.view.frame.size = NSSize(width: ZoneGeometry.barWidth, height: ZoneGeometry.barHeight)
        zoneBar = FloatingPanel(content: bar)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Negs"
        window.toolbarStyle = .unified
        window.isRestorable = false
        // Place the window before adding its content, so the first layout is at the final size.
        if !window.setFrameUsingName("editor") { window.center() }
        // The canvas stays usable beside the sidebar's margin.
        let minimum = NSSize(width: 680 + FloatingLayout.gutter, height: 560)
        window.contentMinSize = minimum
        let restored = window.contentRect(forFrameRect: window.frame).size
        if restored.width < minimum.width || restored.height < minimum.height {
            window.setContentSize(NSSize(width: max(restored.width, minimum.width),
                                         height: max(restored.height, minimum.height)))
        }
        canvas.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = canvas
        window.setFrameAutosaveName("editor")
        super.init(window: window)
        shouldCascadeWindows = false

        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // The view/edit controls lead from the left; the actions group trails.
        window.toolbar = toolbar
        model.undoManager = window.undoManager
        appearing = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowChangedOcclusion() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.holdOriginal(event) || self.togglePins(event) || self.toggleProofKey(event)
            } ? nil : event
        }
        sidebar.onUserMove = { [weak self] in
            guard let self, let content = self.contentOnScreen else { return }
            let home = FloatingLayout.sidebar(in: content, offset: .zero)
            self.sidebarOffset = CGVector(dx: self.sidebar.frame.minX - home.minX, dy: self.sidebar.frame.minY - home.minY)
        }
        zoneBar.onUserMove = { [weak self] in
            guard let self, let content = self.contentOnScreen else { return }
            let home = FloatingLayout.zoneBar(in: content, sidebarVisible: self.model.inspectorVisible, offset: .zero)
            self.zoneBarOffset = CGVector(dx: self.zoneBar.frame.minX - home.minX, dy: self.zoneBar.frame.minY - home.minY)
        }
        let center = NotificationCenter.default
        // The panels follow the window's size and whether it's on screen.
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPanels() }
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanels() }
        })
        // The lines follow the bar while it's dragged.
        windowObservers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: zoneBar, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishZoneBar() }
        })
        resigning = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.originalKey != nil else { return }
                self.originalKey = nil; self.model.holdOriginal(false)
            }
        }
        observe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Prevent window closure during data removal from restoring preferences.
    func prepareForAppDataRemoval() {
        window?.setFrameAutosaveName("")
        hidePanels()
        window?.orderOut(nil)
    }

    // MARK: Panels

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        syncPanels()
    }

    private var contentOnScreen: CGRect? {
        window.map { $0.convertToScreen($0.contentLayoutRect) }
    }

    /// Shows the panels that should be up, each in its place. They join the
    /// window only once it's on screen, or they would appear without it.
    private func syncPanels() {
        guard let window, window.isVisible, let content = contentOnScreen else { return }
        let sidebarFrame = FloatingLayout.sidebar(in: content, offset: sidebarOffset)
        let barFrame = FloatingLayout.zoneBar(in: content, sidebarVisible: model.inspectorVisible, offset: zoneBarOffset)
        for (panel, frame, shown) in [(sidebar, sidebarFrame, model.inspectorVisible), (zoneBar, barFrame, model.showsZonePanel)] {
            if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
            if shown, panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
            } else if !shown, panel.parent != nil {
                window.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
        publishZoneBar()
    }

    private func hidePanels() {
        for panel in [sidebar, zoneBar] where panel.parent != nil {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        publishZoneBar()
    }

    /// Tells the canvas where the bar is, for its lines and drags.
    private func publishZoneBar() {
        model.canvasScale.zoneBarFrame = zoneBar.parent == nil ? nil : zoneBar.frame
        model.canvasScale.view?.overlay.redraw()
    }

    // MARK: State

    private func windowChangedOcclusion() {
        guard let window, window.occlusionState.contains(.visible), let appearing else { return }
        NotificationCenter.default.removeObserver(appearing)
        self.appearing = nil
        panel.rootView = InspectorPanel(model: model)
    }

    /// Holding \ shows the original, as in Lightroom, unless text is being
    /// typed. True if the event was handled.
    /// Whether a key press is the bare P that turns the proof on or off.
    static func togglesProof(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> Bool {
        keyCode == 35 && modifiers.isDisjoint(with: [.shift, .control, .option, .command]) && !(firstResponder is NSText)
    }

    private func toggleProofKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isOurs(event.window), model.source != nil, !model.cropping,
              Self.togglesProof(keyCode: event.keyCode, modifiers: event.modifierFlags, firstResponder: event.window?.firstResponder)
        else { return false }
        if !event.isARepeat { model.proofing.toggle() }
        return true
    }

    /// Whether a key press is the bare Tab that shows or hides the pins. It stands
    /// down while a field is being edited, so Tab still moves between fields.
    static func togglesPins(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> Bool {
        keyCode == 48 && modifiers.isDisjoint(with: [.shift, .control, .option, .command]) && !(firstResponder is NSText)
    }

    /// Handled here rather than by the menu alone, because Tab otherwise moves
    /// the keyboard focus before a menu shortcut sees it. True if it was Tab.
    private func togglePins(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isOurs(event.window), model.source != nil, !model.cropping,
              Self.togglesPins(keyCode: event.keyCode, modifiers: event.modifierFlags, firstResponder: event.window?.firstResponder)
        else { return false }
        if !event.isARepeat { model.pinsVisible.toggle() }
        return true
    }

    /// The editing window or one of its panels, which can hold the keyboard after typing.
    private func isOurs(_ other: NSWindow?) -> Bool { other != nil && (other === window || other === sidebar || other === zoneBar) }

    private func holdOriginal(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            guard event.keyCode == originalKey else { return false }
            originalKey = nil; model.holdOriginal(false)
            return true
        }
        guard isOurs(event.window), event.characters == "\\",
              event.modifierFlags.isDisjoint(with: [.command, .control]),
              !(event.window?.firstResponder is NSText) else { return false }
        if !event.isARepeat { originalKey = event.keyCode; model.holdOriginal(true) }
        return true
    }

    /// Applies the model now rather than on the next observation pass, which
    /// at launch runs only after the window is on screen.
    func refresh() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            update()
        }
    }

    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        guard let window else { return }
        _ = (model.inspectorVisible, model.showsZonePanel)
        syncPanels()
        let photo = model.source != nil
        window.title = model.source?.lastPathComponent ?? "Negs"
        window.subtitle = !photo || !model.ready ? "" : model.value("io.scan_film").bool ? model.filmName : "\(model.filmName) → \(model.paperName)"
        showCropActions(model.cropping)
        if let item = items[.filmstrip] {
            item.toolTip = model.filmstripVisible ? "Hide film strip (⌥⌘F)" : "Show film strip (⌥⌘F)"
            let icon = symbol("rectangle.bottomthird.inset.filled", "Film Strip")
            item.image = model.filmstripVisible
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : icon
        }
        if let item = items[.zones] {
            item.toolTip = model.pinsVisible ? "Hide the pins and lines (Tab)" : "Show the pins and lines (Tab)"
            let icon = symbol("circle.lefthalf.filled", "Pins")
            item.image = model.pinsVisible
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : icon
        }
        setEnabled(.zones, photo && !model.cropping)
        if let item = items[.proof] {
            item.toolTip = model.proofing ? "Stop proofing (P)" : "Proof at the export size (P)"
            let icon = symbol("photo.artframe", "Proof")
            item.image = model.proofing
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : icon
        }
        setEnabled(.proof, photo && !model.cropping)
        setEnabled(.fit, model.canZoom)
        setEnabled(.actualSize, model.canZoom)
        setEnabled(.rotate, photo)
        setEnabled(.crop, model.image != nil)
        if let crop = items[.crop] {
            crop.toolTip = model.cropping ? "Apply the crop (⌘K)" : "Crop the photograph (⌘K)"
            // The accent color marks crop mode as on.
            crop.image = model.cropping
                ? symbol("crop", "Crop").withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
                : symbol("crop", "Crop")
        }
        setEnabled(.export, photo && model.ready && !model.exporting && !model.saving && !model.cropping)
        // The accent color marks the pane the sidebar shows.
        for (id, pane, name, label) in [(NSToolbarItem.Identifier.adjustments, InspectorPane.adjustments, "slider.horizontal.3", "Adjustments"),
                                        (.presets, .presets, "square.stack", "Presets")] {
            let icon = symbol(name, label)
            items[id]?.image = model.inspectorVisible && model.inspectorPane == pane
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : icon
        }
        // A ratio field being edited keeps its own Return and Escape.
        if let session = model.cropSession {
            cancelButton.keyEquivalent = session.typing ? "" : "\u{1b}"
            doneButton.keyEquivalent = session.typing ? "" : "\r"
        }
    }

    private func setEnabled(_ id: NSToolbarItem.Identifier, _ enabled: Bool) {
        guard let item = items[id] else { return }
        item.isEnabled = enabled
        (item as? NSToolbarItemGroup)?.subitems.forEach { $0.isEnabled = enabled }
    }

    /// While cropping, Cancel and Done sit beside the actions group and Export
    /// is disabled there; the group itself keeps its rounded capsule.
    private func showCropActions(_ cropping: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let ids = toolbar.items.map(\.itemIdentifier)
        if cropping, !ids.contains(.doneCrop), let i = ids.firstIndex(of: .actions) {
            toolbar.insertItem(withItemIdentifier: .doneCrop, at: i + 1)
            toolbar.insertItem(withItemIdentifier: .cancelCrop, at: i + 1)
        } else if !cropping, let i = ids.firstIndex(of: .cancelCrop) {
            toolbar.removeItem(at: i + 1)
            toolbar.removeItem(at: i)
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.controls, .flexibleSpace, .actions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.cancelCrop, .doneCrop]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .controls:
            // Native rounded toolbar group: open, film strip and the view/edit
            // controls share one capsule, as in Photos.
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [button(.open, "Open", "folder", "Open photograph (⌘O)", #selector(openPhotograph)),
                              button(.filmstrip, "Film Strip", "rectangle.bottomthird.inset.filled", "Show or hide film strip (⌥⌘F)", #selector(toggleFilmstrip)),
                              button(.zones, "Pins", "circle.lefthalf.filled", "Show or hide the pins and lines (Tab)", #selector(toggleZones)),
                              button(.proof, "Proof", "photo.artframe", "Proof at the export size (P)", #selector(toggleProofButton)),
                              button(.fit, "Fit", "arrow.down.right.and.arrow.up.left", "Fit photograph (⌘0)", #selector(fit)),
                              button(.actualSize, "Actual Size", "1.magnifyingglass", "Actual size (⌘1)", #selector(actualSize)),
                              button(.rotate, "Rotate", "rotate.right", "Rotate clockwise (⌘R)", #selector(rotateClockwise)),
                              button(.crop, "Crop", "crop", "Crop the photograph (⌘K)", #selector(toggleCrop))]
            group.label = "View"
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
            item = group
        case .actions:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [button(.export, "Export", "square.and.arrow.down", "Export photograph (⇧⌘E)", #selector(export)),
                              button(.presets, "Presets", "square.stack", "Show or hide presets (⌥⌘P)", #selector(togglePresets)),
                              button(.adjustments, "Adjustments", "slider.horizontal.3", "Show or hide adjustments (⌥⌘I)", #selector(toggleAdjustments))]
            group.label = "Actions"
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
            item = group
        case .cancelCrop:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = cancelButton; item.label = "Cancel"; item.toolTip = "Discard the crop (Esc)"
        case .doneCrop:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = doneButton; item.label = "Done"; item.toolTip = "Apply the crop (Return)"
            // The confirming action is filled with the accent color. The style
            // needs the macOS 26 SDK, which release CI's Xcode 16 lacks.
            #if compiler(>=6.2)
            if #available(macOS 26, *) { item.style = .prominent } else { doneButton.bezelColor = .controlAccentColor }
            #else
            doneButton.bezelColor = .controlAccentColor
            #endif
        default:
            return nil
        }
        // Enabled from the model's state in update(), not by validation.
        item.autovalidates = false
        (item as? NSToolbarItemGroup)?.subitems.forEach { $0.autovalidates = false }
        items[id] = item
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbolName: String, _ help: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.image = symbol(symbolName, label)
        item.toolTip = help
        item.isBordered = true
        item.target = self
        item.action = action
        // A group's subitems are not returned to `toolbar(_:itemForItemIdentifier:)`
        // by identifier, so keep them for enabled-state and icon updates.
        items[id] = item
        return item
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    // MARK: Actions

    @objc private func openPhotograph() { model.openPanel() }
    @objc private func fit() { model.zoom(fit: true) }
    @objc private func actualSize() { model.zoom(fit: false) }
    @objc private func rotateClockwise() { model.rotate() }
    @objc private func toggleCrop() { model.cropping ? model.endCrop(apply: true) : model.beginCrop() }
    @objc private func cancelCrop() { model.endCrop(apply: false) }
    @objc private func applyCrop() { model.endCrop(apply: true) }
    @objc private func export() { model.savePanel(export: true) }
    @objc private func toggleFilmstrip() { model.filmstripVisible.toggle() }
    @objc private func toggleZones() { model.pinsVisible.toggle() }
    @objc private func toggleProofButton() { model.proofing.toggle() }
    @objc private func toggleAdjustments() { model.togglePane(.adjustments) }
    @objc private func togglePresets() { model.togglePane(.presets) }
}

private extension NSToolbarItem.Identifier {
    static let controls = Self("controls"), actions = Self("actions")
    static let filmstrip = Self("filmstrip"), open = Self("open"), zones = Self("zones"), proof = Self("proof")
    static let fit = Self("fit"), actualSize = Self("actualSize"), rotate = Self("rotate"), crop = Self("crop")
    static let export = Self("export"), adjustments = Self("adjustments"), presets = Self("presets"), cancelCrop = Self("cancelCrop"), doneCrop = Self("doneCrop")
}
