import AppKit
import LocalAuthentication
import XCTest
@testable import SHIORI

@MainActor
private final class FakeNoteAuthenticator: NoteAuthenticator {
    var result: Result<Bool, Error> = .success(true)
    var calls = 0
    var cancellations = 0
    var pause = false
    var continuation: CheckedContinuation<Bool, Error>?
    func authenticate() async throws -> Bool {
        calls += 1
        if pause { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try result.get()
    }
    func cancel() { cancellations += 1 }
}

@MainActor
final class PrivacyMotionTests: XCTestCase {
    func testMultipleOpenNotesAndFocusRestoreWindowsAndStripe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIORI_RUN_WINDOW_TESTS"] == "1", "Desktop-interactive test; opt in with SHIORI_RUN_WINDOW_TESTS=1.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let repository = try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite"))
        let store = NotesStore(repository: repository)
        let first = try await store.create()
        let second = try await store.create()
        let settings = SettingsStore(defaults: defaults)
        let manager = StickyWindowManager(store: store, settings: settings, reportError: { XCTFail($0.localizedDescription) })
        let stripe = EdgeDockController(store: store, settings: settings, focus: manager.focus, open: { _, _ in }, create: {})
        defer { stripe.stop(); manager.windows.values.forEach { $0.close() } }
        manager.visibilityChanged = { stripe.refreshLayout() }
        manager.open(first.id, near: nil)
        manager.open(second.id, near: nil)
        for _ in 0..<100 {
            if manager.windows.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.windows.count, 2)
        XCTAssertTrue(manager.windows[first.id]?.isVisible == true)
        XCTAssertTrue(manager.windows[second.id]?.isVisible == true)
        manager.toggleFocus(first.id)
        XCTAssertTrue(manager.windows[first.id]?.isVisible == true)
        XCTAssertFalse(manager.windows[second.id]?.isVisible == true)
        XCTAssertEqual(stripe.displayedNotes.map(\.id), [first.id])
        manager.exitFocus()
        XCTAssertTrue(manager.windows[first.id]?.isVisible == true)
        XCTAssertTrue(manager.windows[second.id]?.isVisible == true)
        XCTAssertEqual(Set(stripe.displayedNotes.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(store.active.allSatisfy { !$0.pinned })
    }

    func testFocusTemporarilyFiltersNotesAndRestoresVisibilityRules() {
        let focus = NoteFocusState()
        let first = Note(id: "first", pinned: true)
        let second = Note(id: "second", pinned: true)
        XCTAssertTrue(focus.isVisible(first, hidden: false, matchesApp: true))
        XCTAssertTrue(focus.isVisible(second, hidden: false, matchesApp: true))
        focus.noteID = first.id
        XCTAssertTrue(focus.isVisible(first, hidden: false, matchesApp: false))
        XCTAssertFalse(focus.isVisible(second, hidden: false, matchesApp: true))
        focus.noteID = nil
        XCTAssertTrue(focus.isVisible(second, hidden: false, matchesApp: true))
        XCTAssertFalse(focus.isVisible(first, hidden: false, matchesApp: false))
        XCTAssertFalse(focus.isVisible(second, hidden: true, matchesApp: true))
        var deleted = first
        deleted.deletedAt = 1
        focus.noteID = deleted.id
        XCTAssertFalse(focus.isVisible(deleted, hidden: false, matchesApp: true))
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    func testPrivacyCoversLiveSurfacesAndRetainsDraftsWindowsAndLifecycle() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIORI_RUN_WINDOW_TESTS"] == "1", "Desktop-interactive test; opt in with SHIORI_RUN_WINDOW_TESTS=1.")
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "privacyEnabled")
        let settings = SettingsStore(defaults: defaults)
        let auth = FakeNoteAuthenticator()
        let coordinator = AppCoordinator(settings: settings, authenticator: auth)
        let privacy = coordinator.privacy
        XCTAssertTrue(privacy.isLocked)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite"))
        let store = NotesStore(repository: repository, debounce: .seconds(60))
        let note = try await store.create()
        try await store.setPinned(note.id, pinned: true)
        store.edit(note.id, title: "Secret title", body: "Private unsaved مرحباً")
        let manager = StickyWindowManager(store: store, settings: settings, privacy: privacy) { _ in XCTFail("Unexpected save error") }
        coordinator.store = store; coordinator.windows = manager
        coordinator.synchronizeEdgeTabs()
        coordinator.installLifecycleObservers(); coordinator.installLifecycleObservers()
        XCTAssertTrue(coordinator.lifecycleInstalled)
        defer {
            coordinator.removeLifecycleObservers()
            coordinator.edgeTabs.values.forEach { $0.stop() }
            manager.windows.values.forEach { $0.orderOut(nil) }
        }
        manager.restorePinned()
        let window = try XCTUnwrap(manager.windows[note.id])
        let cover = try XCTUnwrap(window.contentView as? PrivateNoteContent)
        let originalEditor = cover.editor
        XCTAssertTrue(originalEditor.isHidden)
        XCTAssertFalse(window.makeFirstResponder(originalEditor))
        let unlockButton = try XCTUnwrap(cover.accessibilityChildren()?.first as? NSButton)
        XCTAssertEqual(unlockButton.title, "Unlock SHIORI")
        XCTAssertTrue(cover.bounds.contains(unlockButton.frame))
        XCTAssertGreaterThan(unlockButton.frame.width, 0)
        XCTAssertTrue(privacy.search("", in: store).isEmpty)
        for panel in NSApp.windows where panel.contentView?.accessibilityLabel() == "SHIORI edge notes" {
            let labels = panel.contentView?.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() } ?? []
            XCTAssertFalse(labels.contains("Secret title"))
            XCTAssertTrue(labels.contains("Locked note"))
        }
        let concealed = PrivacyLock.concealed(store.note(id: note.id)!)
        XCTAssertEqual(concealed.title, ""); XCTAssertEqual(concealed.body, "")
        XCTAssertEqual(concealed.colorIndex, note.colorIndex)
        let search = QuickSearchController(store: store, settings: settings, privacy: privacy, open: { _ in }, create: {})
        let result1 = await privacy.unlock()
        XCTAssertTrue(result1)
        XCTAssertFalse(originalEditor.isHidden)
        search.show()
        XCTAssertTrue(search.isVisible)
        privacy.lock()
        XCTAssertFalse(search.isVisible)
        let frame = window.frame
        let panelCount = coordinator.edgeTabs.count
        let memoryBefore = residentBytes()
        let windowCount = NSApp.windows.count
        for _ in 0..<12 {
            let result2 = await privacy.unlock()
            XCTAssertTrue(result2)
            coordinator.willSleep()
            XCTAssertTrue(privacy.isLocked)
            XCTAssertTrue(originalEditor.isHidden)
            coordinator.displaysChanged()
            XCTAssertEqual(coordinator.edgeTabs.count, panelCount)
            XCTAssertEqual(manager.windows.count, 1)
            XCTAssertTrue((window.contentView as? PrivateNoteContent)?.editor === originalEditor)
            XCTAssertEqual(window.frame, frame)
            XCTAssertTrue(store.note(id: note.id)!.pinned)
            XCTAssertEqual(store.note(id: note.id)?.body, "Private unsaved مرحباً")
        }
        let result3 = await privacy.unlock()
        XCTAssertTrue(result3)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertTrue(privacy.isLocked)
        coordinator.removeLifecycleObservers(); coordinator.removeLifecycleObservers()
        XCTAssertFalse(coordinator.lifecycleInstalled)
        print("Privacy/lifecycle resident bytes before: \(memoryBefore), after: \(residentBytes())")
        XCTAssertEqual(NSApp.windows.count, windowCount)
        let result4 = await privacy.unlock()
        XCTAssertTrue(result4)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(privacy.isLocked)
        manager.toggleHidden(); XCTAssertFalse(window.isVisible)
        manager.toggleHidden(); XCTAssertTrue(window.isVisible)
        try await store.flush()
    }

