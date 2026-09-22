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
