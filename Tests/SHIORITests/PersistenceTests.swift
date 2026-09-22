import AppKit
import Foundation
import XCTest
@testable import SHIORI

final class PersistenceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testMigrationReopenAndFieldPersistence() async throws {
        let (root, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let note = try await repository.create()
        try await repository.updateText(id: note.id, title: "Café", body: "مرحباً")
        try await repository.updateColor(id: note.id, colorIndex: 4)
        try await repository.setPinned(id: note.id, pinned: true)

        let reopened = try await NoteRepository.open(at: databaseURL)
        let loaded = try await reopened.loadActiveNotes()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Café")
        XCTAssertEqual(loaded[0].body, "مرحباً")
        XCTAssertEqual(loaded[0].colorIndex, 4)
        XCTAssertTrue(loaded[0].pinned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testAppAttachmentPersistsDraftAndDetaches() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let store = NotesStore(repository: repository)
        let note = try await store.create()
        store.edit(note.id, body: "Keep this edit")
        let bundleID = "test.application." + UUID().uuidString
        try await store.setAttachedApp(note.id, bundleIdentifier: bundleID)
        let reopened = try await NoteRepository.open(at: databaseURL)
        let loaded = try await reopened.loadActiveNotes()
        XCTAssertEqual(loaded.first?.attachedAppBundleIdentifier, bundleID)
        XCTAssertEqual(loaded.first?.body, "Keep this edit")
        XCTAssertEqual(loaded.first?.pinned, true)
        let manager = StickyWindowManager(store: store, settings: SettingsStore(), reportError: { XCTFail($0.localizedDescription) })
        XCTAssertFalse(manager.matchesApp(try XCTUnwrap(store.note(id: note.id))))
        try await store.setAttachedApp(note.id, bundleIdentifier: nil)
        XCTAssertTrue(manager.matchesApp(try XCTUnwrap(store.note(id: note.id))))
        let detached = try await reopened.loadActiveNotes()
        XCTAssertNil(detached.first?.attachedAppBundleIdentifier)
        XCTAssertEqual(detached.first?.pinned, true)
    }

    @MainActor
    func testAppAttachmentRejectsDeletedNote() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let store = NotesStore(repository: repository)
        let note = try await store.create()
        try await store.delete(note.id)
        do {
            try await store.setAttachedApp(note.id, bundleIdentifier: UUID().uuidString)
            XCTFail("Deleted notes must not be attached")
        } catch {
            XCTAssertEqual(error as? NoteRepositoryError, .noteUnavailable)
        }
        XCTAssertNil(store.note(id: note.id)?.attachedAppBundleIdentifier)
        XCTAssertFalse(store.isBusy(note.id))
    }

