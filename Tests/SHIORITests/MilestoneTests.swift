import XCTest
import AppKit
import GRDB
import KeyboardShortcuts
import ServiceManagement
@testable import SHIORI

@MainActor
final class MilestoneTests: XCTestCase {
    private func database() async throws -> (URL, NoteRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite")))
    }

    func testSearchUsesLiveDraftsAndExcludesInactiveNotes() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(repository: repository, debounce: .seconds(60))
        let note = try await store.create()
        store.edit(note.id, title: "Une idée", body: "Bonjour مرحباً 😀")
        for query in ["IDEE", "bonjour", "مرح", "😀"] { XCTAssertEqual(store.search(query).map(\.id), [note.id]) }
        let durable = try await repository.loadActiveNotes()
        XCTAssertEqual(durable.first?.body, "")
        let second = try await store.create()
        XCTAssertEqual(store.search("").map(\.id), [second.id, note.id])
        try await store.delete(note.id)
        XCTAssertTrue(store.search("idee").isEmpty)
        try await store.complete(second.id)
        XCTAssertTrue(store.search("").isEmpty)
    }

    func testDeleteFlushUndoAndReopenPreserveEntireRecord() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(repository: repository, debounce: .seconds(60))
        let note = try await store.create()
        try await store.setPinned(note.id, pinned: true)
        store.edit(note.id, title: "Idée", body: "- [ ] مرحباً 😀", colorIndex: 4)
        let original = try XCTUnwrap(store.note(id: note.id))
        try await store.delete(note.id)
        XCTAssertTrue(store.active.isEmpty)
        let reopened = try await NoteRepository.open(at: repository.databaseURL)
        let active = try await reopened.loadActiveNotes()
        XCTAssertTrue(active.isEmpty)
        let queue = try DatabaseQueue(path: repository.databaseURL.path)
        let deleted = try await queue.read { try Note.fetchOne($0, key: note.id) }
        XCTAssertNotNil(deleted?.deletedAt)
        XCTAssertEqual(deleted?.body, original.body)
        XCTAssertEqual(deleted?.sortIndex, original.sortIndex)
        do { try await repository.updateText(id: note.id, title: "stale", body: "stale"); XCTFail("Deleted row accepted a stale write") } catch {}
        try await store.undoDelete(note.id)
        XCTAssertEqual(store.active.first, original)
        let restored = try await reopened.loadActiveNotes()
        XCTAssertEqual(restored.first, original)
    }

    func testUpgradePreservesLegacyRowsAndArchiveMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('001_create_notes');
                CREATE TABLE note (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
                    colorIndex INTEGER NOT NULL, pinned INTEGER NOT NULL, createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL, sortIndex REAL NOT NULL, archivedAt REAL, doneAt REAL);
                INSERT INTO note VALUES ('legacy', 'Café', 'مرحبا', 2, 1, 1, 2, 3, NULL, NULL);
                INSERT INTO note VALUES ('archived', 'Old', 'Preserved', 0, 0, 1, 2, 4, 5, 5);
                """)
        }
        let repository = try await NoteRepository.open(at: url)
        let active = try await repository.loadActiveNotes()
        XCTAssertEqual(active.first?.id, "legacy")
        XCTAssertNil(active.first?.deletedAt)
        XCTAssertEqual(active.first?.body, "مرحبا")
        let archived = try await repository.loadArchivedNotes()
        XCTAssertEqual(archived.first?.archivedAt, 5)
        XCTAssertEqual(archived.first?.body, "Preserved")
    }

    func testFailedFlushPreventsDeletion() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(repository: repository, debounce: .seconds(60), writeOverride: { _, _, _ in throw CocoaError(.fileWriteUnknown) })
        let note = try await store.create()
        store.edit(note.id, body: "Unsaved")
        do { try await store.delete(note.id); XCTFail("Expected failed flush") } catch {}
        XCTAssertEqual(store.active.first?.body, "Unsaved")
        XCTAssertNotNil(store.drafts[note.id])
        XCTAssertFalse(store.isBusy(note.id))
        let active = try await repository.loadActiveNotes()
        XCTAssertEqual(active.count, 1)
    }

    func testFormattingCommandsAndUnicodeRanges() throws {
        let text = "Café 😀 العربية"
        let selection = NSRange(location: 0, length: text.utf16.count)
        for (format, expected) in [(MarkdownFormat.bold, "**\(text)**"), (.italic, "_\(text)_"), (.strike, "~~\(text)~~"), (.code, "`\(text)`"), (.link, "[\(text)]()"), (.h1, "# \(text)"), (.h2, "## \(text)"), (.bullet, "- \(text)"), (.checklist, "- [ ] \(text)")] {
            let edit = try XCTUnwrap(MarkdownFormattingEngine.edit(format, text: text, selection: selection))
            XCTAssertEqual(edit.applying(to: text), expected)
        }
        let emoji = (text as NSString).range(of: "😀")
        let wrapped = try XCTUnwrap(MarkdownFormattingEngine.edit(.bold, text: text, selection: emoji))
        XCTAssertEqual(wrapped.applying(to: text), "Café **😀** العربية")
        let unwrapped = try XCTUnwrap(MarkdownFormattingEngine.edit(.bold, text: wrapped.applying(to: text), selection: wrapped.selectionAfter!))
        XCTAssertEqual(unwrapped.applying(to: wrapped.applying(to: text)), text)
        let tasks = "- [ ] one\n- [x] two"
        let bodyRange = (tasks as NSString).range(of: "one")
        let boldTask = try XCTUnwrap(MarkdownFormattingEngine.edit(.bold, text: tasks, selection: bodyRange))
        XCTAssertEqual(ChecklistEngine.tasks(in: boldTask.applying(to: tasks)).count, 2)
        let lines = "one\ntwo\nthree"
        let headings = try XCTUnwrap(MarkdownFormattingEngine.edit(.h2, text: lines, selection: NSRange(location: 0, length: 8)))
        XCTAssertEqual(headings.applying(to: lines), "## one\n## two\nthree")
        let link = "[café](https://example.com)"
        XCTAssertEqual(MarkdownFormattingEngine.edit(.link, text: link, selection: NSRange(location: 3, length: 0))?.selectionAfter, (link as NSString).range(of: "https://example.com"))
        XCTAssertEqual(MarkdownFormattingEngine.edit(.bold, text: "", selection: NSRange(location: 0, length: 0))?.selectionAfter, NSRange(location: 2, length: 0))
        XCTAssertNil(MarkdownFormattingEngine.edit(.bold, text: "😀", selection: NSRange(location: 1, length: 0)))
        XCTAssertEqual(ChecklistEngine.returnEdit(in: "- item", selection: NSRange(location: 6, length: 0))?.applying(to: "- item"), "- item\n- ")
        XCTAssertNotNil(ChecklistEngine.returnEdit(in: "- [ ] task", selection: NSRange(location: 10, length: 0)))
    }

    func testNativeFormattingUndoRedoAndMarkedTextSafety() {
        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = editor
        editor.isRichText = false; editor.allowsUndo = true
        editor.string = "Café 😀"
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.formatText(.bold)
        XCTAssertEqual(editor.string, "**Café 😀**")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "Café 😀")
        editor.undoManager?.redo()
        XCTAssertEqual(editor.string, "**Café 😀**")
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let composed = editor.string
        editor.formatText(.italic)
        XCTAssertEqual(editor.string, composed)
        window.orderOut(nil)
    }

    func testShortcutDefaultsPersistenceResetAndRouting() {
        let namespace = "tests.\(UUID().uuidString)"
        var commands: [GlobalShortcutCoordinator.Command] = []
        let shortcuts = GlobalShortcutCoordinator(namespace: namespace, registersHotkeys: false) { commands.append($0) }
        defer {
            for command in GlobalShortcutCoordinator.Command.allCases {
                UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_\(namespace).\(command.rawValue)")
            }
        }
        for command in GlobalShortcutCoordinator.Command.allCases {
            XCTAssertEqual(KeyboardShortcuts.getShortcut(for: shortcuts.name(command)), command.defaultShortcut)
            shortcuts.perform(command)
        }
        XCTAssertEqual(commands, GlobalShortcutCoordinator.Command.allCases)
        let custom = KeyboardShortcuts.Shortcut(.j, modifiers: [.command, .option])
        KeyboardShortcuts.setShortcut(custom, for: shortcuts.name(.newNote))
        let other = GlobalShortcutCoordinator(namespace: namespace, registersHotkeys: false) { _ in }
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: other.name(.newNote)), custom)
        KeyboardShortcuts.setShortcut(nil, for: shortcuts.name(.quickSearch))
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: shortcuts.name(.quickSearch)))
        shortcuts.reset()
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: shortcuts.name(.newNote)), GlobalShortcutCoordinator.Command.newNote.defaultShortcut)
    }

    func testLoginStateAndErrorsWithoutChangingOSRegistration() async {
        var status = SMAppService.Status.notRegistered
        let service = LaunchAtLoginService(readStatus: { status }, register: { status = .requiresApproval }, unregister: { status = .notRegistered })
        await service.setEnabled(true)
        XCTAssertEqual(service.status, .requiresApproval)
        status = .enabled; service.refresh()
        XCTAssertEqual(service.status, .enabled)
        await service.setEnabled(false)
        XCTAssertEqual(service.status, .notRegistered)
        let failing = LaunchAtLoginService(readStatus: { .notRegistered }, register: { throw CocoaError(.fileWriteNoPermission) }, unregister: {})
        await failing.setEnabled(true)
        XCTAssertNotNil(failing.error)
        XCTAssertEqual(failing.status, .notRegistered)
        XCTAssertFalse(failing.busy)
    }

    func testFloatingVisibilityPreservesPinAndGeometry() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let store = NotesStore(repository: repository)
        let note = try await store.create()
        try await store.setPinned(note.id, pinned: true)
        let manager = StickyWindowManager(store: store, settings: settings) { _ in XCTFail("Unexpected window error") }
        manager.restorePinned()
        let window = try XCTUnwrap(manager.windows[note.id])
        let frame = window.frame
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let headerY: CGFloat = content.isFlipped ? 6 : content.bounds.height - 6
        let headerPoint = content.convert(NSPoint(x: 30, y: headerY), to: content.superview)
        XCTAssertTrue(content.hitTest(headerPoint) is HeaderDragArea.DragView, "Header hit: \(String(describing: content.hitTest(headerPoint)))")
        let preferences = defaults.dictionaryRepresentation()
        manager.toggleHidden()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(store.note(id: note.id)!.pinned)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, preferences as NSDictionary)
        manager.toggleHidden()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame, frame)
        let saved = try await repository.loadActiveNotes()
        XCTAssertTrue(saved.first!.pinned)
        window.orderOut(nil)
    }

    func testEdgeTabsCoverConnectedDisplaysAndReuseEditor() async throws {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { throw XCTSkip("Requires two connected displays") }
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let store = NotesStore(repository: repository)
        let note = try await store.create()
        try await store.setPinned(note.id, pinned: true)
        let manager = StickyWindowManager(store: store, settings: settings) { _ in XCTFail("Unexpected error") }
        let coordinator = AppCoordinator(settings: settings)
        coordinator.store = store; coordinator.windows = manager
        defer {
            coordinator.edgeTabs.values.forEach { $0.stop() }
            manager.windows.values.forEach { $0.orderOut(nil) }
        }
        coordinator.synchronizeEdgeTabs(screens: screens)
        XCTAssertEqual(coordinator.edgeTabs.count, screens.count)
        let firstID = try XCTUnwrap(EdgeDockController.displayID(for: screens[0]))
        let first = try XCTUnwrap(coordinator.edgeTabs[firstID])
        coordinator.synchronizeEdgeTabs(screens: [screens[0]])
        XCTAssertEqual(coordinator.edgeTabs.count, 1)
        coordinator.synchronizeEdgeTabs(screens: screens)
        XCTAssertTrue(coordinator.edgeTabs[firstID] === first)
        XCTAssertEqual(coordinator.edgeTabs.count, screens.count)
        manager.restorePinned()
        let window = try XCTUnwrap(manager.windows[note.id])
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        for screen in screens.reversed() {
            let id = try XCTUnwrap(EdgeDockController.displayID(for: screen))
            let frame = try XCTUnwrap(coordinator.edgeTabs[id]?.cardScreenFrame(for: note.id))
            XCTAssertTrue(screen.frame.intersects(frame))
            manager.open(note.id, near: nil, from: frame)
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(10))
                if window.screen == screen { break }
            }
            XCTAssertEqual(window.screen, screen)
            XCTAssertTrue(manager.windows[note.id] === window)
            XCTAssertEqual(manager.windows.count, 1)
            XCTAssertTrue(store.note(id: note.id)!.pinned)
        }
    }

    func testGlobalBodyFontsPersistAndUpdateWithoutChangingEditingState() throws {
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.noteFont, .architectsDaughter)
        XCTAssertEqual(settings.bodyFont.fontName, "ArchitectsDaughter-Regular")
        XCTAssertEqual(settings.noteFontSize, 16)
        settings.noteFont = .indieFlower; settings.noteFontSize = 22
        XCTAssertEqual(settings.bodyFont.fontName, "IndieFlower-Regular")
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.noteFont, .indieFlower)
        XCTAssertEqual(restored.bodyFont.pointSize, 22)

        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 1200))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: true)
        scroll.documentView = editor; window.contentView = scroll
        defer { window.orderOut(nil) }
        editor.isRichText = false; editor.allowsUndo = true
        editor.string = String(repeating: "Café 😀 مرحباً\n", count: 30)
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.formatText(.bold)
        let source = editor.string, selection = editor.selectedRanges
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let origin = scroll.contentView.bounds.origin
        editor.setBodyFont(settings.bodyFont)
        XCTAssertEqual(editor.string, source)
        let bold = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertEqual(editor.selectedRanges, selection)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertEqual(editor.typingAttributes[.font] as? NSFont, settings.bodyFont)
        editor.undoManager?.undo()
        XCTAssertFalse(editor.string.hasPrefix("**"))
        editor.undoManager?.redo()
        XCTAssertEqual(editor.string, source)
        settings.noteFont = .kalam
        XCTAssertEqual(settings.bodyFont.fontName, "Kalam-Regular")
        XCTAssertEqual(SettingsStore(defaults: defaults).noteFont, .kalam)
        settings.noteFont = .system
        XCTAssertEqual(settings.bodyFont, NSFont.systemFont(ofSize: 22))
    }

    func testFontPreferenceRecoveryAndIMECompositionDefersAppearance() {
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Unknown font", forKey: "noteFont")
        defaults.set(100, forKey: "noteFontSize")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.noteFont, .architectsDaughter)
        XCTAssertEqual(settings.noteFontSize, 24)
        settings.noteFontSize = 2
        XCTAssertEqual(settings.noteFontSize, 14)
        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let oldFont = editor.bodyFont
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let marked = editor.markedRange(), selection = editor.selectedRange(), source = editor.string
        editor.setBodyFont(settings.bodyFont)
        XCTAssertEqual(editor.bodyFont, oldFont)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, source)
        editor.unmarkText()
        XCTAssertEqual(editor.bodyFont, settings.bodyFont)
        XCTAssertEqual(editor.string, source)
    }

    func testValidFramesRemainUnchanged() {
        let screens = [NSRect(x: -1920, y: -200, width: 1920, height: 1080), NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let frame = NSRect(x: -1000, y: 100, width: 360, height: 400)
        XCTAssertEqual(WindowGeometry.clamp(frame, to: screens), frame)
        XCTAssertTrue(screens[1].contains(WindowGeometry.clamp(frame, to: [screens[1]])))
    }
}
