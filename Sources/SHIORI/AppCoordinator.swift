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
final class AppCoordinator: NSObject, NSApplicationDelegate {
    static let logger = Logger(subsystem: "app.shiori.desktop", category: "application")
    let settings: SettingsStore
    let dataFolder: URL
    var store: NotesStore?
    var windows: StickyWindowManager?
    var dock: EdgeDockController?
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var subscriptions = Set<AnyCancellable>()
    var terminating = false

    override init() {
        let override = ProcessInfo.processInfo.environment["SHIORI_DATA_DIR"]
        dataFolder = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("app.shiori.desktop", isDirectory: true)
        if let suite = ProcessInfo.processInfo.environment["SHIORI_DEFAULTS_SUITE"], let defaults = UserDefaults(suiteName: suite) { settings = SettingsStore(defaults: defaults) }
        else { settings = SettingsStore() }
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        installMenus()
        Task { await load() }
        settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.dock?.refreshLayout()
                self?.windows?.refreshVisibility()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func installMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "SHIORI")
        let menu = NSMenu()
        for (title, action, key) in [("New Note", #selector(newNote), "n"), ("Show/Hide Deck", #selector(toggleDeck), ""), ("Hide/Show Floating Notes", #selector(toggleFloating), ""), ("Settings…", #selector(showSettings), ","), ("Back Up Now", #selector(backup), ""), ("Reveal Data Folder", #selector(revealData), ""), ("Quit SHIORI", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = menu.copy() as? NSMenu
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
            let manager = StickyWindowManager(store: loaded, settings: settings, reportError: { [weak self] error in self?.present(error) })
            windows = manager
            dock = EdgeDockController(store: loaded, settings: settings, open: { [weak manager] id, frame in manager?.open(id, near: nil, from: frame) }, create: { [weak self] in self?.newNote() })
            manager.deckFrame = { [weak dock] id in dock?.cardScreenFrame(for: id) }
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
    @objc func newNote() {
        guard let store else { return }
        Task {
            do {
                try await windows?.closeTransient()
                let note = try await store.create()
                windows?.open(note.id, near: nil, focusTitle: true)
            } catch { present(error) }
        }
    }
    @objc func toggleDeck() { dock?.toggle() }
    @objc func toggleFloating() { windows?.toggleHidden() }
    @objc func displaysChanged() { dock?.refreshLayout(); windows?.clampWindows() }
    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = standardWindow(title: "SHIORI Settings", size: NSSize(width: 390, height: 310), content: SettingsView(settings: settings, reset: { [weak self] in
                self?.settings.resetPositions(); self?.dock?.refreshLayout(); self?.windows?.resetPositions()
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