    @MainActor
    func testAppWindowVisibilityAndTerminationPreserveAttachment() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIORI_RUN_WINDOW_TESTS"] == "1", "Desktop-interactive test; opt in with SHIORI_RUN_WINDOW_TESTS=1.")
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let store = NotesStore(repository: repository)
        let note = try await store.create()
        let coordinator = AppCoordinator()
        let app = try XCTUnwrap(coordinator.appAttachment.runningApps.first(where: { !$0.isHidden }))
        let bundleID = try XCTUnwrap(app.bundleIdentifier)
        let visibleWindow: [String: Any] = [
            kCGWindowOwnerPID as String: app.processIdentifier,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600]
        ]
        coordinator.appAttachment.windowInfo = { [visibleWindow] }
        coordinator.appAttachment.record(app)
        try await store.setAttachedApp(note.id, bundleIdentifier: bundleID)
        let manager = StickyWindowManager(store: store, settings: coordinator.settings,
            appAttachment: coordinator.appAttachment, reportError: { XCTFail($0.localizedDescription) })
        coordinator.windows = manager
        let panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        manager.windows[note.id] = panel
        defer { panel.close(); manager.windows.removeAll(); coordinator.removeLifecycleObservers() }
        panel.orderFrontRegardless()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(manager.matchesApp(try XCTUnwrap(store.note(id: note.id))))
        coordinator.installLifecycleObservers()
        // Closing or minimizing the last app window removes it from the on-screen list.
        coordinator.appAttachment.windowInfo = { [] }
        coordinator.refreshAppVisibility()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(coordinator.appAttachment.currentBundleIdentifier, bundleID)
        XCTAssertEqual(store.note(id: note.id)?.attachedAppBundleIdentifier, bundleID)
        // A menu/popup or another app's window must not keep the note visible.
        var popup = visibleWindow
        popup[kCGWindowLayer as String] = 3
        var otherWindow = visibleWindow
        otherWindow[kCGWindowOwnerPID as String] = ProcessInfo.processInfo.processIdentifier
        coordinator.appAttachment.windowInfo = { [popup, otherWindow] }
        coordinator.refreshAppVisibility()
        XCTAssertFalse(panel.isVisible)
        coordinator.appAttachment.windowInfo = { [visibleWindow] }
        coordinator.refreshAppVisibility()
        XCTAssertTrue(panel.isVisible)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: app])
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(coordinator.appAttachment.currentBundleIdentifier)
        XCTAssertEqual(store.note(id: note.id)?.attachedAppBundleIdentifier, bundleID)
        coordinator.appAttachment.record(app)
        manager.refreshVisibility()
        XCTAssertTrue(panel.isVisible)
    }

    func testOrderCompleteRestoreAndSearch() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let first = try await repository.create()
        let second = try await repository.create()
        try await repository.updateText(id: first.id, title: "Café", body: "- [ ] Départ")
        try await repository.updateText(id: second.id, title: "Arabic", body: "مرحبا بالعالم")

        try await repository.reorder(ids: [first.id, second.id])
        let ordered = try await repository.loadActiveNotes()
        XCTAssertEqual(ordered.map(\.id), [first.id, second.id])
        let cafeMatches = try await repository.search("CAFE", archived: false)
        XCTAssertEqual(cafeMatches.map(\.id), [first.id])
        let arabicMatches = try await repository.search("مرحبا", archived: false)
        XCTAssertEqual(arabicMatches.map(\.id), [second.id])

        try await repository.complete(id: first.id, body: "- [x] Départ")
        let activeAfterComplete = try await repository.loadActiveNotes()
        let archivedAfterComplete = try await repository.loadArchivedNotes()
        XCTAssertEqual(activeAfterComplete.map(\.id), [second.id])
        XCTAssertEqual(archivedAfterComplete.map(\.id), [first.id])

        try await repository.restore(id: first.id)
        let restored = try await repository.loadActiveNotes()
        XCTAssertEqual(restored.first?.id, first.id)
        XCTAssertEqual(restored.first?.body, "- [x] Départ")
        XCTAssertFalse(restored.first?.pinned ?? true)
    }

    @MainActor
    func testStoreFlushPersistsImmediateDraft() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let store = NotesStore(repository: repository, debounce: .seconds(60), maxInterval: .seconds(60))
        try await store.load()
        let note = try await store.create()
        store.edit(note.id, title: "Immediate", body: "- [ ] Unicode ✅")
        XCTAssertEqual(store.note(id: note.id)?.title, "Immediate")
        XCTAssertEqual(store.saveStatus(note.id), "Saving…")

        try await store.flush(note.id)
        XCTAssertEqual(store.saveStatus(note.id), "Saved")
        let reopened = try await NoteRepository.open(at: databaseURL)
        let saved = try await reopened.loadActiveNotes().first { $0.id == note.id }
        XCTAssertEqual(saved?.title, "Immediate")
        XCTAssertEqual(saved?.body, "- [ ] Unicode ✅")
    }

    func testBackupReopensAndRetainsExpectedData() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let note = try await repository.create()
        try await repository.updateText(id: note.id, title: "Backup", body: "Persist me")
        let backupDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups")

        let backupURL = try await repository.backup(in: backupDirectory)
        let backup = try await NoteRepository.open(at: backupURL)
        let notes = try await backup.loadActiveNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].body, "Persist me")
    }

    func testBackupRetentionKeepsSevenNewestSnapshots() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let backupDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups")
        for _ in 0..<8 {
            _ = try await repository.backup(in: backupDirectory)
        }
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("notes-") }
        XCTAssertEqual(snapshots.count, 7)
    }

    func testSaveFailureRetainsDirtyDraft() async throws {
        let (_, databaseURL) = try makeDatabaseURL()
        let repository = try await NoteRepository.open(at: databaseURL)
        let store = await MainActor.run {
            NotesStore(
                repository: repository,
                debounce: .seconds(60),
                maxInterval: .seconds(60),
                writeOverride: { _, _, _ in throw PersistenceTestError.failure }
            )
        }
        let note = try await store.create()
        await store.edit(note.id, body: "Keep this draft")
        do {
            try await store.flush(note.id)
            XCTFail("Expected the injected write to fail")
        } catch {
            // The draft remains available for retry after a failed write.
        }
        let retained = await MainActor.run { store.drafts[note.id]?.body }
        XCTAssertEqual(retained, "Keep this draft")
        let hasError = await MainActor.run { store.hasError(note.id) }
        XCTAssertTrue(hasError)
    }

    private func makeDatabaseURL() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SHIORI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return (root, root.appendingPathComponent("notes.sqlite"))
    }
}

private enum PersistenceTestError: Error, Sendable {
    case failure
}