    func testAuthenticationFailuresStaleRepliesAndSpatialTransitionCleanup() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIORI_RUN_WINDOW_TESTS"] == "1", "Desktop-interactive test; opt in with SHIORI_RUN_WINDOW_TESTS=1.")
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "privacyEnabled")
        let auth = FakeNoteAuthenticator()
        let privacy = PrivacyLock(defaults: defaults, authenticator: auth)
        for code in [LAError.Code.userCancel, .authenticationFailed, .biometryNotAvailable] {
            auth.result = .failure(LAError(code))
            let result5 = await privacy.unlock()
            XCTAssertFalse(result5)
            XCTAssertTrue(privacy.isLocked)
        }
        XCTAssertNotNil(privacy.error)
        await privacy.setEnabled(false)
        XCTAssertTrue(privacy.enabled)
        auth.pause = true
        let pending = Task { await privacy.unlock() }
        await Task.yield()
        let calls = auth.calls
        let result6 = await privacy.unlock()
        XCTAssertFalse(result6)
        XCTAssertEqual(auth.calls, calls)
        privacy.lock()
        auth.continuation?.resume(returning: true); auth.continuation = nil
        let result7 = await pending.value
        XCTAssertFalse(result7)
        XCTAssertTrue(privacy.isLocked)
        auth.pause = false; auth.result = .success(true)
        await privacy.setEnabled(false)
        XCTAssertFalse(privacy.enabled)
        auth.result = .failure(LAError(.biometryNotAvailable))
        await privacy.setEnabled(true)
        XCTAssertFalse(privacy.enabled)

        XCTAssertEqual(Theme.Motion.duration(Theme.Motion.editorOpen, reduceMotion: true), 0.12)
        XCTAssertEqual(Theme.Motion.progress(0), 0)
        XCTAssertEqual(Theme.Motion.progress(1), 1)
        let progress = (0...100).map { Theme.Motion.progress(Double($0) / 100) }
        XCTAssertEqual(progress, progress.sorted())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite"))
        let store = NotesStore(repository: repository)
        let settings = SettingsStore(defaults: defaults)
        let manager = StickyWindowManager(store: store, settings: settings) { _ in XCTFail("Unexpected error") }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let source = NSRect(x: screen.visibleFrame.maxX - 40, y: screen.visibleFrame.midY, width: 224, height: 170)
        manager.edgeFrame = { _, _ in source }
        for reduced in [false, true] {
            manager.reduceMotion = { reduced }
            let note = try await store.create()
            for _ in 0..<5 { manager.open(note.id, near: nil, from: source) }
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(manager.windows.count, 1)
            let window = try XCTUnwrap(manager.windows[note.id])
            let finalFrame = window.frame
            XCTAssertEqual(manager.transitioningCount, 0)
            manager.close(note.id)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertNil(manager.windows[note.id])
            XCTAssertEqual(settings.frame(id: note.id), finalFrame)
            XCTAssertEqual(manager.transitioningCount, 0)
            XCTAssertNil(window.contentView)
            XCTAssertNil(window.requestClose)
            manager.open(note.id, near: nil, from: source)
            try await Task.sleep(for: .milliseconds(350))
            weak var deletedEditor = manager.windows[note.id]?.contentView
            manager.delete(note.id)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertNil(manager.windows[note.id])
            // SwiftUI releases its render graph on a subsequent run-loop turn.
            for _ in 0..<100 {
                if deletedEditor == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(deletedEditor)
        }
    }
}
