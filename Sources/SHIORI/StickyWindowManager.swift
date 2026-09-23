import AppKit
import SwiftUI
import QuartzCore
import Combine
@preconcurrency import ApplicationServices

@MainActor
final class AppAttachmentContext: NSObject, ObservableObject {
    @Published private(set) var currentBundleIdentifier: String?
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    var windowChanged: ((_ needsVisibilityRefresh: Bool) -> Void)?
    private var trackingEnabled = false
    private var trackingStarted = false
    private var displayLink: CADisplayLink?
    private var trackingScreen: NSScreen?
    private var trackingUntil: CFTimeInterval = 0
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private var observedApplication: AXUIElement?
    private var windowID: CGWindowID?
    private var currentApplication: NSRunningApplication?
    private(set) var windowFrame: NSRect?
    var hasVisibleWindow: Bool { windowFrame != nil }
    var windowInfo: () -> [[String: Any]] = {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    var trackedWindowInfo: (CGWindowID) -> [[String: Any]] = {
        CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]] ?? []
    }

    override init() {
        super.init()
        if let app = NSWorkspace.shared.frontmostApplication { record(app) }
    }

    static func eligible(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
        app.bundleIdentifier != nil
    }

    func record(_ app: NSRunningApplication) {
        guard Self.eligible(app) else { return }
        let changedApp = currentApplication?.processIdentifier != app.processIdentifier
        if changedApp { stopObserving() }
        currentApplication = app
        currentBundleIdentifier = app.bundleIdentifier
        refreshWindowVisibility()
        if changedApp { updateObservation() }
    }

    func terminated(_ app: NSRunningApplication) {
        if app.bundleIdentifier == currentBundleIdentifier {
            stopObserving()
            displayLink?.isPaused = true
            currentApplication = nil
            currentBundleIdentifier = nil
            windowFrame = nil
            windowID = nil
        }
    }

    func refreshWindowVisibility(using info: [[String: Any]]? = nil) {
        windowID = nil
        guard let app = currentApplication, !app.isTerminated, !app.isHidden else {
            windowFrame = nil
            return
        }
        windowFrame = nil
        for window in info ?? windowInfo() {
            guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowIsOnscreen as String] as? Bool != false,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 0, rect.height > 0 else { continue }
            // Window Server uses a top-left origin on the primary display.
            windowID = window[kCGWindowNumber as String] as? CGWindowID
            windowFrame = NSRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY,
                                 width: rect.width, height: rect.height)
            break
        }
    }

    func startTracking() {
        guard !trackingStarted else { return }
        trackingStarted = true
        updateObservation()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMovement() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMovement() }
            return event
        }
    }

    func setTrackingEnabled(_ enabled: Bool) {
        trackingEnabled = enabled
        updateObservation()
        if !enabled { displayLink?.isPaused = true }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        updateObservation()
    }

    private func trackMovement() {
        guard trackingEnabled, windowID != nil else { return }
        trackingUntil = CACurrentMediaTime() + 0.5
        let screen = NSScreen.screens.first { screen in
            windowFrame.map { screen.frame.contains(NSPoint(x: $0.midX, y: $0.midY)) } ?? false
        } ?? NSScreen.screens.first
        if trackingScreen != screen {
            displayLink?.invalidate()
            displayLink = nil
            trackingScreen = screen
        }
        if displayLink == nil, let screen {
            let link = screen.displayLink(target: self, selector: #selector(sampleMovement))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        let wasPaused = displayLink?.isPaused != false
        displayLink?.isPaused = false
        if wasPaused { sampleMovement() }
    }

    @objc func sampleMovement() {
        guard trackingEnabled else { displayLink?.isPaused = true; return }
        let oldFrame = windowFrame, oldID = windowID
        if let windowID {
            let info = trackedWindowInfo(windowID)
            refreshWindowVisibility(using: info)
            if !hasVisibleWindow { refreshWindowVisibility() }
        } else {
            refreshWindowVisibility()
        }
        if oldFrame != windowFrame || oldID != windowID {
            windowChanged?(oldFrame == nil || windowFrame == nil || oldID != windowID)
        }
        if NSEvent.pressedMouseButtons & 1 == 0 && CACurrentMediaTime() >= trackingUntil {
            displayLink?.isPaused = true
        }
    }

    private func updateObservation() {
        let trusted = AXIsProcessTrusted()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        guard trackingStarted, trackingEnabled, trusted, let app = currentApplication, !app.isTerminated else {
            stopObserving()
            return
        }
        guard observer == nil else { return }
        var created: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<AppAttachmentContext>.fromOpaque(context).takeUnretainedValue()
                owner.observedChange(notification as String)
            }
        }, &created)
        guard result == .success, let created else { return }
        observer = created
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Do not let an unresponsive app block SHIORI while resolving focus.
        AXUIElementSetMessagingTimeout(application, 0.05)
        observedApplication = application
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(created, application, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observeFocusedWindow()
    }

    private func observeFocusedWindow() {
        guard let observer, let application = observedApplication else { return }
        let names = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
        if let observedWindow {
            for name in names { AXObserverRemoveNotification(observer, observedWindow, name as CFString) }
        }
        observedWindow = nil
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        observedWindow = window
        for name in names {
            AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func observedChange(_ notification: String) {
        if notification == kAXMovedNotification || notification == kAXResizedNotification {
            trackMovement()
            return
        }
        observeFocusedWindow()
        refreshWindowVisibility()
        windowChanged?(true)
        trackMovement()
    }

    private func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedWindow = nil
        observedApplication = nil
    }

    func stopTracking() {
        trackingStarted = false
        trackingEnabled = false
        stopObserving()
        displayLink?.invalidate()
        displayLink = nil
        trackingScreen = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        windowChanged = nil
    }

    var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(Self.eligible).sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
    }
}

