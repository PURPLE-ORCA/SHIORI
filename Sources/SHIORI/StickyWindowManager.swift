import AppKit
import SwiftUI

final class StickyPanel: NSPanel {
    var requestClose: (() -> Void)?
    override func performClose(_ sender: Any?) { requestClose?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class StickyWindowManager: NSObject, NSWindowDelegate {
    let store: NotesStore
    let settings: SettingsStore
    let reportError: (Error) -> Void
    var windows: [String: StickyPanel] = [:]
    var transient: String?
    var hidden = false
    private var geometryTasks: [String: Task<Void, Never>] = [:]
    private var opening: Task<Void, Never>?

    init(store: NotesStore, settings: SettingsStore, reportError: @escaping (Error) -> Void) {
        self.store = store; self.settings = settings; self.reportError = reportError
    }
    func open(_ id: String, near point: NSPoint?, focusTitle: Bool = false) {
        let previous = opening
        opening = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                guard let note = self.store.notes.first(where: { $0.id == id }), note.archivedAt == nil else { return }
                if !note.pinned { try await self.closeTransient(except: id); self.transient = id }
                self.show(id, near: point, focusTitle: focusTitle)
            } catch { self.reportError(error) }
        }
    }
    private func show(_ id: String, near point: NSPoint?, focusTitle: Bool, activate: Bool = true) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil); return
        }
        let defaultFrame = NSRect(origin: point.map { NSPoint(x: $0.x - Theme.editorSize.width, y: $0.y - Theme.editorSize.height / 2) } ?? NSPoint(x: (NSScreen.main?.visibleFrame.midX ?? 500) - 180, y: (NSScreen.main?.visibleFrame.midY ?? 500) - 200), size: Theme.editorSize)
        let frame = WindowGeometry.clamp(settings.frame(id: id) ?? defaultFrame, to: NSScreen.screens.map(\.visibleFrame))
        let window = StickyPanel(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 300, height: 300)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.appearance = NSAppearance(named: .aqua)
        window.animationBehavior = .utilityWindow
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = settings.collectionBehavior
        window.isReleasedWhenClosed = false; window.identifier = NSUserInterfaceItemIdentifier(id)
        window.delegate = self
        window.requestClose = { [weak self] in self?.close(id) }
        window.contentView = NSHostingView(rootView: StickyEditorView(store: store, id: id, focusTitle: focusTitle,
            close: { [weak self] in self?.close(id) }, pin: { [weak self] in self?.togglePin(id) }, complete: { [weak self] in self?.complete(id) }))
        windows[id] = window
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
    }
    func restorePinned() {
        for note in store.notes where note.pinned && note.archivedAt == nil { show(note.id, near: nil, focusTitle: false, activate: false) }
    }
    func closeTransient(except id: String? = nil) async throws {
        if let current = transient, current != id {
            try await store.flush(current)
            dismiss(current)
        }
    }
    func close(_ id: String) {
        Task {
            do {
                try await store.flush(id)
                try await store.setPinned(id, pinned: false)
                dismiss(id)
            } catch { reportError(error) }
        }
    }
    func togglePin(_ id: String) {
        Task {
            do {
                guard let note = store.notes.first(where: { $0.id == id }) else { return }
                try await store.flush(id)
                try await store.setPinned(id, pinned: !note.pinned)
                if note.pinned { dismiss(id) } else { transient = nil; saveGeometry(id) }
            } catch { reportError(error) }
        }
    }
    func complete(_ id: String) {
        windows[id]?.makeFirstResponder(nil)
        Task {
            do { try await store.complete(id); dismiss(id) }
            catch { reportError(error) }
        }
    }
    private func dismiss(_ id: String) {
        saveGeometry(id)
        let window = windows.removeValue(forKey: id)
        window?.delegate = nil
        window?.close()
        geometryTasks.removeValue(forKey: id)?.cancel()
        if transient == id { transient = nil }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let id = sender.identifier?.rawValue { close(id) }
        return false
    }
    func windowDidMove(_ notification: Notification) { scheduleGeometry(notification) }
    func windowDidResize(_ notification: Notification) { scheduleGeometry(notification) }
    private func scheduleGeometry(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        geometryTasks[id]?.cancel()
        geometryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveGeometry(id)
        }
    }
    func saveGeometry(_ id: String) {
        guard let window = windows[id] else { return }
        let display = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].map { String(describing: $0) }
        settings.saveFrame(window.frame, id: id, display: display)
    }
    func saveAllGeometry() { for id in windows.keys { saveGeometry(id) } }
    func toggleHidden() {
        hidden.toggle()
        for (id, window) in windows where store.notes.first(where: { $0.id == id })?.pinned == true {
            if hidden { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
    }
    func refreshVisibility() { for window in windows.values { window.collectionBehavior = settings.collectionBehavior } }
    func clampWindows() {
        for window in windows.values { window.setFrame(WindowGeometry.clamp(window.frame, to: NSScreen.screens.map(\.visibleFrame)), display: true) }
    }
    func resetPositions() {
        for (index, window) in windows.values.enumerated() {
            let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
            let frame = NSRect(x: screen.midX - 180 + CGFloat(index * 24), y: screen.midY - 200 - CGFloat(index * 24), width: 360, height: 400)
            window.setFrame(WindowGeometry.clamp(frame, to: [screen]), display: true)
        }
        saveAllGeometry()
    }
}

struct HeaderDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct StickyEditorView: View {
    @ObservedObject var store: NotesStore
    let id: String
    let focusTitle: Bool
    let close: () -> Void
    let pin: () -> Void
    let complete: () -> Void
    @FocusState private var titleFocused: Bool
    @State private var bodyFocus = false
    private var note: Note? { store.notes.first { $0.id == id } }
    var body: some View {
        if let note {
            VStack(spacing: 0) {
                HStack {
                    Text(Date(timeIntervalSince1970: note.updatedAt), format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.black.opacity(0.55)).allowsHitTesting(false)
                    HeaderDragArea().frame(maxWidth: .infinity, minHeight: 28).accessibilityLabel("Move note")
                    Button(action: pin) { Image(systemName: note.pinned ? "pin.fill" : "pin") }.accessibilityLabel(note.pinned ? "Unpin note" : "Pin note")
                    Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Return to deck")
                }.buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 10)
                TextField("Untitled note", text: Binding(get: { self.note?.title ?? "" }, set: { store.edit(id, title: $0) }))
                    .font(.system(size: 22, weight: .semibold)).textFieldStyle(.plain).focused($titleFocused)
                    .onSubmit { titleFocused = false; bodyFocus = true }
                    .onKeyPress(.tab) { titleFocused = false; bodyFocus = true; return .handled }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                NativeEditor(text: Binding(get: { self.note?.body ?? "" }, set: { store.edit(id, body: $0) }), focus: $bodyFocus)
                HStack(spacing: 9) {
                    ForEach(0..<5) { index in
                        Button { store.edit(id, colorIndex: index) } label: {
                            Circle().fill(Theme.color(index)).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.black.opacity(note.colorIndex == index ? 0.65 : 0.15), lineWidth: note.colorIndex == index ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel(Theme.names[index])
                    }
                    Spacer()
                    Button("Complete", systemImage: "checkmark", action: complete).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                }.padding(.horizontal, 20).padding(.top, 10)
                HStack {
                    Text(store.saveStatus(id)).font(.system(size: 10)).foregroundStyle(.black.opacity(0.6))
                    Spacer()
                    if store.hasError(id) {
                        Button("Retry") { Task { do { try await store.flush(id) } catch { AppCoordinator.logger.error("Retry failed (code \((error as NSError).code))") } } }.font(.caption)
                    }
                }.padding(.horizontal, 20).padding(.top, 5).padding(.bottom, 10)
            }
            .foregroundStyle(.black.opacity(0.85)).background(Theme.color(note.colorIndex))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(.black.opacity(0.12), lineWidth: 1))
            .environment(\.colorScheme, .light)
            .disabled(store.isBusy(id))
            .onAppear { titleFocused = focusTitle }
        }
    }
}
