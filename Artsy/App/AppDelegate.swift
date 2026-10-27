import AppKit
import Combine
import MetalKit
#if !APP_STORE
import Sparkle
#endif
import SwiftUI
import UniformTypeIdentifiers
import ArtsyEngine

class AppDelegate: NSObject, NSApplicationDelegate {
    var metalContext: MetalContext!
    private var tabCounter = 0
    private var savedWindowFrame: NSRect?
    private var newCanvasPanel: NSPanel?
    /// The start screen's window, while it is up.
    private var startWindow: NSWindow?
    /// Set while quitting, so canvases closing on the way out do not bring the start screen back.
    private var isQuitting = false
    /// Documents opened from the start screen's list under a security scope (the App Store
    /// build's sandbox), held while their windows are open.
    private var scopedRecentURLs: Set<URL> = []
    /// Keeps `viewModel.isDirty` → `window.isDocumentEdited` bindings alive per window.
    private var dirtyObservations: [ObjectIdentifier: AnyCancellable] = [:]
    #if !APP_STORE
    /// Sparkle updater — starts checking on launch, exposes "Check for Updates…" action.
    /// The App Store build has none: the store updates it, and the sandbox would not let
    /// Sparkle replace the app anyway.
    private lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    /// True when the app was launched only to host the unit tests.
    private static let isHostingTests = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The engine asks the platform for the pen in use and for its own diagnostics lines
        CanvasViewModel.currentPenKey = { TabletEventHandler.currentPenKey }
        ChromeActions.commitPendingEdits = { [weak self] in self?.activeStorePublic?.canvasView.commitPendingEdits() }
        DiagnosticsLog.platformDetails = {
            let screens = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\($0.backingScaleFactor)x" }
            return ["screens " + (screens.isEmpty ? "none" : screens.joined(separator: ", "))]
        }
        if Self.isHostingTests {
            // No windows, menus or update checks — the tests build what they need.
            NSApp.setActivationPolicy(.accessory)
            return
        }

        NSApp.setActivationPolicy(.regular)
        // Raw pen input is recorded unless Help ▸ Diagnostics says otherwise, so a session
        // can be replayed here
        UserDefaults.standard.register(defaults: ["recordStrokes": true])
        buildMenuBar()
        #if !APP_STORE
        _ = updaterController // instantiate → starts background update checks
        #endif

