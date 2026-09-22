import AppKit
import SwiftUI
import QuartzCore

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
    private let deleteUndo = DeleteUndoCoordinator()
    private var geometryTasks: [String: Task<Void, Never>] = [:]
    private var opening: Task<Void, Never>?
    private var dismissals: [String: Task<Void, Never>] = [:]
    var deckFrame: ((String) -> NSRect?)?

    init(store: NotesStore, settings: SettingsStore, reportError: @escaping (Error) -> Void) {
        self.store = store; self.settings = settings; self.reportError = reportError
    }
    func open(_ id: String, near point: NSPoint?, focusTitle: Bool = false, from cardFrame: NSRect? = nil) {
        let previous = opening
        opening = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.dismissals[id]?.value
            do {
                guard let note = self.store.notes.first(where: { $0.id == id }), note.archivedAt == nil, note.deletedAt == nil else { return }
                if !note.pinned { try await self.closeTransient(except: id); self.transient = id }
                self.show(id, near: point, focusTitle: focusTitle, from: cardFrame)
            } catch { self.reportError(error) }
        }
    }
    private func show(_ id: String, near point: NSPoint?, focusTitle: Bool, activate: Bool = true, from cardFrame: NSRect? = nil) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil); return
        }
        let defaultFrame = NSRect(origin: point.map { NSPoint(x: $0.x - Theme.editorSize.width, y: $0.y - Theme.editorSize.height / 2) } ?? NSPoint(x: (NSScreen.main?.visibleFrame.midX ?? 500) - 180, y: (NSScreen.main?.visibleFrame.midY ?? 500) - 200), size: Theme.editorSize)
        let sourceFrame = cardFrame.map { NSRect(x: $0.minX + (settings.edge == "left" ? 24 : -24), y: $0.maxY - Theme.editorSize.height, width: Theme.editorSize.width, height: Theme.editorSize.height) }
        let frame = WindowGeometry.clamp(settings.frame(id: id) ?? sourceFrame ?? defaultFrame, to: NSScreen.screens.map(\.visibleFrame))
        let window = StickyPanel(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 300, height: 300)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.appearance = NSAppearance(named: .aqua)
        window.animationBehavior = .none
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = settings.collectionBehavior
        window.isReleasedWhenClosed = false; window.identifier = NSUserInterfaceItemIdentifier(id)
        window.delegate = self
        window.requestClose = { [weak self] in self?.close(id) }
        window.contentView = NSHostingView(rootView: StickyEditorView(store: store, id: id, focusTitle: focusTitle,
            close: { [weak self] in self?.close(id) }, pin: { [weak self] in self?.togglePin(id) }, delete: { [weak self] in self?.delete(id) }))
        windows[id] = window
        let animate = activate && cardFrame != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate, let cardFrame {
            window.setFrame(cardFrame, display: false)
            window.alphaValue = 0.25
        }
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.editor
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = 1
            }
        }
    }
    func restorePinned() {
        for note in store.notes where note.pinned && note.archivedAt == nil && note.deletedAt == nil { show(note.id, near: nil, focusTitle: false, activate: false) }
    }
    func closeTransient(except id: String? = nil) async throws {
        if let current = transient, current != id {
            try await store.flush(current)
            await dismiss(current)
        }
    }
    func close(_ id: String) {
        Task {
            do {
                try await store.flush(id)
                try await store.setPinned(id, pinned: false)
                await dismiss(id)
            } catch { reportError(error) }
        }
    }
    func togglePin(_ id: String) {
        Task {
            do {
                guard let note = store.notes.first(where: { $0.id == id }) else { return }
                try await store.flush(id)
                try await store.setPinned(id, pinned: !note.pinned)
                if note.pinned { await dismiss(id) } else { transient = nil; saveGeometry(id) }
            } catch { reportError(error) }
        }
    }
    func delete(_ id: String) {
        windows[id]?.makeFirstResponder(nil)
        let screen = windows[id]?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let wasVisible = windows[id]?.isVisible == true
        Task {
            do {
                try await store.delete(id)
                await dismiss(id)
                deleteUndo.show(on: screen, undo: { [weak self] in
                    guard let self else { return }
                    try await self.store.undoDelete(id)
                    if wasVisible, self.store.note(id: id)?.pinned == true {
                        self.show(id, near: nil, focusTitle: false, activate: false)
                    }
                }, reportError: reportError)
            } catch { reportError(error) }
        }
    }
    private func dismiss(_ id: String) async {
        if let pending = dismissals[id] { await pending.value; return }
        guard let window = windows[id] else { return }
        saveGeometry(id)
        geometryTasks.removeValue(forKey: id)?.cancel()
        window.delegate = nil
        window.ignoresMouseEvents = true
        window.makeFirstResponder(nil)
        window.resignKey()
        let destination = deckFrame?(id)
        let task = Task { @MainActor in
            if let destination, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Theme.Motion.editor
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().setFrame(destination, display: true)
                        window.animator().alphaValue = 0
                    } completionHandler: { continuation.resume() }
                }
            }
            window.close()
            self.windows.removeValue(forKey: id)
            if self.transient == id { self.transient = nil }
        }
        dismissals[id] = task
        await task.value
        dismissals.removeValue(forKey: id)
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
    func saveAllGeometry() { for id in windows.keys where dismissals[id] == nil { saveGeometry(id) } }
    func toggleHidden() {
        hidden.toggle()
        for (id, window) in windows where store.notes.first(where: { $0.id == id })?.pinned == true {
            if hidden { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
    }
    func refreshVisibility() { for window in windows.values { window.collectionBehavior = settings.collectionBehavior } }
    func clampWindows() {
        for window in windows.values {
            let frame = WindowGeometry.clamp(window.frame, to: NSScreen.screens.map(\.visibleFrame))
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
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
    let delete: () -> Void
    @FocusState private var titleFocused: Bool
    @State private var bodyFocus = false
    @State private var editor: ChecklistTextView?
    @State private var formatting = false
    private var note: Note? { store.notes.first { $0.id == id } }
    var body: some View {
        if let note {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Untitled note", text: Binding(get: { self.note?.title ?? "" }, set: { store.edit(id, title: $0) }))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit { titleFocused = false; bodyFocus = true }
                        .onKeyPress(.tab) { titleFocused = false; bodyFocus = true; return .handled }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: pin) {
                        Image(systemName: note.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel(note.pinned ? "Unpin note" : "Pin note")
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Close note")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                HStack(spacing: 8) {
                    Text(Date(timeIntervalSince1970: note.updatedAt), format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.black.opacity(0.48))
                        .allowsHitTesting(false)
                    HeaderDragArea()
                        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
                        .accessibilityLabel("Move note")
                }
                    .padding(.horizontal, 20)
                    .padding(.top, 3)
                    .padding(.bottom, 8)
                NativeEditor(text: Binding(get: { self.note?.body ?? "" }, set: { store.edit(id, body: $0) }), focus: $bodyFocus)
                    .connecting { editor = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 9) {
                    ForEach(0..<5) { index in
                        Button { store.edit(id, colorIndex: index) } label: {
                            Circle().fill(Theme.color(index)).frame(width: 16, height: 16)
                                .overlay(Circle().stroke(.black.opacity(note.colorIndex == index ? 0.65 : 0.15), lineWidth: note.colorIndex == index ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel(Theme.names[index])
                    }
                    Spacer()
                    Button("Aa") { formatting.toggle() }
                        .buttonStyle(.plain).accessibilityLabel("Format Markdown")
                        .popover(isPresented: $formatting) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(MarkdownFormat.allCases, id: \.rawValue) { format in
                                    Button(format.rawValue) {
                                        formatting = false
                                        editor?.formatText(format)
                                    }.buttonStyle(.plain).padding(5)
                                }
                            }.padding(8)
                        }
                    Menu {
                        Button("Delete Note", role: .destructive, action: delete)
                    } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Note actions")
                }.padding(.horizontal, 20).padding(.top, 9)
                HStack {
                    Text(store.saveStatus(id)).font(.system(size: 10, design: .rounded)).foregroundStyle(.black.opacity(0.52))
                    Spacer()
                    if store.hasError(id) {
                        Button("Retry") { Task { do { try await store.flush(id) } catch { AppCoordinator.logger.error("Retry failed (code \((error as NSError).code))") } } }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                }.padding(.horizontal, 20).padding(.top, 5).padding(.bottom, 9)
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
