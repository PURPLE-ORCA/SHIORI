import AppKit
import Combine
import Foundation
import OSLog
import QuartzCore

/// The small state machine used by the dock.  Keeping delayed transitions in
/// one place prevents a quick enter/exit sequence from leaving the panel open.
public enum DockPhase: Equatable {
    case collapsed
    case pendingOpen
    case expanded
    case pendingClose
}

public struct DockStateMachine: Equatable {
    public private(set) var phase: DockPhase = .collapsed

    public init() {}

    public mutating func pointerEntered() {
        switch phase {
        case .collapsed:
            phase = .pendingOpen
        case .pendingClose:
            phase = .expanded
        case .pendingOpen, .expanded:
            break
        }
    }

    public mutating func openDelayElapsed() {
        if phase == .pendingOpen { phase = .expanded }
    }

    public mutating func pointerExited() {
        switch phase {
        case .pendingOpen:
            phase = .collapsed
        case .expanded:
            phase = .pendingClose
        case .collapsed, .pendingClose:
            break
        }
    }

    public mutating func closeDelayElapsed() {
        if phase == .pendingClose { phase = .collapsed }
    }

    public mutating func showImmediately() { phase = .expanded }
    public mutating func hideImmediately() { phase = .collapsed }
}

private final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class EdgeDockController: NSObject {
    private let log = Logger(subsystem: "app.shiori.desktop", category: "dock")
    private let store: NotesStore
    private let settings: SettingsStore
    private let openNote: (String, NSPoint?) -> Void
    private let createNote: () -> Void
    private let reportError: (Error) -> Void

    private var panel: DockPanel?
    private var dockView: DockView?
    private var primaryDisplayID: CGDirectDisplayID?
    private var pendingAnchor: Double?
    private var phaseMachine = DockStateMachine()
    private var transitionToken = 0
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var settingsCancellable: AnyCancellable?
    private var storeCancellable: AnyCancellable?
    private var visible = true

    public init(
        store: NotesStore,
        settings: SettingsStore,
        open: @escaping (String, NSPoint?) -> Void,
        create: @escaping () -> Void,
        reportError: @escaping (Error) -> Void = { error in
            let alert = NSAlert()
            alert.messageText = "The note order could not be saved"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    ) {
        self.store = store
        self.settings = settings
        self.openNote = open
        self.createNote = create
        self.reportError = reportError
        super.init()
        primaryDisplayID = Self.displayID(for: NSScreen.main ?? NSScreen.screens.first)
        makePanel()
        refreshLayout()

        settingsCancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
        storeCancellable = store.$notes.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
    }

    var phase: DockPhase { phaseMachine.phase }

    func refreshLayout() {
        refreshLayout(animated: true)
    }

    private func refreshLayout(animated: Bool) {
        guard let panel, let dockView else { return }
        guard let screen = retainedScreen() else { return }
        let notes = store.active
        dockView.notes = notes
        dockView.edge = settings.edge == "left" ? .left : .right
        let availableCardHeight = max(0, screen.visibleFrame.height - DockView.plusHeight - DockView.cardPadding * 2 - DockView.cardHeight)
        dockView.visibleCardLimit = min(DockView.maxVisibleCards, max(1, Int(availableCardHeight / DockView.cardOverlap) + 1))
        dockView.scrollLimit = max(0, notes.count - dockView.visibleCardLimit)
        dockView.scrollIndex = min(dockView.scrollIndex, dockView.scrollLimit)
        dockView.needsDisplay = true

        let frame = frame(for: screen, expanded: phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose)
        setPanelFrame(panel, to: frame, animated: animated)
        panel.collectionBehavior = settings.collectionBehavior
        if visible && !panel.isVisible { panel.orderFrontRegardless() }
    }

    func setVisible(_ isVisible: Bool) {
        if !isVisible { finishAnchorDrag() }
        visible = isVisible
        if isVisible {
            panel?.orderFrontRegardless()
        } else {
            cancelTransitions()
            phaseMachine.hideImmediately()
            panel?.orderOut(nil)
        }
    }

    func toggle() {
        guard visible else { setVisible(true); return }
        if phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose {
            cancelTransitions()
            phaseMachine.hideImmediately()
            refreshLayout()
        } else {
            cancelTransitions()
            phaseMachine.showImmediately()
            refreshLayout()
        }
    }

    /// Re-evaluates the display after a display arrangement change.
    func displayConfigurationChanged() { refreshLayout() }

    private func setPanelFrame(_ panel: NSPanel, to frame: NSRect, animated: Bool) {
        guard panel.frame != frame else { return }
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true, animate: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = phaseMachine.phase == .expanded ? 0.18 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func makePanel() {
        let panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: DockView.collapsedWidth, height: DockView.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = settings.collectionBehavior

        let view = DockView(controller: self)
        panel.contentView = view
        self.panel = panel
        self.dockView = view
    }

    private func retainedScreen() -> NSScreen? {
        if let id = primaryDisplayID,
           let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == id }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func frame(for screen: NSScreen, expanded: Bool) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let anchor = pendingAnchor ?? settings.anchor
        guard expanded else {
            let height = DockView.collapsedHeight
            let y = visibleFrame.minY + (visibleFrame.height * anchor) - (height / 2)
            let x = settings.edge == "left"
                ? visibleFrame.minX - 1
                : visibleFrame.maxX - DockView.collapsedWidth + 1
            return NSRect(
                x: x,
                y: min(max(y, visibleFrame.minY), visibleFrame.maxY - height),
                width: DockView.collapsedWidth,
                height: height
            )
        }

        let cardHeight = DockView.cardHeight
        let overlap = DockView.cardOverlap
        let visibleCount = min(DockView.maxVisibleCards, max(1, store.active.count))
        let desiredHeight = DockView.plusHeight + DockView.cardPadding * 2
            + cardHeight + CGFloat(max(0, visibleCount - 1)) * overlap
        let height = min(max(desiredHeight, DockView.collapsedHeight), visibleFrame.height)
        let center = visibleFrame.minY + visibleFrame.height * anchor
        let y = min(max(center - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        let width = DockView.expandedWidth
        let x = settings.edge == "left" ? visibleFrame.minX : visibleFrame.maxX - width
        return NSRect(x: x, y: y, width: width, height: height)
    }

    fileprivate func entered() {
        guard visible else { return }
        cancelClose()
        if phaseMachine.phase == .pendingClose {
            phaseMachine.showImmediately()
            refreshLayout()
            return
        }
        phaseMachine.pointerEntered()
        guard phaseMachine.phase == .pendingOpen else { return }
        scheduleOpen()
    }

    fileprivate func exited() {
        guard visible else { return }
        cancelOpen()
        phaseMachine.pointerExited()
        guard phaseMachine.phase == .pendingClose else { return }
        scheduleClose()
    }

    fileprivate func keepOpen() {
        cancelClose()
        if phaseMachine.phase == .pendingClose { phaseMachine.showImmediately() }
    }

    private func scheduleOpen() {
        openWork?.cancel()
        transitionToken += 1
        let token = transitionToken
        let delay = max(0, settings.openDelay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.phaseMachine.openDelayElapsed()
            self.refreshLayout()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleClose() {
        closeWork?.cancel()
        transitionToken += 1
        let token = transitionToken
        let delay = max(0, settings.closeDelay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.phaseMachine.closeDelayElapsed()
            self.refreshLayout()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelOpen() { openWork?.cancel(); openWork = nil }
    private func cancelClose() { closeWork?.cancel(); closeWork = nil }

    private func cancelTransitions() {
        transitionToken += 1
        cancelOpen()
        cancelClose()
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    fileprivate func moveAnchor(to screenPoint: NSPoint) {
        guard let screen = retainedScreen() else { return }
        let visibleFrame = screen.visibleFrame
        pendingAnchor = min(1, max(0, (screenPoint.y - visibleFrame.minY) / visibleFrame.height))
        refreshLayout(animated: false)
    }

    fileprivate func finishAnchorDrag() {
        guard let pendingAnchor else { return }
        self.pendingAnchor = nil
        settings.anchor = pendingAnchor
        refreshLayout(animated: false)
    }

    fileprivate func didClick(note: Note, at screenPoint: NSPoint) {
        keepOpen()
        openNote(note.id, screenPoint)
    }

    fileprivate func didClickCreate() {
        keepOpen()
        createNote()
    }

    fileprivate func didFinishReorder(ids: [String]) {
        guard ids.isEmpty == false else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.reorder(ids: ids)
                self.refreshLayout()
            } catch {
                self.log.error("Could not persist dock order (\(String(reflecting: type(of: error)), privacy: .public))")
                self.reportError(error)
                self.refreshLayout()
            }
        }
    }
}

private final class DockAccessibilityAction: NSAccessibilityElement, @unchecked Sendable {
    // AppKit invokes accessibility callbacks on the main thread; this element
    // is only a bridge to the main-actor dock view.
    enum Kind: Sendable {
        case create
        case note(String)
        case grip
    }

    nonisolated(unsafe) weak var owner: DockView?
    let kind: Kind

    init(owner: DockView, kind: Kind) {
        self.owner = owner
        self.kind = kind
        super.init()
        setAccessibilityParent(owner)
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        if case .grip = kind { return .slider }
        return .button
    }

    override func accessibilityLabel() -> String? {
        let owner = owner
        let kind = kind
        return MainActor.assumeIsolated {
            guard let owner else { return nil }
            switch kind {
            case .create:
                return "Create note"
            case .grip:
                return "Move notes dock"
            case .note(let id):
                guard let note = owner.notes.first(where: { $0.id == id }) else { return "Note" }
                return note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : note.title
            }
        }
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner
        let kind = kind
        return MainActor.assumeIsolated {
            guard let owner, let window = owner.window else { return .zero }
            return window.convertToScreen(owner.actionFrame(for: kind))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let owner = owner
        let kind = kind
        return MainActor.assumeIsolated {
            guard let owner else { return false }
            switch kind {
            case .create:
                owner.controller?.didClickCreate()
                return true
            case .note(let id):
                owner.accessibleOpen(id)
                return true
            case .grip:
                return false
            }
        }
    }
}

@MainActor
private final class DockView: NSView {
    enum Edge { case left, right }

    static let collapsedWidth: CGFloat = 30
    static let collapsedHeight: CGFloat = 108
    static let expandedWidth: CGFloat = 332
    static let cardWidth: CGFloat = 286
    static let cardHeight: CGFloat = 94
    static let cardOverlap: CGFloat = 55
    static let cardPadding: CGFloat = 12
    static let plusHeight: CGFloat = 38
    static let maxVisibleCards = 8

    weak var controller: EdgeDockController?
    var notes: [Note] = [] { didSet { needsDisplay = true } }
    var edge: Edge = .right { didSet { needsDisplay = true } }
    var visibleCardLimit = maxVisibleCards
    var scrollLimit = 0
    var scrollIndex = 0
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint?
    private var dragIndex: Int?
    private var dragIDs: [String]?
    private var dragTargetIndex: Int?
    private var draggingGrip = false
    private var plusPressed = false
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(controller: EdgeDockController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("SHIORI Notes dock")
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        addTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        addTrackingArea()
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The panel itself is small and only this view receives events; no
        // transparent full-screen event catcher is involved.
        return bounds.contains(point) ? self : nil
    }

    override func accessibilityChildren() -> [Any] {
        var children: [Any] = [DockAccessibilityAction(owner: self, kind: .create)]
        for note in visibleNotes {
            children.append(DockAccessibilityAction(owner: self, kind: .note(note.id)))
        }
        children.append(DockAccessibilityAction(owner: self, kind: .grip))
        return children
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if controller?.phase == .expanded || controller?.phase == .pendingClose {
            drawDeck()
        } else {
            drawCollapsed()
        }
    }

    override func mouseEntered(with event: NSEvent) { controller?.entered() }

    override func mouseExited(with event: NSEvent) {
        if draggingGrip || dragIndex != nil { return }
        controller?.exited()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isExpanded else { return }
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = cardIndex(at: point)
        if hoveredIndex != newIndex {
            hoveredIndex = newIndex
            needsDisplay = true
        }
        controller?.keepOpen()
    }

    override func scrollWheel(with event: NSEvent) {
        guard isExpanded, scrollLimit > 0 else { return }
        if abs(event.scrollingDeltaY) < 0.01 { return }
        scrollIndex = min(scrollLimit, max(0, scrollIndex + (event.scrollingDeltaY > 0 ? -1 : 1)))
        needsDisplay = true
        controller?.keepOpen()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        draggingGrip = isGrip(point)
        plusPressed = false
        if isExpanded {
            if plusFrame.contains(point) {
                plusPressed = true
                return
            }
            dragIndex = cardIndex(at: point)
            dragIDs = visibleNotes.map(\.id)
        } else {
            dragIndex = nil
            dragIDs = nil
        }
        dragTargetIndex = nil
        controller?.keepOpen()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if draggingGrip {
            let screenPoint = window?.convertPoint(toScreen: point) ?? point
            controller?.moveAnchor(to: screenPoint)
            return
        }
        guard let dragIndex, let dragIDs, dragIDs.indices.contains(dragIndex) else { return }
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        let target = targetIndex(at: point)
        if dragTargetIndex != target {
            dragTargetIndex = target
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragIndex = nil
            dragIDs = nil
            dragTargetIndex = nil
            draggingGrip = false
            plusPressed = false
            needsDisplay = true
        }

        let point = convert(event.locationInWindow, from: nil)
        let releasedOutside = !bounds.contains(point)
        if releasedOutside {
            if draggingGrip {
                controller?.finishAnchorDrag()
            } else if let ids = reorderedIDs() {
                controller?.didFinishReorder(ids: ids)
            }
            controller?.exited()
            return
        }
        if draggingGrip {
            controller?.finishAnchorDrag()
            return
        }
        if plusPressed {
            controller?.didClickCreate()
            return
        }
        guard isExpanded else {
            controller?.didClickCreate()
            return
        }
        if let index = cardIndex(at: point), dragTargetIndex == nil, visibleNotes.indices.contains(index) {
            let note = visibleNotes[index]
            let screenPoint = window?.convertPoint(toScreen: cardFrame(at: index).origin)
                ?? NSPoint(x: 0, y: 0)
            controller?.didClick(note: note, at: screenPoint)
            return
        }
        if let ids = reorderedIDs() { controller?.didFinishReorder(ids: ids) }
    }

    private var isExpanded: Bool {
        controller?.phase == .expanded || controller?.phase == .pendingClose
    }

    private var visibleNotes: [Note] {
        guard notes.isEmpty == false else { return [] }
        let start = min(scrollIndex, max(0, notes.count - 1))
        return Array(notes.dropFirst(start).prefix(visibleCardLimit))
    }

    private func addTrackingArea() {
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    private func drawCollapsed() {
        let rect = NSRect(x: edge == .left ? 5 : 7, y: 8, width: 14, height: bounds.height - 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let active = notes
        guard active.isEmpty == false else {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4)).fill()
            return
        }
        let gap: CGFloat = active.count > 40 ? 0 : 2
        let segmentHeight = max(0.7, min(13, (rect.height - gap * CGFloat(active.count - 1)) / CGFloat(active.count)))
        let total = segmentHeight * CGFloat(active.count) + gap * CGFloat(active.count - 1)
        var y = rect.midY + total / 2 - segmentHeight
        for note in active {
            let segment = NSRect(x: rect.minX + 2, y: y, width: rect.width - 4, height: segmentHeight)
            Theme.nsColor(note.colorIndex).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 3, yRadius: 3).fill()
            y -= segmentHeight + gap
        }
        drawGrip(at: edge == .left ? rect.maxX + 2 : rect.minX - 2, y: rect.midY)
    }

    private func drawDeck() {
        let panel = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let surface = NSBezierPath(roundedRect: panel.insetBy(dx: 3, dy: 3), xRadius: 15, yRadius: 15)
        NSColor.windowBackgroundColor.withAlphaComponent(0.4).setFill()
        surface.fill()

        let rendered = renderedNotes
        // Draw lower cards last so each upper title strip remains visible.
        for index in rendered.indices {
            drawCard(rendered[index], at: index, highlighted: false)
        }
        if let hoveredIndex, rendered.indices.contains(hoveredIndex) {
            drawCard(rendered[hoveredIndex], at: hoveredIndex, highlighted: true)
        }
        drawGrip(at: edge == .left ? bounds.width - 8 : 8, y: bounds.midY)

        let plus = plusFrame
        NSColor.controlAccentColor.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: plus, xRadius: 10, yRadius: 10).fill()
        let plusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        "+".draw(in: plus, withAttributes: plusAttributes)
    }

    private func drawCard(_ note: Note, at index: Int, highlighted: Bool) {
        let base = cardFrame(at: index)
        var rect = base
        if highlighted { rect.origin.x += edge == .left ? 7 : -7 }
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor.black.withAlphaComponent(highlighted ? 0.18 : 0.1).setFill()
        path.fill()
        let card = rect.offsetBy(dx: 0, dy: highlighted ? 3 : 1)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        Theme.nsColor(note.colorIndex).setFill()
        cardPath.fill()

        let gripX = edge == .left ? card.minX + 9 : card.maxX - 9
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        for dotIndex in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: gripX - 1.5, y: card.midY - 8 + CGFloat(dotIndex) * 8, width: 3, height: 3)).fill()
        }

        let inset = card.insetBy(dx: 14, dy: 10)
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : note.title
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        (title as NSString).draw(in: NSRect(x: inset.minX, y: inset.maxY - 18, width: inset.width - 24, height: 18), withAttributes: titleAttributes)
        if note.pinned {
            NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?.draw(in: NSRect(x: inset.maxX - 15, y: inset.maxY - 16, width: 13, height: 13))
        }

        let preview = bodyPreview(note.body)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)
        ]
        (preview as NSString).draw(in: NSRect(x: inset.minX, y: inset.minY + 11, width: inset.width, height: 34), withAttributes: bodyAttributes)
        let timestampAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (timestamp(note.updatedAt) as NSString).draw(in: NSRect(x: inset.minX, y: inset.minY - 1, width: inset.width, height: 14), withAttributes: timestampAttributes)
    }

    private func bodyPreview(_ body: String) -> String {
        // Previewing the first small slice keeps repaint cost bounded for long notes.
        let compact = String(body.prefix(180)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if compact.isEmpty { return "No text yet" }
        return compact.count > 88 ? String(compact.prefix(85)) + "…" : compact
    }

    private var renderedNotes: [Note] {
        guard let source = dragIndex, let target = dragTargetIndex,
              visibleNotes.indices.contains(source), visibleNotes.indices.contains(target), source != target else {
            return visibleNotes
        }
        var result = visibleNotes
        let moved = result.remove(at: source)
        result.insert(moved, at: target)
        return result
    }

    private func drawGrip(at x: CGFloat, y: CGFloat) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.72).setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let dot = NSRect(x: x + CGFloat(column) * 4 - 2, y: y - 7 + CGFloat(row) * 7, width: 2.5, height: 2.5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    private func timestamp(_ value: TimeInterval) -> String {
        Self.timestampFormatter.string(from: Date(timeIntervalSince1970: value))
    }

    private func cardFrame(at index: Int) -> NSRect {
        let x = edge == .left ? 38 : bounds.width - Self.cardWidth - 38
        let y = Self.plusHeight + Self.cardPadding + CGFloat(max(0, visibleNotes.count - index - 1)) * Self.cardOverlap
        return NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight)
    }

    private var plusFrame: NSRect {
        let x = edge == .left ? 38 : bounds.width - 38 - 52
        return NSRect(x: x, y: 10, width: 52, height: Self.plusHeight)
    }

    private func cardIndex(at point: NSPoint) -> Int? {
        guard isExpanded else { return nil }
        for index in visibleNotes.indices.reversed() where cardFrame(at: index).contains(point) { return index }
        return nil
    }

    private func targetIndex(at point: NSPoint) -> Int? {
        guard let source = dragIndex, visibleNotes.indices.contains(source) else { return nil }
        var target: Int?
        for index in visibleNotes.indices {
            let frame = cardFrame(at: index)
            if point.y >= frame.midY { target = index; break }
        }
        target = target ?? max(0, visibleNotes.count - 1)
        if target == source { return nil }
        return target
    }

    private func reorderedIDs() -> [String]? {
        guard let source = dragIndex, let target = dragTargetIndex, visibleNotes.indices.contains(source), visibleNotes.indices.contains(target) else { return nil }
        var ids = notes.map(\.id)
        let from = scrollIndex + source
        let to = scrollIndex + target
        guard ids.indices.contains(from), ids.indices.contains(to), from != to else { return nil }
        let id = ids.remove(at: from)
        ids.insert(id, at: to)
        return ids
    }

    private func isGrip(_ point: NSPoint) -> Bool {
        let x = edge == .left ? bounds.width - 5 : 0
        return NSRect(x: x, y: bounds.midY - 20, width: 10, height: 40).contains(point)
    }

    fileprivate func actionFrame(for kind: DockAccessibilityAction.Kind) -> NSRect {
        switch kind {
        case .create:
            return plusFrame
        case .note(let id):
            guard let index = visibleNotes.firstIndex(where: { $0.id == id }) else { return .zero }
            return cardFrame(at: index)
        case .grip:
            return NSRect(x: edge == .left ? bounds.width - 16 : 0, y: bounds.midY - 24, width: 16, height: 48)
        }
    }

    fileprivate func accessibleOpen(_ id: String) {
        guard let index = visibleNotes.firstIndex(where: { $0.id == id }) else { return }
        let note = visibleNotes[index]
        let point = window?.convertPoint(toScreen: cardFrame(at: index).origin) ?? .zero
        controller?.didClick(note: note, at: point)
    }
}
