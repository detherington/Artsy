import AppKit
import Combine
import MetalKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    var metalContext: MetalContext!
    private var tabCounter = 0
    private var distractionFreeWindow: NSWindow?
    private var distractionFreeCanvasView: CanvasView?
    private var savedWindowFrame: NSRect?
    private var newCanvasPanel: NSPanel?
    /// Keeps `viewModel.isDirty` → `window.isDocumentEdited` bindings alive per window.
    private var dirtyObservations: [ObjectIdentifier: AnyCancellable] = [:]
    /// Sparkle updater — starts checking on launch, exposes "Check for Updates…" action.
    private lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenuBar()
        _ = updaterController // instantiate → starts background update checks

        do {
            metalContext = try MetalContext()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to initialize Metal"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSWindow.allowsAutomaticWindowTabbing = true

        NotificationCenter.default.addObserver(self, selector: #selector(handleEnterDistractionFree), name: .enterDistractionFree, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleExitDistractionFree), name: .exitDistractionFree, object: nil)

        // Global Escape key monitor for distraction-free exit
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.distractionFreeWindow != nil {
                self?.exitDistractionFree()
                return nil
            }
            return event
        }

        // Global tablet proximity monitor — catches pen/eraser flips
        NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { event in
            TabletEventHandler.handleProximity(event: event)

            // Notify active canvas views to update their brush
            NotificationCenter.default.post(name: .tabletProximityChanged, object: nil)
            return event
        }

        // If files were queued for opening (double-click launch), open them
        // Otherwise show new canvas dialog (or skip if user prefers to use defaults)
        if !pendingOpenURLs.isEmpty {
            processPendingOpens()
        } else if AppPreferences.shared.skipNewCanvasDialog {
            createNewCanvas(size: AppPreferences.shared.defaultCanvasSize)
        } else {
            showNewCanvasDialog()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showNewCanvasDialog() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "New Canvas"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()

        let hostView = NSHostingView(rootView: NewCanvasView(
            onCreate: { [weak self] size in
                panel.close()
                self?.newCanvasPanel = nil
                self?.createNewCanvas(size: size)
            },
            onOpen: { [weak self] in
                self?.isOpeningFile = true
                panel.close()
                DispatchQueue.main.async {
                    self?.newCanvasPanel = nil
                    self?.handleOpen()
                }
            },
            onCancel: { [weak self] in
                panel.close()
                self?.newCanvasPanel = nil
            }
        ))
        panel.contentView = hostView
        self.newCanvasPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func createNewCanvas(size: CGSize) {
        tabCounter += 1
        let title = "Canvas \(tabCounter)"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 800, height: 500)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false

        do {
            let viewModel = CanvasViewModel(canvasSize: size)
            let canvasView = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: metalContext.device)
            try canvasView.configure(context: metalContext, viewModel: viewModel)

            let contentView = buildLayout(canvasView: canvasView, viewModel: viewModel)
            window.contentView = contentView

            // Store references on the window for menu actions
            window.representedURL = nil
            CanvasWindowStore.shared.register(window: window, viewModel: viewModel, canvasView: canvasView)
            observeDirty(window: window, viewModel: viewModel)

        } catch {
            let label = NSTextField(labelWithString: "Canvas creation failed:\n\(error.localizedDescription)")
            label.alignment = .center
            window.contentView = label
        }

        // Always set the tabbing identifier
        window.tabbingIdentifier = "ArtsyCanvas"

        // Add tab to the currently active canvas window/group
        let targetWindow = NSApp.keyWindow?.tabbingIdentifier == "ArtsyCanvas" ? NSApp.keyWindow :
            NSApp.windows.first(where: { $0.tabbingIdentifier == "ArtsyCanvas" && $0 != window && $0.isVisible })

        if let target = targetWindow {
            target.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func buildLayout(canvasView: CanvasView, viewModel: CanvasViewModel) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let toolPalette = NSHostingView(rootView: ToolPaletteView(viewModel: viewModel))
        toolPalette.translatesAutoresizingMaskIntoConstraints = false

        let rightPanel = NSHostingView(rootView: RightPanelView(viewModel: viewModel))
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.clipsToBounds = true

        let statusBar = NSHostingView(rootView: StatusBarView(viewModel: viewModel))
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        canvasView.translatesAutoresizingMaskIntoConstraints = false

        // Selection overlay (marching ants) — on top of canvas, click-through
        let selectionOverlay = SelectionOverlayView()
        selectionOverlay.viewModel = viewModel
        selectionOverlay.wantsLayer = true
        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolPalette)
        container.addSubview(canvasView)
        container.addSubview(selectionOverlay, positioned: .above, relativeTo: canvasView)
        container.addSubview(rightPanel)
        container.addSubview(statusBar)

        let rightPanelWidth = rightPanel.widthAnchor.constraint(equalToConstant: 260)

        NSLayoutConstraint.activate([
            toolPalette.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolPalette.topAnchor.constraint(equalTo: container.topAnchor),
            toolPalette.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            toolPalette.widthAnchor.constraint(equalToConstant: 48),

            rightPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: container.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            rightPanelWidth,

            canvasView.leadingAnchor.constraint(equalTo: toolPalette.trailingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            canvasView.topAnchor.constraint(equalTo: container.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Selection overlay: same frame as canvas
            selectionOverlay.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: canvasView.topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

        selectionOverlay.startAnimation()

        // Observe view model's panel visibility toggle
        var observation: NSObjectProtocol?
        observation = NotificationCenter.default.addObserver(
            forName: .rightPanelToggled, object: viewModel, queue: .main
        ) { [weak rightPanel] _ in
            guard let rightPanel = rightPanel else { return }
            let show = viewModel.isRightPanelVisible
            let width: CGFloat
            if !show {
                width = 0
            } else if viewModel.rightPanelMode == .condensed {
                width = 48
            } else {
                width = 260
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                rightPanelWidth.constant = width
                rightPanel.isHidden = !show
                container.layoutSubtreeIfNeeded()
            }
        }
        // Keep observation alive by storing on the container
        objc_setAssociatedObject(container, "panelObserver", observation, .OBJC_ASSOCIATION_RETAIN)

        return container
    }

    private var isOpeningFile = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if isOpeningFile { return false }
        if newCanvasPanel != nil { return false }
        if !pendingOpenURLs.isEmpty { return false }
        return true
    }

    // MARK: - Dirty observation

    /// Bind `viewModel.isDirty` to `window.isDocumentEdited` (close-button dot) AND
    /// prepend a "•" to the window title so the unsaved indicator is visible in the tab bar.
    private func observeDirty(window: NSWindow, viewModel: CanvasViewModel) {
        let id = ObjectIdentifier(window)
        dirtyObservations[id] = viewModel.$isDirty
            .receive(on: RunLoop.main)
            .sink { [weak window] isDirty in
                guard let window = window else { return }
                window.isDocumentEdited = isDirty
                let current = window.title
                let stripped = current.hasPrefix("• ") ? String(current.dropFirst(2)) : current
                window.title = isDirty ? "• " + stripped : stripped
            }
    }

    // MARK: - Quit with unsaved changes

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Gather all canvas windows with dirty state.
        let dirtyWindows = NSApp.windows.compactMap { w -> (window: NSWindow, store: (viewModel: CanvasViewModel, canvasView: CanvasView))? in
            guard w.tabbingIdentifier == "ArtsyCanvas",
                  let store = CanvasWindowStore.shared.get(for: w),
                  store.viewModel.isDirty else { return nil }
            return (w, store)
        }

        guard !dirtyWindows.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        if dirtyWindows.count == 1 {
            let name = dirtyWindows[0].store.viewModel.displayName
            alert.messageText = "Save changes to \"\(name)\" before quitting?"
        } else {
            alert.messageText = "You have \(dirtyWindows.count) canvases with unsaved changes. Save all before quitting?"
        }
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")            // return 1000 — .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")          // return 1001
        alert.addButton(withTitle: "Don't Save")      // return 1002

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Save
            // Save every dirty canvas; if any save is cancelled or fails, abort quit.
            saveAllDirty(dirtyWindows, index: 0) { allSaved in
                NSApp.reply(toApplicationShouldTerminate: allSaved)
            }
            return .terminateLater

        case .alertSecondButtonReturn: // Cancel
            return .terminateCancel

        default: // Don't Save
            return .terminateNow
        }
    }

    /// Sequentially save each dirty canvas. If any fails/cancels, stop and report false.
    private func saveAllDirty(
        _ items: [(window: NSWindow, store: (viewModel: CanvasViewModel, canvasView: CanvasView))],
        index: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if index >= items.count {
            completion(true)
            return
        }
        let item = items[index]
        item.window.makeKeyAndOrderFront(nil)
        saveCanvas(store: item.store, targetWindow: item.window) { [weak self] saved in
            if !saved {
                completion(false)
                return
            }
            self?.saveAllDirty(items, index: index + 1, completion: completion)
        }
    }

    // Queue of files to open if received before Metal is initialized
    private var pendingOpenURLs: [URL] = []

    // Handle double-click opening of .artsy files
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard url.pathExtension == "artsy" else { return false }
        if metalContext != nil {
            openArtsyDocument(at: url)
        } else {
            pendingOpenURLs.append(url)
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if url.pathExtension == "artsy" {
                if metalContext != nil {
                    openArtsyDocument(at: url)
                } else {
                    pendingOpenURLs.append(url)
                }
            }
        }
    }

    private func processPendingOpens() {
        guard metalContext != nil else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in urls {
            openArtsyDocument(at: url)
        }
    }

    private func openArtsyDocument(at url: URL) {
        guard let metalContext = metalContext else {
            NSLog("Artsy: Cannot open document — Metal not initialized")
            return
        }

        // Verify the document exists and has the expected structure
        let fm = FileManager.default
        let docJSON = url.appendingPathComponent("document.json")
        guard fm.fileExists(atPath: docJSON.path) else {
            let alert = NSAlert()
            alert.messageText = "Cannot open file"
            alert.informativeText = "The file does not appear to be a valid .artsy document."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        do {
            // Parse the document metadata first
            let jsonData = try Data(contentsOf: docJSON)
            let doc = try JSONDecoder().decode(CanvasDocument.DocumentData.self, from: jsonData)

            let canvasSize = CGSize(width: doc.canvasWidth, height: doc.canvasHeight)
            let viewModel = CanvasViewModel(canvasSize: canvasSize)

            let canvasView = CanvasView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                device: metalContext.device
            )
            try canvasView.configure(context: metalContext, viewModel: viewModel)

            guard let layerStack = viewModel.layerStack else {
                throw DocumentError.loadFailed
            }

            // Replace default layers with saved ones
            layerStack.layers.removeAll()
            layerStack.activeLayerIndex = 0

            let textureManager = TextureManager(device: metalContext.device)
            let layersDir = url.appendingPathComponent("layers")

            for (i, layerInfo) in doc.layers.enumerated() {
                guard let texture = try? textureManager.makeCanvasTexture(
                    width: doc.canvasWidth, height: doc.canvasHeight, label: layerInfo.name
                ) else { continue }

                let layer = Layer(
                    id: UUID(uuidString: layerInfo.id) ?? UUID(),
                    name: layerInfo.name,
                    texture: texture
                )
                layer.isVisible = layerInfo.isVisible
                layer.isLocked = layerInfo.isLocked
                layer.opacity = layerInfo.opacity
                layer.blendMode = LayerBlendMode(rawValue: layerInfo.blendMode) ?? .normal

                let layerFile = layersDir.appendingPathComponent("layer-\(i).png")
                if fm.fileExists(atPath: layerFile.path),
                   let pngData = try? Data(contentsOf: layerFile),
                   let nsImage = NSImage(data: pngData),
                   let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    CanvasDocument.loadCGImageIntoTexture(cgImage: cgImage, texture: texture, context: metalContext)
                }

                layerStack.layers.append(layer)
            }

            // Ensure at least one layer exists
            if layerStack.layers.isEmpty {
                let fallback = try textureManager.makeCanvasTexture(
                    width: doc.canvasWidth, height: doc.canvasHeight, label: "Layer 1"
                )
                layerStack.layers.append(Layer(name: "Layer 1", texture: fallback))
            }

            if doc.activeLayerIndex < layerStack.layers.count {
                layerStack.activeLayerIndex = doc.activeLayerIndex
            }

            // Create window
            let contentView = self.buildLayout(canvasView: canvasView, viewModel: viewModel)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = url.deletingPathExtension().lastPathComponent
            window.minSize = NSSize(width: 800, height: 500)
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "ArtsyCanvas"
            window.isReleasedWhenClosed = false
            window.contentView = contentView

            // Track saved file URL so dirty tracking / quit prompt know this canvas is on disk
            viewModel.fileURL = url
            viewModel.markClean()

            CanvasWindowStore.shared.register(window: window, viewModel: viewModel, canvasView: canvasView)
            observeDirty(window: window, viewModel: viewModel)

            let targetWindow = NSApp.keyWindow?.tabbingIdentifier == "ArtsyCanvas" ? NSApp.keyWindow :
                NSApp.windows.first(where: { $0.tabbingIdentifier == "ArtsyCanvas" && $0 != window && $0.isVisible })

            if let target = targetWindow {
                target.addTabbedWindow(window, ordered: .above)
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)

        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open document"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    // MARK: - Menu Bar

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Artsy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        // Check for Updates… (Sparkle)
        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = updaterController
        appMenu.addItem(checkUpdatesItem)

        appMenu.addItem(NSMenuItem.separator())
        // Settings
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Artsy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Canvas...", action: #selector(showNewCanvasDialog), keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Open...", action: #selector(handleOpen), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Save...", action: #selector(handleSave), keyEquivalent: "s")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Export PNG...", action: #selector(handleExportPNG), keyEquivalent: "e")
        let exportJPEGItem = NSMenuItem(title: "Export JPEG...", action: #selector(handleExportJPEG), keyEquivalent: "e")
        exportJPEGItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(exportJPEGItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.close), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit menu — must include standard actions for text fields to work
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(handleUndo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(handleRedo), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Distraction Free", action: #selector(toggleDistractionFree), keyEquivalent: "f")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(handleZoomToFit), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(handleActualSize), keyEquivalent: "1")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Toggle Right Panel", action: #selector(handleToggleRightPanel), keyEquivalent: "\t")
        viewMenu.addItem(NSMenuItem.separator())

        // Background color submenu
        let bgMenuItem = NSMenuItem(title: "Background Color", action: nil, keyEquivalent: "")
        let bgMenu = NSMenu(title: "Background Color")
        bgMenu.addItem(withTitle: "Dark Gray", action: #selector(setBgDarkGray), keyEquivalent: "")
        bgMenu.addItem(withTitle: "Medium Gray", action: #selector(setBgMediumGray), keyEquivalent: "")
        bgMenu.addItem(withTitle: "Light Gray", action: #selector(setBgLightGray), keyEquivalent: "")
        bgMenu.addItem(withTitle: "Black", action: #selector(setBgBlack), keyEquivalent: "")
        bgMenu.addItem(withTitle: "White", action: #selector(setBgWhite), keyEquivalent: "")
        bgMenu.addItem(NSMenuItem.separator())
        bgMenu.addItem(withTitle: "Custom...", action: #selector(setBgCustom), keyEquivalent: "")
        bgMenuItem.submenu = bgMenu
        viewMenu.addItem(bgMenuItem)

        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview), keyEquivalent: "\\")
        viewMenuItem.submenu = viewMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab), keyEquivalent: "}")
        windowMenu.item(at: 1)?.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab), keyEquivalent: "{")
        windowMenu.item(at: 2)?.keyEquivalentModifierMask = [.command, .shift]
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions (operate on the active tab's canvas)

    private var activeStore: (viewModel: CanvasViewModel, canvasView: CanvasView)? {
        guard let window = NSApp.keyWindow else { return nil }
        return CanvasWindowStore.shared.get(for: window)
    }

    var activeStorePublic: (viewModel: CanvasViewModel, canvasView: CanvasView)? {
        // Try key window first, then any visible canvas window
        if let window = NSApp.keyWindow, let store = CanvasWindowStore.shared.get(for: window) {
            return store
        }
        for window in NSApp.windows where window.tabbingIdentifier == "ArtsyCanvas" {
            if let store = CanvasWindowStore.shared.get(for: window) {
                return store
            }
        }
        return nil
    }

    @objc private func handleUndo() {
        guard let store = activeStore else { return }
        store.viewModel.performUndo(renderer: store.canvasView.renderer)
    }

    @objc private func handleRedo() {
        guard let store = activeStore else { return }
        store.viewModel.performRedo(renderer: store.canvasView.renderer)
    }

    @objc private func handleZoomToFit() {
        guard let store = activeStore else { return }
        store.viewModel.transform.zoomToFit(canvasSize: store.viewModel.canvasSize, viewSize: store.canvasView.bounds.size)
    }

    @objc private func handleActualSize() {
        guard let store = activeStore else { return }
        store.viewModel.transform.scale = 1.0
        store.viewModel.transform.offset = .zero
    }

    @objc private func handleToggleRightPanel() {
        activeStore?.viewModel.toggleRightPanel()
    }

    @objc private func toggleDistractionFree() {
        if distractionFreeWindow != nil {
            exitDistractionFree()
        } else {
            enterDistractionFree()
        }
    }

    @objc private func handleEnterDistractionFree() { enterDistractionFree() }
    @objc private func handleExitDistractionFree() { exitDistractionFree() }

    private var activeWindowBeforeFullscreen: NSWindow?
    private var savedTransform: CanvasTransform?

    private func enterDistractionFree() {
        guard let store = activeStore, let keyWindow = NSApp.keyWindow else { return }

        store.viewModel.isDistractionFree = true
        activeWindowBeforeFullscreen = keyWindow
        savedTransform = store.viewModel.transform

        guard let screen = keyWindow.screen ?? NSScreen.main else { return }
        let fsWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        fsWindow.level = .floating  // Float above all other windows
        fsWindow.backgroundColor = NSColor.black
        fsWindow.isReleasedWhenClosed = false

        let fsCanvasView = CanvasView(frame: screen.frame, device: metalContext.device)
        do {
            try fsCanvasView.configure(context: metalContext, viewModel: store.viewModel)
        } catch {
            return
        }
        fsCanvasView.autoresizingMask = [.width, .height]

        fsWindow.contentView = fsCanvasView
        fsWindow.setFrame(screen.frame, display: true)
        fsWindow.makeKeyAndOrderFront(nil)

        distractionFreeWindow = fsWindow
        distractionFreeCanvasView = fsCanvasView
        fsWindow.makeFirstResponder(fsCanvasView)

        // Don't hide other windows — just cover them with the floating fullscreen window.
        // This preserves their tab grouping exactly.
    }

    private func exitDistractionFree() {
        guard let fsWindow = distractionFreeWindow else { return }

        // Restore the original transform (zoom/pan) before tearing down
        if let transform = savedTransform, let vm = distractionFreeCanvasView?.viewModel {
            vm.transform = transform
        }
        savedTransform = nil

        if let fsCanvas = distractionFreeCanvasView {
            fsCanvas.viewModel?.isDistractionFree = false
            fsCanvas.delegate = nil
            fsCanvas.isPaused = true
        }

        fsWindow.orderOut(nil)
        distractionFreeWindow = nil
        distractionFreeCanvasView = nil

        // Just bring the original window back to front — tab groups are intact
        if let activeWindow = activeWindowBeforeFullscreen {
            activeWindow.makeKeyAndOrderFront(nil)
        }
        activeWindowBeforeFullscreen = nil
    }

    @objc private func setBgDarkGray() { activeStore?.viewModel.canvasBackgroundColor = (0.10, 0.10, 0.10) }
    @objc private func setBgMediumGray() { activeStore?.viewModel.canvasBackgroundColor = (0.35, 0.35, 0.35) }
    @objc private func setBgLightGray() { activeStore?.viewModel.canvasBackgroundColor = (0.65, 0.65, 0.65) }
    @objc private func setBgBlack() { activeStore?.viewModel.canvasBackgroundColor = (0.0, 0.0, 0.0) }
    @objc private func setBgWhite() { activeStore?.viewModel.canvasBackgroundColor = (1.0, 1.0, 1.0) }

    @objc private func setBgCustom() {
        let colorPanel = NSColorPanel.shared
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(bgColorChanged(_:)))
        colorPanel.color = NSColor(
            red: activeStore?.viewModel.canvasBackgroundColor.r ?? 0.18,
            green: activeStore?.viewModel.canvasBackgroundColor.g ?? 0.18,
            blue: activeStore?.viewModel.canvasBackgroundColor.b ?? 0.18,
            alpha: 1.0
        )
        colorPanel.orderFront(nil)
    }

    @objc private func bgColorChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.deviceRGB) else { return }
        activeStore?.viewModel.canvasBackgroundColor = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    @objc private func handleExportPNG() {
        guard let store = activeStore else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "canvas.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ImageExporter.exportPNG(renderer: store.canvasView.renderer, to: url)
        }
    }

    @objc private func handleExportJPEG() {
        guard let store = activeStore else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "canvas.jpg"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ImageExporter.exportJPEG(renderer: store.canvasView.renderer, to: url)
        }
    }

    @objc private func handleSave() {
        guard let store = activeStore else { return }
        saveCanvas(store: store, targetWindow: NSApp.keyWindow, completion: nil)
    }

    /// Save the canvas. If the viewModel already has a fileURL, save there; otherwise prompt.
    /// `completion(true)` = saved successfully, `completion(false)` = cancelled or failed.
    private func saveCanvas(
        store: (viewModel: CanvasViewModel, canvasView: CanvasView),
        targetWindow: NSWindow?,
        completion: ((Bool) -> Void)?
    ) {
        if let existingURL = store.viewModel.fileURL {
            // Save in place
            CanvasDocument.saveAsync(
                renderer: store.canvasView.renderer,
                viewModel: store.viewModel,
                to: existingURL
            ) { result in
                switch result {
                case .success:
                    store.viewModel.markClean()
                    targetWindow?.title = existingURL.deletingPathExtension().lastPathComponent
                    completion?(true)
                case .failure(let error):
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    completion?(false)
                }
            }
            return
        }

        // First save — show Save panel
        let panel = NSSavePanel()
        if let artsyType = UTType("com.artsy.document") {
            panel.allowedContentTypes = [artsyType]
        }
        panel.nameFieldStringValue = "Untitled.artsy"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            CanvasDocument.saveAsync(
                renderer: store.canvasView.renderer,
                viewModel: store.viewModel,
                to: url
            ) { result in
                switch result {
                case .success:
                    store.viewModel.fileURL = url
                    store.viewModel.markClean()
                    targetWindow?.title = url.deletingPathExtension().lastPathComponent
                    completion?(true)
                case .failure(let error):
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    completion?(false)
                }
            }
        }
    }

    @objc private func handleOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an .artsy document"

        // Try to set the custom UTType, fall back to allowing all
        if let artsyType = UTType("com.artsy.document") {
            panel.allowedContentTypes = [artsyType]
        }

        panel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url {
                self.openArtsyDocument(at: url)
            }
            self.isOpeningFile = false

            // If user cancelled and no windows exist, show the new canvas dialog
            if NSApp.windows.filter({ $0.isVisible && $0.tabbingIdentifier == "ArtsyCanvas" }).isEmpty {
                self.showNewCanvasDialog()
            }
        }
    }

    @objc private func showSettings() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Artsy Settings"
        settingsWindow.contentView = NSHostingView(rootView: SettingsView())
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Window → ViewModel/CanvasView mapping

final class CanvasWindowStore {
    static let shared = CanvasWindowStore()

    private var store: [ObjectIdentifier: (viewModel: CanvasViewModel, canvasView: CanvasView)] = [:]

    func register(window: NSWindow, viewModel: CanvasViewModel, canvasView: CanvasView) {
        store[ObjectIdentifier(window)] = (viewModel, canvasView)
    }

    func get(for window: NSWindow) -> (viewModel: CanvasViewModel, canvasView: CanvasView)? {
        store[ObjectIdentifier(window)]
    }

    func remove(for window: NSWindow) {
        store.removeValue(forKey: ObjectIdentifier(window))
    }
}
