import XCTest
import AppKit
@testable import SHIORI

final class DockTests: XCTestCase {
    func testHoverStateTransitionsCancelStaleOpenAndClose() {
        var state = DockStateMachine()
        XCTAssertEqual(state.phase, .collapsed)

        state.pointerEntered()
        XCTAssertEqual(state.phase, .pendingOpen)
        state.pointerExited()
        XCTAssertEqual(state.phase, .collapsed)
        state.openDelayElapsed()
        XCTAssertEqual(state.phase, .collapsed)

        state.pointerEntered()
        state.openDelayElapsed()
        XCTAssertEqual(state.phase, .expanded)
        state.pointerExited()
        XCTAssertEqual(state.phase, .pendingClose)
        state.pointerEntered()
        XCTAssertEqual(state.phase, .expanded)
        state.closeDelayElapsed()
        XCTAssertEqual(state.phase, .expanded)
    }

    func testExplicitShowAndHideAreIdempotent() {
        var state = DockStateMachine()
        state.showImmediately()
        state.showImmediately()
        XCTAssertEqual(state.phase, .expanded)
        state.hideImmediately()
        state.hideImmediately()
        XCTAssertEqual(state.phase, .collapsed)
    }
    @MainActor
    func testLinkedCardReturnsToAppBorderAndFollowsFrontWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let repository = try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite"))
        let store = NotesStore(repository: repository)
        let settings = SettingsStore(defaults: defaults)
        settings.edge = "right"
        let context = AppAttachmentContext()
        let app = try XCTUnwrap(context.runningApps.first(where: { !$0.isHidden }))
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let original = screen.visibleFrame.insetBy(dx: 100, dy: 100)
        func windowInfo(_ frame: NSRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: app.processIdentifier,
             kCGWindowNumber as String: CGWindowID(123),
             kCGWindowIsOnscreen as String: true,
             kCGWindowLayer as String: 0,
             kCGWindowBounds as String: ["X": frame.minX, "Y": screen.frame.maxY - frame.maxY,
                                        "Width": frame.width, "Height": frame.height]]
        }
        context.windowInfo = { [windowInfo(original)] }
        context.record(app)
        let linked = try await store.create()
        try await store.setAttachedApp(linked.id, bundleIdentifier: app.bundleIdentifier)
        let unlinked = try await store.create()
        let manager = StickyWindowManager(store: store, settings: settings, appAttachment: context,
            reportError: { XCTFail($0.localizedDescription) })
        manager.reduceMotion = { true }
        let appDock = EdgeDockController(store: store, settings: settings, appAttachment: context,
            open: { [weak manager] id, frame in manager?.open(id, near: nil, from: frame) }, create: {})
        let screenDock = EdgeDockController(store: store, settings: settings, open: { _, _ in }, create: {})
        defer {
            context.stopTracking()
            appDock.stop(); screenDock.stop()
            manager.windows.values.forEach { $0.close() }
        }
        manager.visibilityChanged = { appDock.refreshLayout() }
        context.windowChanged = { needsVisibilityRefresh in
            if needsVisibilityRefresh { manager.refreshVisibility(resample: false) }
            else { appDock.refreshPosition() }
        }
        manager.edgeFrame = { id, _ in appDock.returnFrame(for: id) }
        manager.restorePinned()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.contentView?.accessibilityLabel() == "SHIORI app notes" })
        XCTAssertEqual(appDock.displayedNotes.map(\.id), [linked.id])
        XCTAssertEqual(screenDock.displayedNotes.map(\.id), [unlinked.id])
        XCTAssertNil(screenDock.returnFrame(for: linked.id))
        XCTAssertEqual(panel.frame.maxX, original.maxX, accuracy: 0.5)
        XCTAssertEqual(appDock.returnFrame(for: linked.id)?.maxX, original.maxX)
        XCTAssertTrue(panel.isVisible)

        manager.close(linked.id)
        for _ in 0..<100 {
            if manager.windows[linked.id] == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(manager.windows[linked.id])
        XCTAssertEqual(store.note(id: linked.id)?.pinned, false)
        XCTAssertEqual(store.note(id: linked.id)?.attachedAppBundleIdentifier, app.bundleIdentifier)
        XCTAssertTrue(panel.isVisible)

        // The first normal on-screen window becomes the anchor, including after moves/resizes.
        let moved = original.offsetBy(dx: -40, dy: 30).insetBy(dx: 20, dy: 20)
        context.windowInfo = { [windowInfo(moved), windowInfo(original)] }
        manager.refreshVisibility()
        XCTAssertEqual(context.windowFrame, moved)
        XCTAssertEqual(panel.frame.maxX, moved.maxX, accuracy: 0.5)
        XCTAssertEqual(panel.frame.midY, moved.midY, accuracy: 0.5)
        XCTAssertNil(manager.windows[linked.id])
        // Drag updates use the selected window only and preserve the current deck state.
        var fullScans = 0
        context.windowInfo = { fullScans += 1; return [windowInfo(moved)] }
        let phase = appDock.phase
        for step in 1...12 {
            let frame = moved.offsetBy(dx: CGFloat(step), dy: CGFloat(step))
            context.trackedWindowInfo = { id in
                XCTAssertEqual(id, 123)
                return [windowInfo(frame)]
            }
            context.sampleMovement()
            XCTAssertEqual(panel.frame.maxX, frame.maxX, accuracy: 0.5)
            XCTAssertEqual(panel.frame.midY, frame.midY, accuracy: 0.5)
            XCTAssertEqual(appDock.phase, phase)
        }
        XCTAssertEqual(fullScans, 0)
        context.trackedWindowInfo = { _ in [windowInfo(moved)] }
        context.sampleMovement()
        settings.edge = "left"
        appDock.refreshLayout()
        XCTAssertEqual(panel.frame.minX, moved.minX, accuracy: 0.5)

        context.windowInfo = { [windowInfo(screen.visibleFrame)] }
        manager.refreshVisibility()
        let screenPanel = try XCTUnwrap(NSApp.windows.first { $0.contentView?.accessibilityLabel() == "SHIORI edge notes" })
        screenDock.refreshLayout()
        XCTAssertFalse(panel.frame.intersects(screenPanel.frame))
        context.windowInfo = { [windowInfo(moved)] }
        manager.refreshVisibility()

        manager.open(linked.id, near: nil, from: appDock.cardScreenFrame(for: linked.id))
        for _ in 0..<100 {
            if manager.windows[linked.id] != nil && manager.transitioningCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(manager.windows[linked.id])
        XCTAssertTrue(editor.isVisible)
        // Closing/minimizing the app's last window hides both its tabs and an unpinned editor.
        context.windowInfo = { [] }
        context.trackedWindowInfo = { _ in [] }
        context.sampleMovement()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(editor.isVisible)
        XCTAssertNil(appDock.returnFrame(for: linked.id))
        XCTAssertNil(screenDock.returnFrame(for: linked.id))
        context.windowInfo = { [windowInfo(moved)] }
        manager.refreshVisibility()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(editor.isVisible)

        try await store.setAttachedApp(linked.id, bundleIdentifier: nil)
        appDock.refreshLayout()
        screenDock.refreshLayout()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(screenDock.displayedNotes.contains(where: { $0.id == linked.id }))
        XCTAssertNotNil(screenDock.returnFrame(for: linked.id))
    }

    @MainActor
    func testRestingStripesDragAndReturnAfterHover() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIORI_RUN_WINDOW_TESTS"] == "1", "Desktop-interactive test; opt in with SHIORI_RUN_WINDOW_TESTS=1.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite"))
        let store = NotesStore(repository: repository)
        for color in 0..<4 {
            let note = try await store.create()
            store.edit(note.id, title: "Note \(color)", colorIndex: color)
        }
        try await store.flush()
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.openDelay = 0; settings.closeDelay = 0.01
        var pointer = NSPoint.zero
        let controller = EdgeDockController(store: store, settings: settings, open: { _, _ in }, create: {}, pointerLocation: { pointer })
        defer { controller.stop() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.contentView?.accessibilityLabel() == "SHIORI edge notes" })
        let view = try XCTUnwrap(panel.contentView)
        XCTAssertEqual(controller.phase, .collapsed)
        XCTAssertEqual(panel.frame.width, 30)
        XCTAssertNotNil(view.hitTest(NSPoint(x: 26, y: 54)))
        XCTAssertNil(view.hitTest(NSPoint(x: 1, y: 54)))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let initialAnchor = settings.anchor
        view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 26, y: 54)))
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 26, y: 84)))
        view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 26, y: 54)))
        XCTAssertGreaterThan(settings.anchor, initialAnchor)
        pointer = NSPoint(x: panel.frame.maxX - 5, y: panel.frame.midY)
        controller.entered()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.phase, .expanded)
        try await Task.sleep(for: .milliseconds(260))
        let first = try XCTUnwrap(store.active.first?.id)
        view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 245, y: 425)))
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 245, y: 190)))
        view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 245, y: 190)))
        for _ in 0..<50 {
            if store.active.last?.id == first { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.active.last?.id, first)
        pointer = NSPoint(x: panel.frame.minX - 100, y: panel.frame.minY - 100)
        controller.exited()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(controller.phase, .collapsed)
        XCTAssertEqual(panel.frame.width, 30)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Resting edge stripes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
