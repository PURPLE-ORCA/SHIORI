import AppKit
import SwiftUI
import Combine
import OSLog

@main
struct SHIORIMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let coordinator = AppCoordinator()
        app.delegate = coordinator
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(coordinator) {}
    }
}

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let logger = Logger(subsystem: "app.shiori.desktop", category: "application")
    let settings: SettingsStore
    let privacy: PrivacyLock
    private(set) var lifecycleInstalled = false
    private var started = false
    let dataFolder: URL
    var store: NotesStore?
    var windows: StickyWindowManager?
    var edgeTabs: [CGDirectDisplayID: EdgeDockController] = [:]
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var subscriptions = Set<AnyCancellable>()
    var searchController: QuickSearchController?
    var shortcuts: GlobalShortcutCoordinator?
    var terminating = false
    let appAttachment = AppAttachmentContext()
    private var appVisibilitySubscription: AnyCancellable?

    init(settings suppliedSettings: SettingsStore? = nil, authenticator: NoteAuthenticator? = nil) {
        let override = ProcessInfo.processInfo.environment["SHIORI_DATA_DIR"]
        dataFolder = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("app.shiori.desktop", isDirectory: true)
        if let suppliedSettings { settings = suppliedSettings }
        else if let suite = ProcessInfo.processInfo.environment["SHIORI_DEFAULTS_SUITE"], let defaults = UserDefaults(suiteName: suite) { settings = SettingsStore(defaults: defaults) }
        else { settings = SettingsStore() }
        privacy = PrivacyLock(defaults: settings.defaults, authenticator: authenticator ?? TouchIDAuthenticator())
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !started else { return }; started = true
        installMenus()
        privacy.reportUnavailable = { message in
            let alert = NSAlert()
            alert.messageText = "SHIORI is locked"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        shortcuts = GlobalShortcutCoordinator(namespace: ProcessInfo.processInfo.environment["SHIORI_DEFAULTS_SUITE"] ?? "shiori") { [weak self] command in
            switch command {
            case .newNote: self?.newNote()
            case .quickSearch: self?.quickSearch()
            case .floatingNotes: self?.toggleFloating()
            }
        }
        Task { await load() }
        settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.edgeTabs.values.forEach { $0.refreshLayout() }
                self?.windows?.refreshVisibility()
            }
        }.store(in: &subscriptions)
        installLifecycleObservers()
    }
    func installLifecycleObservers() {
        guard !lifecycleInstalled else { return }
        lifecycleInstalled = true
        // Window close/minimize events in other apps have no NSWorkspace notification.
        appVisibilitySubscription = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAppVisibility() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(displaysChanged), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(self, selector: #selector(relock), name: name, object: nil)
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspace.addObserver(self, selector: #selector(refreshAppVisibility), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(applicationTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    @objc func refreshAppVisibility() {
        guard let windows, windows.store.active.contains(where: { $0.pinned && $0.attachedAppBundleIdentifier != nil }) else { return }
        windows.refreshVisibility()
    }
    func removeLifecycleObservers() {
        appVisibilitySubscription = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        lifecycleInstalled = false
    }
    @objc func applicationActivated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            appAttachment.record(app)
            windows?.refreshVisibility()
        }
        // The public workspace activation event also covers the login/lock screen becoming frontmost.
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier == "com.apple.loginwindow" { relock() }
    }
    @objc func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        appAttachment.terminated(app)
        windows?.refreshVisibility()
    }
    @objc func relock() { privacy.lock() }
    @objc func unlockNotes() { privacy.perform {} }
    func installMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "SHIORI")
        let menu = NSMenu()
        for (title, action, key) in [("Unlock SHIORI", #selector(unlockNotes), ""), ("New Note", #selector(newNote), "n"), ("Quick Search…", #selector(quickSearch), ""), ("Hide Floating Notes", #selector(toggleFloating), ""), ("Settings…", #selector(showSettings), ","), ("Quit SHIORI", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        menu.delegate = self
        statusItem.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = menu.copy() as? NSMenu
        appItem.submenu?.delegate = self
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"), ("Close", #selector(NSWindow.performClose(_:)), "w")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func load() async {
        guard store == nil else { return }
        do {
            let repository = try await NoteRepository.open(at: dataFolder.appendingPathComponent("notes.sqlite"))
            let loaded = NotesStore(repository: repository)
            try await loaded.load()
            if !settings.initialized {
                if loaded.notes.isEmpty {
                    let samples = [("A little room to think", "Keep the things you want close.\n\nHover at the screen edge to reach your notes.", 0), ("Today", "- [ ] Make something meaningful\n- [ ] Take a quiet break\n- [x] Start here", 2), ("Quelques idées", "Un café, une idée, un nouveau départ.\n\nمرحباً — مساحة لأفكارك", 4)]
                    for (title, body, color) in samples.reversed() {
                        let note = try await loaded.create()
                        loaded.edit(note.id, title: title, body: body, colorIndex: color)
                        try await loaded.flush(note.id)
                    }
                }
                settings.initialized = true
            }
            store = loaded
            let manager = StickyWindowManager(store: loaded, settings: settings, privacy: privacy, appAttachment: appAttachment, reportError: { [weak self] error in self?.present(error) })
            windows = manager
            manager.edgeFrame = { [weak self] id, screen in
                guard let self else { return nil }
                let display = EdgeDockController.displayID(for: screen ?? NSScreen.main)
                return display.flatMap { self.edgeTabs[$0]?.returnFrame(for: id) } ?? self.edgeTabs.values.first?.returnFrame(for: id)
            }
            synchronizeEdgeTabs()
            manager.restorePinned()
            do { _ = try await repository.backupIfNeeded(in: dataFolder.appendingPathComponent("Backups")) }
            catch { present(error, title: "The backup could not be created") }
        } catch {
            Self.logger.error("Database initialization failed (code \((error as NSError).code))")
            let alert = NSAlert()
            alert.messageText = "Your notes could not be opened"
            alert.informativeText = "Your existing data has been preserved. \(error.localizedDescription)"
            alert.addButton(withTitle: "Retry"); alert.addButton(withTitle: "Reveal Data Folder"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { await load() }
            else if response == .alertSecondButtonReturn { revealData() }
        }
    }
    func synchronizeEdgeTabs(screens: [NSScreen] = NSScreen.screens) {
        guard let store, let windows else { return }
        let ids = Set(screens.compactMap { EdgeDockController.displayID(for: $0) })
        for id in Array(edgeTabs.keys) where !ids.contains(id) { edgeTabs.removeValue(forKey: id)?.stop() }
        for screen in screens {
            guard let id = EdgeDockController.displayID(for: screen) else { continue }
            if edgeTabs[id] == nil {
                edgeTabs[id] = EdgeDockController(store: store, settings: settings, displayID: id, privacy: privacy,
                    open: { [weak windows] noteID, frame in windows?.open(noteID, near: nil, from: frame) },
                    create: { [weak self] in self?.createNote(on: screen) })
            }
            edgeTabs[id]?.refreshLayout()
        }
    }

    @objc func newNote() {
        if privacy.isLocked { privacy.perform { [weak self] in self?.newNote() }; return }
        createNote(on: NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
    }

    private func createNote(on screen: NSScreen?) {
        let point = screen.map { NSPoint(x: $0.visibleFrame.midX + Theme.editorSize.width / 2, y: $0.visibleFrame.midY) }
        guard let store else { return }
        Task {
            do {
                if let current = windows?.transient { try await store.flush(current) }
                let note = try await store.create()
                let source = EdgeDockController.displayID(for: screen).flatMap { edgeTabs[$0]?.creationFrame() }
                windows?.open(note.id, near: point, focusTitle: true, from: source)
            } catch { present(error) }
        }
    }
    @objc func quickSearch() {
        guard let store else { return }
        if searchController == nil {
            searchController = QuickSearchController(store: store, settings: settings, privacy: privacy, open: { [weak self] id in self?.windows?.open(id, near: nil) }, create: { [weak self] in self?.newNote() })
        }
        searchController?.show()
    }
    @objc func toggleFloating() { windows?.toggleHidden() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(unlockNotes) }?.isHidden = !privacy.isLocked
        menu.items.first { $0.action == #selector(toggleFloating) }?.title = windows?.hidden == true ? "Show Floating Notes" : "Hide Floating Notes"
    }
    @objc func displaysChanged() { synchronizeEdgeTabs(); windows?.clampWindows(); windows?.refreshVisibility() }
    @objc func willSleep() {
        relock()
        windows?.saveAllGeometry()
        Task { do { try await store?.flush() } catch { Self.logger.error("Sleep flush failed; draft retained") } }
    }
    func applicationWillTerminate(_ notification: Notification) {
        edgeTabs.values.forEach { $0.stop() }
        edgeTabs.removeAll()
        removeLifecycleObservers()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = standardWindow(title: "SHIORI Settings", size: NSSize(width: 460, height: 560), content: SettingsView(settings: settings, privacy: privacy, shortcuts: shortcuts, reset: { [weak self] in
                self?.settings.resetPositions(); self?.edgeTabs.values.forEach { $0.refreshLayout() }; self?.windows?.resetPositions()
            }))
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func backup() {
        guard let store else { return }
        Task {
            do {
                let url = try await store.backup(in: dataFolder.appendingPathComponent("Backups"))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { present(error, title: "The backup could not be created") }
        }
    }
    @objc func revealData() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dataFolder.path) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let store else { return .terminateNow }
        terminating = true
        sender.keyWindow?.makeFirstResponder(nil)
        Task {
            do {
                try await store.drain(); windows?.saveAllGeometry()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                present(error, title: "SHIORI stayed open to protect unsaved changes")
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func present(_ error: Error, title: String = "The change could not be saved") {
        Self.logger.error("Persistence operation failed (code \((error as NSError).code))")
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func standardWindow<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content); window.center()
        return window
    }
}