final class StickyPanel: NSPanel {
    var requestClose: (() -> Void)?
    var requestUnlock: (() -> Void)?
    var privacyLocked = false
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if privacyLocked, responder != nil { return false }
        return super.makeFirstResponder(responder)
    }
    override func sendEvent(_ event: NSEvent) {
        if privacyLocked, event.type == .keyDown || event.type == .leftMouseDown { requestUnlock?(); return }
        super.sendEvent(event)
    }
    override func performClose(_ sender: Any?) { requestClose?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class NoteFocusState: ObservableObject {
    @Published var noteID: String?

    func allows(_ id: String) -> Bool { noteID == nil || noteID == id }

    func isVisible(_ note: Note, hidden: Bool, matchesApp: Bool) -> Bool {
        guard note.archivedAt == nil, note.deletedAt == nil, allows(note.id) else { return false }
        return noteID == note.id || (!(note.pinned && hidden) && matchesApp)
    }
}

@MainActor
final class StickyWindowManager: NSObject, NSWindowDelegate {
    let focus = NoteFocusState()
    let appAttachment: AppAttachmentContext
    let store: NotesStore
    let settings: SettingsStore
    let reportError: (Error) -> Void
    let privacy: PrivacyLock?
    private var privacySubscription: AnyCancellable?
    var windows: [String: StickyPanel] = [:]
    var hidden = false
    private let deleteUndo = DeleteUndoCoordinator()
    private var geometryTasks: [String: Task<Void, Never>] = [:]
    private var opening: Task<Void, Never>?
    private var transitions: [String: Task<Void, Never>] = [:]
    private var closing = Set<String>()
    private var stableFrames: [String: NSRect] = [:]
    var visibilityChanged: (() -> Void)?
    var edgeFrame: ((String, NSScreen?) -> NSRect?)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var transitioningCount: Int { transitions.count }

    init(store: NotesStore, settings: SettingsStore, privacy: PrivacyLock? = nil, appAttachment: AppAttachmentContext = AppAttachmentContext(), reportError: @escaping (Error) -> Void) {
        self.appAttachment = appAttachment
        self.store = store; self.settings = settings; self.privacy = privacy; self.reportError = reportError
        super.init()
        privacySubscription = privacy?.$isLocked.sink { [weak self] locked in
            guard let self else { return }
            for (id, window) in self.windows {
                window.privacyLocked = locked
                let content = window.contentView as? PrivateNoteContent
                content?.color = Theme.nsColor(self.store.note(id: id)?.colorIndex ?? 0)
                content?.setLocked(locked)
            }
        }
    }
    func open(_ id: String, near point: NSPoint?, focusTitle: Bool = false, from cardFrame: NSRect? = nil) {
        if let privacy, privacy.isLocked {
            privacy.perform { [weak self] in self?.open(id, near: point, focusTitle: focusTitle, from: cardFrame) }
            return
        }
        let previous = opening
        opening = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.transitions[id]?.value
            guard let note = self.store.notes.first(where: { $0.id == id }), note.archivedAt == nil, note.deletedAt == nil else { return }
            if !self.focus.allows(id) { self.exitFocus() }
            self.show(id, near: point, focusTitle: focusTitle, from: cardFrame)
            await self.transitions[id]?.value
        }
    }
    private func show(_ id: String, near point: NSPoint?, focusTitle: Bool, activate: Bool = true, from cardFrame: NSRect? = nil) {
        guard focus.allows(id) else { return }
        let targetScreen = cardFrame.flatMap { frame in
            NSScreen.screens.max { lhs, rhs in
                let left = lhs.visibleFrame.intersection(frame), right = rhs.visibleFrame.intersection(frame)
                return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
            }
        }
        if let existing = windows[id] {
            if let targetScreen, existing.screen != targetScreen {
                existing.setFrame(WindowGeometry.clamp(existing.frame, to: [targetScreen.visibleFrame]), display: true)
            }
            NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil); return
        }
        let defaultFrame = NSRect(origin: point.map { NSPoint(x: $0.x - Theme.editorSize.width, y: $0.y - Theme.editorSize.height / 2) } ?? NSPoint(x: (NSScreen.main?.visibleFrame.midX ?? 500) - 180, y: (NSScreen.main?.visibleFrame.midY ?? 500) - 200), size: Theme.editorSize)
        let sourceFrame = cardFrame.map { NSRect(x: $0.minX + (settings.edge == "left" ? 24 : -24), y: $0.maxY - Theme.editorSize.height, width: Theme.editorSize.width, height: Theme.editorSize.height) }
        let frame = WindowGeometry.clamp(settings.frame(id: id) ?? sourceFrame ?? defaultFrame, to: targetScreen.map { [$0.visibleFrame] } ?? NSScreen.screens.map(\.visibleFrame))
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
        let editor = NSHostingView(rootView: StickyEditorView(settings: settings, store: store, appAttachment: appAttachment, focus: focus, toggleFocus: { [weak self] in self?.toggleFocus(id) }, attach: { [weak self] bundleID in self?.attach(id, to: bundleID) }, id: id, focusTitle: focusTitle,
            close: { [weak self] in self?.close(id) }, pin: { [weak self] in self?.togglePin(id) }, delete: { [weak self] in self?.delete(id) }))
        if let privacy {
            let unlock: () -> Void = { [weak privacy] in privacy?.perform {} }
            let content = PrivateNoteContent(editor: editor, color: Theme.nsColor(store.note(id: id)?.colorIndex ?? 0), unlock: unlock)
            window.contentView = content
            content.setLocked(privacy.isLocked)
            window.privacyLocked = privacy.isLocked
            window.requestUnlock = unlock
        } else { window.contentView = editor }
        windows[id] = window
        if activate, let source = cardFrame ?? edgeFrame?(id, window.screen) {
            let reduced = reduceMotion()
            stableFrames[id] = frame
            if !reduced { window.setFrame(source, display: false) }
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            transitions[id] = Task { [weak self, weak window] in
                guard let self, let window else { return }
                await self.animate(window, to: frame, alpha: 1, duration: focusTitle ? Theme.Motion.create : Theme.Motion.editorOpen)
                self.stableFrames.removeValue(forKey: id)
                self.transitions.removeValue(forKey: id)
                let recovered = WindowGeometry.clamp(window.frame, to: NSScreen.screens.map(\.visibleFrame))
                if recovered != window.frame { window.setFrame(recovered, display: true) }
            }
        } else if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
    }

    private func animate(_ window: NSWindow, to frame: NSRect, alpha: CGFloat, duration: Double) async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.duration(duration, reduceMotion: reduceMotion())
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = alpha
            } completionHandler: { continuation.resume() }
        }
    }
    func restorePinned() {
        refreshVisibility()
    }
    func close(_ id: String) {
        if let privacy, privacy.isLocked { privacy.perform { [weak self] in self?.close(id) }; return }
        Task {
            await transitions[id]?.value
            do {
                try await store.flush(id)
                try await store.setPinned(id, pinned: false)
                await dismiss(id)
            } catch { reportError(error) }
        }
    }
    func togglePin(_ id: String) {
        if let privacy, privacy.isLocked { privacy.perform { [weak self] in self?.togglePin(id) }; return }
        Task {
            await transitions[id]?.value
            do {
                guard let note = store.notes.first(where: { $0.id == id }) else { return }
                try await store.flush(id)
                try await store.setPinned(id, pinned: !note.pinned)
                if note.pinned { await dismiss(id) } else { saveGeometry(id) }
            } catch { reportError(error) }
        }
    }
    func delete(_ id: String) {
        if let privacy, privacy.isLocked { privacy.perform { [weak self] in self?.delete(id) }; return }
        windows[id]?.makeFirstResponder(nil)
        let screen = windows[id]?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let wasVisible = windows[id]?.isVisible == true
        Task {
            await transitions[id]?.value
            do {
                try await store.delete(id)
                await dismiss(id, returningToEdge: false)
                deleteUndo.show(on: screen, behavior: settings.collectionBehavior, undo: { [weak self] in
                    guard let self else { return }
                    try await self.store.undoDelete(id)
                    if wasVisible, self.store.note(id: id)?.pinned == true {
                        self.show(id, near: nil, focusTitle: false, activate: false)
                    }
                }, reportError: reportError)
            } catch { reportError(error) }
        }
    }
    private func dismiss(_ id: String, returningToEdge: Bool = true) async {
        if closing.contains(id) { await transitions[id]?.value; return }
        await transitions[id]?.value
        guard let window = windows[id] else { return }
        saveGeometry(id)
        geometryTasks.removeValue(forKey: id)?.cancel()
        closing.insert(id)
        stableFrames[id] = window.frame
        window.ignoresMouseEvents = true
        window.makeFirstResponder(nil)
        let target = edgeFrame?(id, window.screen)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if returningToEdge, window.isVisible, let target {
                await self.animate(window, to: self.reduceMotion() ? window.frame : target, alpha: 0, duration: Theme.Motion.editorClose)
            }
            window.delegate = nil
            window.close()
            window.contentView = nil
            window.requestClose = nil; window.requestUnlock = nil
            self.windows.removeValue(forKey: id)
            self.stableFrames.removeValue(forKey: id)
            self.closing.remove(id)
            self.transitions.removeValue(forKey: id)
        }
        transitions[id] = task
        await task.value
        if focus.noteID == id { exitFocus() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let id = sender.identifier?.rawValue { close(id) }
        return false
    }
    func windowDidMove(_ notification: Notification) { scheduleGeometry(notification) }
    func windowDidResize(_ notification: Notification) { scheduleGeometry(notification) }
    private func scheduleGeometry(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue, stableFrames[id] == nil else { return }
        geometryTasks[id]?.cancel()
        geometryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveGeometry(id)
            self?.geometryTasks.removeValue(forKey: id)
        }
    }
    func saveGeometry(_ id: String) {
        guard let window = windows[id] else { return }
        let display = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].map { String(describing: $0) }
        settings.saveFrame(stableFrames[id] ?? window.frame, id: id, display: display)
    }
    func saveAllGeometry() { for id in windows.keys { saveGeometry(id) } }
    func attach(_ id: String, to bundleIdentifier: String?) {
        if let privacy, privacy.isLocked { privacy.perform { [weak self] in self?.attach(id, to: bundleIdentifier) }; return }
        Task {
            do {
                try await store.setAttachedApp(id, bundleIdentifier: bundleIdentifier)
                refreshVisibility()
            } catch { reportError(error) }
        }
    }
    func matchesApp(_ note: Note) -> Bool {
        note.attachedAppBundleIdentifier == nil || (note.attachedAppBundleIdentifier == appAttachment.currentBundleIdentifier && appAttachment.hasVisibleWindow)
    }
    func toggleHidden() {
        focus.noteID = nil
        hidden.toggle()
        refreshVisibility()
    }
    func toggleFocus(_ id: String) {
        if let privacy, privacy.isLocked { privacy.perform { [weak self] in self?.toggleFocus(id) }; return }
        guard let note = store.note(id: id), note.archivedAt == nil, note.deletedAt == nil,
              windows[id] != nil else { return }
        focus.noteID = focus.noteID == id ? nil : id
        refreshVisibility()
        windows[id]?.makeKeyAndOrderFront(nil)
    }
    func exitFocus() {
        focus.noteID = nil
        refreshVisibility()
    }
    func refreshVisibility(resample: Bool = true) {
        if let id = focus.noteID, !store.active.contains(where: { $0.id == id }) { focus.noteID = nil }
        if resample { appAttachment.refreshWindowVisibility() }
        appAttachment.setTrackingEnabled(store.active.contains {
            $0.attachedAppBundleIdentifier != nil && $0.attachedAppBundleIdentifier == appAttachment.currentBundleIdentifier
        })
        for note in store.active where note.pinned && matchesApp(note) && !hidden && windows[note.id] == nil {
            show(note.id, near: nil, focusTitle: false, activate: false)
        }
        for (id, window) in windows {
            window.collectionBehavior = settings.collectionBehavior
            guard let note = store.note(id: id) else { window.orderOut(nil); continue }
            if !focus.isVisible(note, hidden: hidden, matchesApp: matchesApp(note)) {
                window.orderOut(nil)
            } else if !window.isVisible { window.orderFrontRegardless() }
        }
        visibilityChanged?()
    }
    func clampWindows() {
        for (id, window) in windows {
            guard stableFrames[id] == nil else { continue }
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
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct StickyEditorView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: NotesStore
    @ObservedObject var appAttachment: AppAttachmentContext
    @ObservedObject var focus: NoteFocusState
    let toggleFocus: () -> Void
    let attach: (String?) -> Void
    let id: String
    let focusTitle: Bool
    let close: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    @FocusState private var titleFocused: Bool
    @State private var bodyFocus = false
    private final class EditorReference { weak var view: ChecklistTextView? }
    @State private var editor = EditorReference()
    @State private var formatting = false
    @State private var choosingColor = false
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
                .padding(.top, 12)
                .overlay(alignment: .top) { HeaderDragArea().frame(height: 12).accessibilityLabel("Move note") }
                NativeEditor(text: Binding(get: { self.note?.body ?? "" }, set: { store.edit(id, body: $0) }), focus: $bodyFocus, bodyFont: settings.bodyFont)
                    .connecting { editor.view = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 9) {
                    Button { choosingColor.toggle() } label: {
                        Image(systemName: "paintpalette").font(.system(size: 15)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Note color").help("Note color")
                    .popover(isPresented: $choosingColor, arrowEdge: .bottom) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), spacing: 8) {
                            ForEach(Theme.palette.indices, id: \.self) { index in
                                Button {
                                    store.edit(id, colorIndex: index)
                                } label: {
                                    RoundedRectangle(cornerRadius: 9).fill(Theme.color(index))
                                        .frame(width: 30, height: 30)
                                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.black.opacity(0.18)))
                                        .overlay {
                                            if note.colorIndex == index {
                                                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.black.opacity(0.65))
                                            }
                                        }
                                }
                                .buttonStyle(.plain).accessibilityLabel(Theme.names[index])
                                .accessibilityAddTraits(note.colorIndex == index ? .isSelected : [])
                            }
                        }.padding(12)
                    }
                    HeaderDragArea().frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                        .accessibilityLabel("Move note")
                    Button(action: toggleFocus) {
                        if focus.noteID == id {
                            Text("Exit Focus").font(.system(size: 11, weight: .medium))
                        } else {
                            Image(systemName: "viewfinder").font(.system(size: 14)).frame(width: 24, height: 24)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(focus.noteID == id ? "Exit Focus" : "Focus Note")
                    .help(focus.noteID == id ? "Exit Focus" : "Focus Note")
                    if store.hasError(id) {
                        Button("Retry save", systemImage: "exclamationmark.circle") {
                            Task { do { try await store.flush(id) } catch { AppCoordinator.logger.error("Retry failed") } }
                        }.labelStyle(.iconOnly).buttonStyle(.plain)
                            .help(store.saveError(id) ?? "Couldn’t save this note. Click to retry.")
                    }
                    Menu {
                        Button("Attach to Current App") { attach(appAttachment.currentBundleIdentifier) }
                            .disabled(appAttachment.currentBundleIdentifier == nil)
                        Menu("Attach to Running App") {
                            ForEach(appAttachment.runningApps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "") { attach(app.bundleIdentifier) }
                            }
                        }
                        if !appAttachment.accessibilityGranted {
                            Button("Enable Responsive Window Tracking…") { appAttachment.requestAccessibility() }
                                .help("Allow Accessibility access to follow window changes.")
                        }
                        if let bundleID = note.attachedAppBundleIdentifier {
                            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                                .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
                            Text("Attached to " + name)
                            Button("Detach from App") { attach(nil) }
                        }
                    } label: {
                        Image(systemName: note.attachedAppBundleIdentifier == nil ? "link" : "link.circle.fill")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("App attachment")
                    Button("Aa") { formatting.toggle() }
                        .buttonStyle(.plain).accessibilityLabel("Format Markdown")
                        .popover(isPresented: $formatting) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(MarkdownFormat.allCases, id: \.rawValue) { format in
                                    Button(format.rawValue) {
                                        formatting = false
                                        editor.view?.formatText(format)
                                    }.buttonStyle(.plain).padding(5)
                                }
                            }.padding(8)
                        }
                    Button(action: delete) {
                        Image(systemName: "trash").font(.system(size: 13)).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel("Delete note").help("Delete note")
                }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 10)
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