        do {
            metalContext = try MetalContext()
            metalContext.brushTextures.userTextureDirectory = BrushLibrary.shared.texturesDirectory
            DiagnosticsLog.shared.launched(device: metalContext.device)
        } catch {
            DiagnosticsLog.shared.launched(device: nil)
            DiagnosticsLog.shared.error(error, doing: "initialising Metal")
            let alert = NSAlert()
            alert.messageText = "Failed to initialize Metal"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSWindow.allowsAutomaticWindowTabbing = true

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
            showStart()
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
                self?.showStartIfNothingOpen()
            }
        ))
        panel.contentView = hostView
        self.newCanvasPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// - Parameter remember: whether `size` becomes the start screen's "Same as last";
    ///   not for a photo's.
    func createNewCanvas(size: CGSize, remember: Bool = true) {
        if remember { AppPreferences.shared.lastCanvasSize = size }
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
        window.collectionBehavior.insert(.fullScreenPrimary)

        do {
            let viewModel = CanvasViewModel(canvasSize: size)
            viewModel.untitledName = title
            let canvasView = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: metalContext.device)
            try canvasView.configure(context: metalContext, viewModel: viewModel)
            // The time-lapse of a canvas not yet saved goes to a temporary folder until it is
            canvasView.renderer.timelapse = CanvasDocument.temporaryTimelapse(for: canvasView.renderer)

            window.contentView = layout(canvasView: canvasView, viewModel: viewModel)

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
        startWindow?.close()
    }

    /// The canvas with the chrome around it; see `MainLayout`.
    private func layout(canvasView: CanvasView, viewModel: CanvasViewModel) -> NSView {
        MainLayout(canvasView: canvasView, viewModel: viewModel,
                   previewRenderer: try? BrushPreview(context: metalContext, size: BrushPreviewCache.size))
    }

    private var isOpeningFile = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if Self.isHostingTests { return false }
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
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak viewModel] _ in
            guard let self else { return }
            self.dirtyObservations[id] = nil
            if let url = viewModel?.fileURL, self.scopedRecentURLs.remove(url.standardizedFileURL) != nil {
                url.stopAccessingSecurityScopedResource()
            }
            // The last canvas gone, the start screen is back
            DispatchQueue.main.async { self.showStartIfNothingOpen() }
        }
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
        isQuitting = true
        DiagnosticsLog.shared.note(.app, "quitting")
        DiagnosticsLog.shared.flush()
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
            saveAllDirty(dirtyWindows, index: 0) { [weak self] allSaved in
                if !allSaved { self?.isQuitting = false }
                NSApp.reply(toApplicationShouldTerminate: allSaved)
            }
            return .terminateLater

        case .alertSecondButtonReturn: // Cancel
            isQuitting = false
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

    // Handle double-click opening of .artsy documents and .artsybrush brushes
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        switch url.pathExtension {
        case "artsy":
            if metalContext != nil {
                openArtsyDocument(at: url)
            } else {
                pendingOpenURLs.append(url)
            }
            return true
        case BrushLibrary.fileExtension:
            importBrushFile(at: url)
            return true
        default:
            return false
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            _ = application(sender, openFile: filename)
        }
    }

    /// A brush file opened from the Finder goes into the library and becomes the current brush.
    private func importBrushFile(at url: URL) {
        do {
            let brush = try BrushLibrary.shared.importBrush(from: url)
            activeStore?.viewModel.currentBrush = brush
        } catch {
            NSAlert(error: error).runModal()
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
            // The one loader, the same one the tests exercise: layers, their thickness, guides
            let (viewModel, canvasView) = try CanvasDocument.open(from: url, metalContext: metalContext)
            if let layerStack = viewModel.layerStack {
                canvasView.renderer.updateAllThumbnails(in: layerStack)
            }

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
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.contentView = layout(canvasView: canvasView, viewModel: viewModel)

            // Track saved file URL so dirty tracking / quit prompt know this canvas is on disk
            viewModel.fileURL = url
            viewModel.markClean()
            RecentCanvases.shared.note(url, size: viewModel.canvasSize)

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
            startWindow?.close()

        } catch {
            DiagnosticsLog.shared.error(error, doing: "opening \(url.lastPathComponent)")
            let alert = NSAlert()
            alert.messageText = "Failed to open document"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    // MARK: - The start screen

    /// The start screen in a window of its own: the canvases opened lately and the sizes
    /// (`StartView`, `docs/start-screen-plan.md`). At launch, back when the last canvas
    /// closes, and under Window ▸ Start; closing it with nothing else open quits.
    @objc func showStart() {
        if let startWindow {
            startWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Start"
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: StartView(recents: RecentCanvases.shared, actions: startActions()))
        window.center()
        window.setFrameAutosaveName("Start")
        startWindow = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.startWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// With the last canvas closed and nothing else up, the start screen; not while quitting.
    private func showStartIfNothingOpen() {
        guard !isQuitting, startWindow == nil, newCanvasPanel == nil,
              !NSApp.windows.contains(where: { $0.isVisible && $0.tabbingIdentifier == "ArtsyCanvas" }) else { return }
        showStart()
    }

    private func startActions() -> StartActions {
        var actions = StartActions()
        actions.newCanvas = { [weak self] size in self?.createNewCanvas(size: size) }
        actions.customCanvas = { [weak self] in self?.showNewCanvasDialog() }
        actions.open = { [weak self] entry in self?.openRecent(entry) }
        actions.browse = { [weak self] in self?.handleOpen() }
        actions.browseTitle = "Open…"
        actions.reveal = { entry in
            if let url = RecentCanvases.shared.url(of: entry) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        actions.canRename = { RecentCanvases.shared.url(of: $0) != nil }
        actions.rename = { [weak self] entry, name in self?.rename(entry, to: name) }
        actions.fromImageFile = { [weak self] in self?.newCanvasFromImageFile() }
        return actions
    }

    /// A canvas from an image file: the photo's size, the photo as the first layer under
    /// an empty one, the window named after the file.
    private func newCanvasFromImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo to paint over"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url),
                  let image = PhotoCanvas.image(from: data, maxSide: LayerStack.maxCanvasSide) else {
                NSAlert(error: PhotoCanvas.Failure.undecodable).runModal()
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            self.createNewCanvas(size: PhotoCanvas.canvasSize(for: image), remember: false)
            guard let store = self.activeStore else { return }
            do {
                try PhotoCanvas.place(image, named: name, in: store.viewModel, renderer: store.canvasView.renderer)
                store.viewModel.untitledName = name
                NSApp.keyWindow?.title = "• " + name
            } catch {
                DiagnosticsLog.shared.error(error, doing: "placing \(name)")
                NSAlert(error: error).runModal()
            }
        }
    }

    /// A canvas from the list: its window brought forward if it is open, opened if it is
    /// still there, else a word and the entry offered for removal.
    private func openRecent(_ entry: RecentCanvases.Entry) {
        guard let url = RecentCanvases.shared.url(of: entry) else {
            let alert = NSAlert()
            alert.messageText = "\(entry.name) was not found"
            alert.informativeText = "It may have been moved or deleted."
            alert.addButton(withTitle: "Remove from Recents")
            alert.addButton(withTitle: "Keep")
            if alert.runModal() == .alertFirstButtonReturn { RecentCanvases.shared.remove(entry) }
            return
        }
        let path = url.standardizedFileURL.path
        if let open = NSApp.windows.first(where: {
            $0.tabbingIdentifier == "ArtsyCanvas" && CanvasWindowStore.shared.get(for: $0)?.viewModel.fileURL?.standardizedFileURL.path == path
        }) {
            open.makeKeyAndOrderFront(nil)
            startWindow?.close()
            return
        }
        if url.startAccessingSecurityScopedResource() { scopedRecentURLs.insert(url.standardizedFileURL) }
        openArtsyDocument(at: url)
    }

    @objc private func openRecentMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = RecentCanvases.shared.entries.first(where: { $0.id.uuidString == id }) else { return }
        openRecent(entry)
    }

    @objc private func clearRecents() {
        RecentCanvases.shared.removeAll()
    }

    /// The document renamed on disk, in the list, and in any window that has it open.
    private func rename(_ entry: RecentCanvases.Entry, to name: String) {
        guard !name.isEmpty, !name.contains("/"), let url = RecentCanvases.shared.url(of: entry) else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("artsy")
        guard destination.path != url.path else { return }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            DiagnosticsLog.shared.error(error, doing: "renaming \(entry.name)")
            NSAlert(error: error).runModal()
            return
        }
        RecentCanvases.shared.moved(entry, to: destination)
        let path = url.standardizedFileURL.path
        for window in NSApp.windows where window.tabbingIdentifier == "ArtsyCanvas" {
            guard let store = CanvasWindowStore.shared.get(for: window),
                  store.viewModel.fileURL?.standardizedFileURL.path == path else { continue }
            store.viewModel.fileURL = destination
            window.representedURL = destination
            window.title = (store.viewModel.isDirty ? "• " : "") + name
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

        #if !APP_STORE
        // Check for Updates… (Sparkle)
        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = updaterController
        appMenu.addItem(checkUpdatesItem)

        appMenu.addItem(NSMenuItem.separator())
        #endif
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
        // Open Recent: the start screen's list, filled in as the menu opens
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Save...", action: #selector(handleSave), keyEquivalent: "s")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Export PNG...", action: #selector(handleExportPNG), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Export PNG (16-bit)...", action: #selector(handleExportPNG16), keyEquivalent: "")
        let exportJPEGItem = NSMenuItem(title: "Export JPEG...", action: #selector(handleExportJPEG), keyEquivalent: "e")
        exportJPEGItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(exportJPEGItem)
        fileMenu.addItem(NSMenuItem.separator())
        // Time-lapse: filled in as it opens, from the front canvas's recorder
        let timelapseItem = NSMenuItem(title: "Time-lapse", action: nil, keyEquivalent: "")
        let timelapseMenu = NSMenu(title: "Time-lapse")
        timelapseMenu.delegate = self
        timelapseMenu.autoenablesItems = false
        timelapseItem.submenu = timelapseMenu
        fileMenu.addItem(timelapseItem)
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
        editMenu.addItem(withTitle: "Cut", action: #selector(handleCut), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(handleCopy), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(handlePaste), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste in Place", action: #selector(handlePasteInPlace), keyEquivalent: "V") // ⌘⇧V
        editMenu.addItem(withTitle: "Select All", action: #selector(handleSelectAll), keyEquivalent: "a")
        let deselectItem = NSMenuItem(title: "Deselect", action: #selector(handleDeselect), keyEquivalent: "d")
        editMenu.addItem(deselectItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Dry Layer", action: #selector(handleDryLayer), keyEquivalent: "")
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        // Brush menu
        let brushMenuItem = NSMenuItem()
        let brushMenu = NSMenu(title: "Brush")
        brushMenu.addItem(withTitle: "Brush Studio...", action: #selector(showBrushStudio), keyEquivalent: "B")
        brushMenu.addItem(NSMenuItem.separator())
        brushMenu.addItem(withTitle: "Duplicate Brush", action: #selector(handleDuplicateBrush), keyEquivalent: "")
        brushMenu.addItem(withTitle: "Delete Brush", action: #selector(handleDeleteBrush), keyEquivalent: "")
        brushMenu.addItem(NSMenuItem.separator())
        brushMenu.addItem(withTitle: "Import Brush...", action: #selector(handleImportBrush), keyEquivalent: "")
        brushMenu.addItem(withTitle: "Export Brush...", action: #selector(handleExportBrush), keyEquivalent: "")
        brushMenu.addItem(NSMenuItem.separator())
        brushMenu.addItem(withTitle: "Import Tip or Grain Image...", action: #selector(handleImportTexture), keyEquivalent: "")
        brushMenu.addItem(withTitle: "Show Brushes Folder", action: #selector(handleShowBrushesFolder), keyEquivalent: "")
        brushMenuItem.submenu = brushMenu
        mainMenu.addItem(brushMenuItem)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(handleZoomToFit), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(handleActualSize), keyEquivalent: "1")
        viewMenu.addItem(NSMenuItem.separator())
        let rotateLeft = viewMenu.addItem(withTitle: "Rotate Canvas Left", action: #selector(handleRotateLeft), keyEquivalent: "[")
        rotateLeft.keyEquivalentModifierMask = [.command, .option]
        let rotateRight = viewMenu.addItem(withTitle: "Rotate Canvas Right", action: #selector(handleRotateRight), keyEquivalent: "]")
        rotateRight.keyEquivalentModifierMask = [.command, .option]
        let resetRotation = viewMenu.addItem(withTitle: "Reset Rotation", action: #selector(handleResetRotation), keyEquivalent: "0")
        resetRotation.keyEquivalentModifierMask = [.command, .option]
        let flip = viewMenu.addItem(withTitle: "Flip Canvas View", action: #selector(handleFlipView), keyEquivalent: "f")
        flip.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Hide Interface", action: #selector(handleToggleChrome), keyEquivalent: "\t")
        let showWet = viewMenu.addItem(withTitle: "Show Wet Paint", action: #selector(handleToggleShowWetPaint), keyEquivalent: "w")
        showWet.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(NSMenuItem.separator())

        // Guides submenu; its check marks follow the front canvas (see menuNeedsUpdate)
        let guidesItem = NSMenuItem(title: "Guides", action: nil, keyEquivalent: "")
        let guidesMenu = NSMenu(title: "Guides")
        guidesMenu.delegate = self
        guidesMenu.addItem(withTitle: "Show Grid", action: #selector(toggleGrid), keyEquivalent: "'")
        guidesMenu.addItem(withTitle: "Snap to Grid", action: #selector(toggleSnapToGrid), keyEquivalent: "")
        let spacingItem = NSMenuItem(title: "Grid Spacing", action: nil, keyEquivalent: "")
        let spacingMenu = NSMenu(title: "Grid Spacing")
        spacingMenu.delegate = self
        for spacing in [16, 32, 64, 128, 256] {
            let item = spacingMenu.addItem(withTitle: "\(spacing) px", action: #selector(setGridSpacing(_:)), keyEquivalent: "")
            item.tag = spacing
        }
        spacingItem.submenu = spacingMenu
        guidesMenu.addItem(spacingItem)
        guidesMenu.addItem(NSMenuItem.separator())
        guidesMenu.addItem(withTitle: "Add Horizontal Guide", action: #selector(addHorizontalGuide), keyEquivalent: "")
        guidesMenu.addItem(withTitle: "Add Vertical Guide", action: #selector(addVerticalGuide), keyEquivalent: "")
        guidesMenu.addItem(withTitle: "Snap to Guides", action: #selector(toggleSnapToGuides), keyEquivalent: "")
        guidesMenu.addItem(withTitle: "Clear Guides", action: #selector(clearGuides), keyEquivalent: "")
        guidesItem.submenu = guidesMenu
        viewMenu.addItem(guidesItem)
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
        windowMenu.addItem(NSMenuItem.separator())
        let startItem = NSMenuItem(title: "Start", action: #selector(showStart), keyEquivalent: "n")
        startItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(startItem)
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help menu: what to bring back from a session on another Mac
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        let diagnosticsMenu = NSMenu(title: "Diagnostics")
        diagnosticsMenu.delegate = self
        diagnosticsMenu.addItem(withTitle: "Record Strokes", action: #selector(toggleStrokeRecording), keyEquivalent: "")
        diagnosticsMenu.addItem(withTitle: "Show Diagnostics Folder", action: #selector(showDiagnosticsFolder), keyEquivalent: "")
        diagnosticsMenu.addItem(withTitle: "Export Diagnostics…", action: #selector(exportDiagnostics), keyEquivalent: "")
        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnosticsItem.submenu = diagnosticsMenu
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts), keyEquivalent: "/")
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(diagnosticsItem)
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

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
        // Route through CanvasView so transform-session intra-session undo runs
        // when a session is active.
        store.canvasView.performUndoAction()
    }

    @objc private func handleRedo() {
        guard let store = activeStore else { return }
        store.canvasView.performRedoAction()
    }

    @objc private func handleSelectAll() {
        guard let store = activeStore else { return }
        // Route through CanvasView so any pending transform auto-commits first
        // and the snapshot captures the post-commit state correctly.
        store.canvasView.performSelectAllAction()
    }

    @objc private func handleDeselect() {
        guard let store = activeStore else { return }
        store.canvasView.performDeselectAction()
    }

    @objc private func handleCut() {
        activeStore?.canvasView.performCutAction()
    }

    @objc private func handleCopy() {
        activeStore?.canvasView.performCopyAction()
    }

    @objc private func handlePaste() {
        activeStore?.canvasView.performPasteAction()
    }

    @objc private func handlePasteInPlace() {
        activeStore?.canvasView.performPasteInPlaceAction()
    }

    // The view actions live on the view model, shared with the bar's Adjust panel

    @objc private func handleZoomToFit() {
        guard let store = activeStore else { return }
        store.viewModel.zoomToFit(viewSize: store.canvasView.bounds.size)
    }

    @objc private func handleActualSize() {
        activeStore?.viewModel.actualSize()
    }

    @objc private func handleRotateLeft() {
        guard let store = activeStore else { return }
        store.viewModel.rotateView(direction: 1, viewSize: store.canvasView.bounds.size)
    }

    @objc private func handleRotateRight() {
        guard let store = activeStore else { return }
        store.viewModel.rotateView(direction: -1, viewSize: store.canvasView.bounds.size)
    }

    @objc private func handleResetRotation() {
        guard let store = activeStore else { return }
        store.viewModel.resetRotation(viewSize: store.canvasView.bounds.size)
    }

    // MARK: - Guides

    @objc private func toggleGrid() {
        changeGuides { $0.showsGrid.toggle() }
    }

    @objc private func toggleSnapToGrid() {
        changeGuides { $0.snapsToGrid.toggle() }
    }

    @objc private func setGridSpacing(_ sender: NSMenuItem) {
        changeGuides { $0.gridSpacing = CGFloat(sender.tag) }
    }

    @objc private func toggleSnapToGuides() {
        changeGuides { $0.snapsToGuides.toggle() }
    }

    @objc private func addHorizontalGuide() {
        guard let store = activeStore else { return }
        store.viewModel.addGuide(horizontal: true, viewSize: store.canvasView.bounds.size)
        store.canvasView.redrawOverlays()
    }

    @objc private func addVerticalGuide() {
        guard let store = activeStore else { return }
        store.viewModel.addGuide(horizontal: false, viewSize: store.canvasView.bounds.size)
        store.canvasView.redrawOverlays()
    }

    @objc private func clearGuides() {
        changeGuides { $0.horizontals.removeAll(); $0.verticals.removeAll() }
    }

    private func changeGuides(_ change: (inout CanvasGuides) -> Void) {
        guard let store = activeStore else { return }
        store.viewModel.changeGuides(change)
        store.canvasView.redrawOverlays()
    }

    @objc private func handleFlipView() {
        guard let store = activeStore else { return }
        store.viewModel.flipView(viewSize: store.canvasView.bounds.size)
    }

    @objc private func handleToggleChrome() {
        activeStore?.viewModel.toggleChrome()
    }

    @objc private func handleToggleShowWetPaint(_ sender: NSMenuItem) {
        guard let viewModel = activeStore?.viewModel else { return }
        viewModel.showsWetPaint.toggle()
        sender.state = viewModel.showsWetPaint ? .on : .off
    }

    @objc private func handleDryLayer() {
        activeStore?.viewModel.dryActiveLayer()
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

    // MARK: - Brush menu

    private var brushStudioWindow: NSWindow?
    private var shortcutsWindow: NSWindow?

    /// Every key the app answers to, in one sheet.
    @objc private func showShortcuts() {
        let window = shortcutsWindow ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Keyboard Shortcuts"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: ShortcutsView())
            window.center()
            return window
        }()
        shortcutsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    private var brushStudioModel: BrushStudioModel?

    /// Opens the studio on the active canvas's current brush. Reopening it binds it to
    /// whichever canvas is active then.
    @objc private func showBrushStudio() {
        guard let store = activeStore else { return }
        let model = BrushStudioModel(
            viewModel: store.viewModel,
            library: BrushLibrary.shared,
            previewRenderer: try? BrushPreview(context: metalContext)
        )
        brushStudioModel = model

        let window = brushStudioWindow ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Brush Studio"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)   // the chrome's one look
            window.center()
            return window
        }()
        window.contentView = NSHostingView(rootView: BrushStudioView(model: model, library: BrushLibrary.shared))
        brushStudioWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// A copy of the current brush, saved to the library and selected, so it can be
    /// changed without touching the original.
    @objc private func handleDuplicateBrush() {
        guard let store = activeStore else { return }
        do {
            let copy = try BrushLibrary.shared.duplicate(store.viewModel.currentBrush)
            store.viewModel.currentBrush = copy
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func handleDeleteBrush() {
        guard let store = activeStore else { return }
        let brush = store.viewModel.currentBrush
        guard BrushLibrary.shared.isUserBrush(brush) else {
            let alert = NSAlert()
            alert.messageText = "\(brush.name) is a built-in brush"
            alert.informativeText = "Built-in brushes can't be deleted. Only brushes you have made or imported can."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(brush.name)\"?"
        alert.informativeText = "This removes the brush from your library. It can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try BrushLibrary.shared.remove(brush)
            store.viewModel.currentBrush = .hardRound
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func handleImportBrush() {
        guard let store = activeStore else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [BrushLibrary.brushType, .json]
            + ["abr", "brush", "brushset"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Artsy brushes, Photoshop .abr files (their tips), or Procreate .brush and .brushset files (shape and grain)."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                do {
                    let imported = try BrushLibrary.shared.importBrushes(from: url)
                    DiagnosticsLog.shared.note(.brush, "imported \(imported.count) from \(url.lastPathComponent): "
                                               + imported.map(\.name).joined(separator: ", "))
                    for case .stamp(let settings) in imported.map(\.rendering) {
                        if case .image(let name) = settings.tip { self?.metalContext.brushTextures.forgetImage(named: name) }
                        if case .image(let name)? = settings.grain?.texture { self?.metalContext.brushTextures.forgetImage(named: name) }
                    }
                    if let last = imported.last { store.viewModel.currentBrush = last }
                } catch {
                    DiagnosticsLog.shared.error(error, doing: "importing \(url.lastPathComponent)")
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc private func handleExportBrush() {
        guard let store = activeStore else { return }
        let brush = store.viewModel.currentBrush
        let panel = NSSavePanel()
        panel.allowedContentTypes = [BrushLibrary.brushType]
        panel.nameFieldStringValue = "\(brush.name).\(BrushLibrary.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try BrushLibrary.shared.export(brush, to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Copies images into the library's textures folder. A brush file refers to one as
    /// "image:<file name>" for its tip or grain.
    /// An image file onto the canvas as a new layer, from the Add panel.
    @objc private func handleImportImage() {
        guard let store = activeStore else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to place as a new layer"
        let canvasView = store.canvasView
        panel.begin { [weak canvasView] response in
            guard response == .OK, let url = panel.url, let canvasView, let image = NSImage(contentsOf: url) else { return }
            canvasView.placeImage(image, named: url.deletingPathExtension().lastPathComponent)
        }
    }

    @objc private func handleImportTexture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, UTType(filenameExtension: "gbr") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose tip or grain images. A tip's alpha channel is its shape; a grain's brightness is its height."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            var names: [String] = []
            for url in panel.urls {
                do {
                    let name = try BrushLibrary.shared.importTexture(from: url)
                    self?.metalContext.brushTextures.forgetImage(named: name)
                    names.append(name)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            guard !names.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = names.count == 1 ? "Imported \(names[0])" : "Imported \(names.count) images"
            alert.informativeText = "Refer to an image from a brush file as \"image:<name>\" for its tip or grain texture. Names: "
                + names.joined(separator: ", ")
            alert.runModal()
        }
    }

    @objc private func handleShowBrushesFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([BrushLibrary.shared.directory])
    }

    // MARK: - Diagnostics

    @objc private func toggleStrokeRecording() {
        let on = !StrokeRecorder.isEnabledInDefaults
        UserDefaults.standard.set(on, forKey: "recordStrokes")
        for store in CanvasWindowStore.shared.all { store.viewModel.setStrokeRecording(on) }
        DiagnosticsLog.shared.note(.app, "stroke recording turned \(on ? "on" : "off")")
    }

    @objc private func showDiagnosticsFolder() {
        guard let folder = DiagnosticsLog.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DiagnosticsLog.shared.flush()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// The logs, the stroke recordings and the brush library, copied into one folder to send.
    @objc private func exportDiagnostics() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Artsy Diagnostics \(formatter.string(from: Date()))"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try DiagnosticsLog.gatherBundle(to: url, device: self?.metalContext?.device)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                DiagnosticsLog.shared.error(error, doing: "exporting diagnostics")
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func handleExportPNG() {
        guard let store = activeStore else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "canvas.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.canvasView.commitPendingEdits()
            do { try ImageExporter.exportPNG(renderer: store.canvasView.renderer, to: url) }
            catch { DiagnosticsLog.shared.error(error, doing: "exporting PNG"); NSAlert(error: error).runModal() }
        }
    }

    @objc private func handleExportPNG16() {
        guard let store = activeStore else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "canvas-16bit.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.canvasView.commitPendingEdits()
            do { try ImageExporter.exportPNG(renderer: store.canvasView.renderer, to: url, bitsPerChannel: 16) }
            catch { DiagnosticsLog.shared.error(error, doing: "exporting 16-bit PNG"); NSAlert(error: error).runModal() }
        }
    }

    @objc private func handleExportJPEG() {
        guard let store = activeStore else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "canvas.jpg"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.canvasView.commitPendingEdits()
            do { try ImageExporter.exportJPEG(renderer: store.canvasView.renderer, to: url) }
            catch { DiagnosticsLog.shared.error(error, doing: "exporting JPEG"); NSAlert(error: error).runModal() }
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
        // A transform in progress goes onto its layer first, or the file would lack it
        store.canvasView.commitPendingEdits()
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
                    RecentCanvases.shared.note(existingURL, size: store.viewModel.canvasSize)
                    targetWindow?.title = existingURL.deletingPathExtension().lastPathComponent
                    completion?(true)
                case .failure(let error):
                    DiagnosticsLog.shared.error(error, doing: "saving")
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
                    RecentCanvases.shared.note(url, size: store.viewModel.canvasSize)
                    targetWindow?.title = url.deletingPathExtension().lastPathComponent
                    completion?(true)
                case .failure(let error):
                    DiagnosticsLog.shared.error(error, doing: "saving")
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

            // Cancelled with nothing open: the start screen
            self.showStartIfNothingOpen()
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
        settingsWindow.appearance = NSAppearance(named: .darkAqua)
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

    /// Every open canvas.
    var all: [(viewModel: CanvasViewModel, canvasView: CanvasView)] { Array(store.values) }

    func remove(for window: NSWindow) {
        store.removeValue(forKey: ObjectIdentifier(window))
    }
}

// MARK: - Guides menu check marks

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Open Recent" {
            menu.removeAllItems()
            for entry in RecentCanvases.shared.entries.prefix(20) {
                let item = NSMenuItem(title: entry.name, action: #selector(openRecentMenuItem(_:)), keyEquivalent: "")
                item.representedObject = entry.id.uuidString
                menu.addItem(item)
            }
            if !menu.items.isEmpty { menu.addItem(NSMenuItem.separator()) }
            menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
            return
        }
        if menu.title == "Time-lapse" {
            menu.removeAllItems()
            let store = activeStore
            let recorder = store?.canvasView.renderer.timelapse
            let hasFrames = (recorder?.frames ?? 0) > 0
            let summary = NSMenuItem(title: recorder?.summary ?? "Nothing recorded yet", action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
            menu.addItem(NSMenuItem.separator())
            let record = NSMenuItem(title: "Record Time-lapse", action: #selector(timelapseToggleRecording), keyEquivalent: "")
            record.state = recorder?.isRecording == true ? .on : .off
            record.isEnabled = store != nil
            menu.addItem(record)
            menu.addItem(NSMenuItem.separator())
            for (title, action) in [("Replay...", #selector(timelapseReplay)),
                                    ("Export Full Length...", #selector(timelapseExportFull)),
                                    ("Export 30 Seconds...", #selector(timelapseExportShort))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.isEnabled = hasFrames
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let delete = NSMenuItem(title: "Delete Time-lapse...", action: #selector(timelapseDelete), keyEquivalent: "")
            delete.isEnabled = hasFrames
            menu.addItem(delete)
            return
        }
        if menu.title == "Diagnostics" {
            menu.items.first { $0.title == "Record Strokes" }?.state = StrokeRecorder.isEnabledInDefaults ? .on : .off
            return
        }
        guard let guides = activeStore?.viewModel.guides else { return }
        for item in menu.items {
            switch item.title {
            case "Show Grid": item.state = guides.showsGrid ? .on : .off
            case "Snap to Grid": item.state = guides.snapsToGrid ? .on : .off
            case "Snap to Guides": item.state = guides.snapsToGuides ? .on : .off
            case "Clear Guides": item.isEnabled = !guides.isEmpty
            default:
                if item.tag > 0 { item.state = Int(guides.gridSpacing) == item.tag ? .on : .off }
            }
        }
    }
}

// MARK: - Time-lapse

extension AppDelegate {
    /// The front canvas's own switch, flipped; a canvas with no recorder gets one when
    /// turned on.
    @objc private func timelapseToggleRecording() {
        guard let store = activeStore, let renderer = store.canvasView.renderer else { return }
        CanvasDocument.setTimelapseRecording(!(renderer.timelapse?.isRecording ?? false), renderer: renderer,
                                             documentURL: store.viewModel.fileURL)
    }

    /// The recording so far in a window of its own, with Export and Done.
    @objc private func timelapseReplay() {
        guard let store = activeStore, let recorder = store.canvasView.renderer.timelapse else { return }
        let name = store.viewModel.displayName
        Task { @MainActor [weak self] in
            do {
                let movie = try await recorder.movie()
                let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Time-lapse — " + name
                window.appearance = NSAppearance(named: .darkAqua)
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: TimelapsePlayerView(
                    movie: movie, name: name, export: { [weak self] length in
                        self?.exportTimelapse(recorder, length: length, named: name)
                    }, done: { [weak window] in window?.close() }))
                // Sized to the frame, as wide as 960 or what the screen allows
                let width = min(960, (NSScreen.main?.visibleFrame.width ?? 1200) - 120)
                window.setContentSize(NSSize(width: width, height: width * movie.size.height / movie.size.width + 72))
                window.center()
                window.makeKeyAndOrderFront(nil)
            } catch {
                DiagnosticsLog.shared.error(error, doing: "replaying the time-lapse")
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func timelapseExportFull() { exportTimelapse(length: .full) }
    @objc private func timelapseExportShort() { exportTimelapse(length: .thirtySeconds) }

    private func exportTimelapse(length: TimelapseMovie.Length) {
        guard let store = activeStore, let recorder = store.canvasView.renderer.timelapse else { return }
        exportTimelapse(recorder, length: length, named: store.viewModel.displayName)
    }

    /// The movie as an MP4 where the save panel says, its progress in a small window
    /// with Cancel.
    private func exportTimelapse(_ recorder: TimelapseRecorder, length: TimelapseMovie.Length, named name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = length == .full ? "\(name) Time-lapse.mp4" : "\(name) Time-lapse 30 s.mp4"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let export = TimelapseExport()
            let progress = NSWindow(contentViewController: NSHostingController(rootView: TimelapseExportView(export: export, name: name)))
            progress.title = "Export Time-lapse"
            progress.styleMask = [.titled]
            progress.appearance = NSAppearance(named: .darkAqua)
            progress.isReleasedWhenClosed = false
            progress.center()
            progress.makeKeyAndOrderFront(nil)
            export.task = Task { @MainActor in
                defer { progress.close() }
                do {
                    let movie = try await recorder.movie(length: length)
                    try await movie.export(to: url) { fraction in
                        DispatchQueue.main.async { export.fraction = fraction }
                    }
                } catch is CancellationError {
                } catch {
                    DiagnosticsLog.shared.error(error, doing: "exporting the time-lapse")
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc private func timelapseDelete() {
        guard let store = activeStore, let recorder = store.canvasView.renderer.timelapse else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the time-lapse of \(store.viewModel.displayName)?"
        alert.informativeText = "The recording so far, \(recorder.summary), is removed from the document. This cannot be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        recorder.deleteRecording()
    }
}
