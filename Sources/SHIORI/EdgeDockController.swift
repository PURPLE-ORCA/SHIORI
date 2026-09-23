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
    private let appAttachment: AppAttachmentContext?
    private var appBundleIdentifier: String?
    private var appAnchor: Double = 0.5
    private let privacy: PrivacyLock?
    private var privacySubscription: AnyCancellable?
    private var privacyLocked = false
    private let openNote: (String, NSRect?) -> Void
    private let createNote: () -> Void
    private let pointerLocation: () -> NSPoint
    private let reportError: (Error) -> Void

    private var panel: DockPanel?
    private var dockView: DockView?
    private let fixedDisplayID: CGDirectDisplayID?
    private var primaryDisplayID: CGDirectDisplayID?
    private var pendingAnchor: Double?
    private var phaseMachine = DockStateMachine()
    private var transitionToken = 0
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var settingsCancellable: AnyCancellable?
    private var storeCancellable: AnyCancellable?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var visible = true
    private var positionedDisplayID: CGDirectDisplayID?

    public init(
        store: NotesStore,
        settings: SettingsStore,
        displayID: CGDirectDisplayID? = nil,
        privacy: PrivacyLock? = nil,
        appAttachment: AppAttachmentContext? = nil,
        open: @escaping (String, NSRect?) -> Void,
        create: @escaping () -> Void,
        pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
        reportError: @escaping (Error) -> Void = { error in
            let alert = NSAlert()
            alert.messageText = "The note order could not be saved"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    ) {
        self.appAttachment = appAttachment
        self.store = store
        self.privacy = privacy
        self.privacyLocked = privacy?.isLocked == true
        self.settings = settings
        self.fixedDisplayID = displayID
        self.openNote = open
        self.createNote = create
        self.pointerLocation = pointerLocation
        self.reportError = reportError
        super.init()
        primaryDisplayID = (settings.defaults.object(forKey: "edgeDisplayID") as? NSNumber)?.uint32Value ?? Self.displayID(for: NSScreen.main ?? NSScreen.screens.first)
        makePanel()
        refreshLayout()
        installMouseMonitors()
        privacySubscription = privacy?.$isLocked.sink { [weak self] locked in
            guard let self else { return }
            self.privacyLocked = locked
            self.dockView?.privacyLocked = locked
            self.refreshLayout(animated: false)
            self.dockView?.displayIfNeeded()
        }

        settingsCancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
        storeCancellable = store.$notes.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
    }

    fileprivate var isAppDock: Bool { appAttachment != nil }
    var phase: DockPhase { phaseMachine.phase }
    var displayedNotes: [Note] {
        store.active.filter { note in
            if let appAttachment {
                return note.attachedAppBundleIdentifier != nil &&
                    note.attachedAppBundleIdentifier == appAttachment.currentBundleIdentifier
            }
            return note.attachedAppBundleIdentifier == nil
        }
    }

    private func anchorFrame(on screen: NSScreen) -> NSRect {
        guard let appAttachment else { return screen.visibleFrame }
        return appAttachment.windowFrame?.intersection(screen.visibleFrame) ?? .zero
    }

    func refreshLayout() {
        refreshLayout(animated: true)
    }

    /// Returns the projected card frame in screen coordinates without opening
    /// the deck. The editor uses this to choose its initial position.
    func cardScreenFrame(for id: String) -> NSRect? {
        guard let screen = retainedScreen(), let dockView else { return nil }
        guard let index = dockView.visibleNoteIndex(for: id) else { return nil }
        let expanded = frame(for: screen, expanded: true)
        let card = (phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose)
            ? dockView.displayCardFrame(at: index) : dockView.cardFrame(at: index, width: expanded.width)
        return NSRect(x: expanded.minX + card.minX, y: expanded.minY + card.minY, width: card.width, height: card.height)
    }

    func returnFrame(for id: String) -> NSRect? {
        guard let screen = retainedScreen(), displayedNotes.contains(where: { $0.id == id }) else { return nil }
        if appAttachment != nil {
            let collapsed = frame(for: screen, expanded: false)
            return NSRect(x: settings.edge == "left" ? collapsed.minX : collapsed.maxX - 14,
                          y: collapsed.minY, width: 14, height: collapsed.height)
        }
        let origin = cardScreenFrame(for: id)?.origin ?? frame(for: screen, expanded: false).origin
        let x = settings.edge == "left" ? screen.visibleFrame.minX - 184 : screen.visibleFrame.maxX - 40
        return NSRect(x: x, y: origin.y, width: 224, height: 170)
    }

    func creationFrame() -> NSRect? {
        guard let screen = retainedScreen() else { return nil }
        let expanded = frame(for: screen, expanded: true)
        let anchor = anchorFrame(on: screen)
        let x = settings.edge == "left" ? anchor.minX + 23 : anchor.maxX - 23
        return NSRect(x: x - 112, y: expanded.minY + 22 - 85, width: 224, height: 170)
    }

    private func refreshLayout(animated: Bool) {
        guard let panel, let dockView else { return }
        if let appAttachment, appBundleIdentifier != appAttachment.currentBundleIdentifier {
            appBundleIdentifier = appAttachment.currentBundleIdentifier
            cancelTransitions()
            phaseMachine.hideImmediately()
            dockView.scrollIndex = 0
        }
        guard let screen = retainedScreen(),
              appAttachment == nil || (appAttachment?.hasVisibleWindow == true && !displayedNotes.isEmpty) else {
            cancelTransitions()
            phaseMachine.hideImmediately()
            panel.orderOut(nil)
            return
        }
        let anchor = anchorFrame(on: screen)
        guard !anchor.isEmpty, !anchor.isNull else { panel.orderOut(nil); return }
        let notes = privacyLocked ? displayedNotes.map(PrivacyLock.concealed) : displayedNotes
        if dockView.notes != notes { dockView.notes = notes }
        let edge: DockView.Edge = settings.edge == "left" ? .left : .right
        if dockView.edge != edge { dockView.edge = edge }
        let availableCardHeight = max(0, screen.visibleFrame.height - DockView.plusHeight - DockView.cardPadding * 2 - DockView.cardHeight)
        dockView.visibleCardLimit = max(1, Int(availableCardHeight / DockView.cardOverlap) + 1)
        dockView.scrollLimit = max(0, notes.count - dockView.visibleCardLimit)
        dockView.scrollIndex = min(dockView.scrollIndex, dockView.scrollLimit)
        positionedDisplayID = Self.displayID(for: screen)

        let frame = frame(for: screen, expanded: phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose)
        setPanelFrame(panel, to: frame, animated: animated)
        let anchorY = self.frame(for: screen, expanded: false).midY - frame.minY
        if dockView.anchorY != anchorY {
            dockView.anchorY = anchorY
            dockView.needsDisplay = true
        }
        refreshHitRegion()
        panel.collectionBehavior = settings.collectionBehavior
        if visible && !panel.isVisible { panel.orderFrontRegardless() }
    }

    func refreshPosition() {
        guard appAttachment != nil, visible, let panel, panel.isVisible, let dockView,
              let screen = retainedScreen() else { return }
        guard positionedDisplayID == Self.displayID(for: screen) else { refreshLayout(); return }
        let target = frame(for: screen, expanded: phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose)
        setPanelFrame(panel, to: target, animated: false)
        let anchorY = frame(for: screen, expanded: false).midY - target.minY
        if dockView.anchorY != anchorY {
            dockView.anchorY = anchorY
            dockView.needsDisplay = true
        }
        refreshHitRegion()
    }

    func setVisible(_ isVisible: Bool) {
        guard visible != isVisible else { return }
        if !isVisible { finishAnchorDrag() }
        visible = isVisible
        if isVisible {
            refreshLayout()
            updatePointerInteraction()
        } else {
            cancelTransitions()
            phaseMachine.hideImmediately()
            panel?.ignoresMouseEvents = true
            panel?.orderOut(nil)
        }
    }

    func toggle() {
        guard visible else { setVisible(true); return }
        if phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose {
            cancelTransitions()
            phaseMachine.pointerExited()
            scheduleClose(delay: 0)
        } else {
            cancelTransitions()
            dockView?.prepareDeckEntry()
            phaseMachine.showImmediately()
            refreshLayout(animated: false)
            dockView?.animateDeckEntry()
        }
    }

    /// Re-evaluates the display after a display arrangement change.
    func displayConfigurationChanged() { refreshLayout() }

    private func setPanelFrame(_ panel: NSPanel, to frame: NSRect, animated _: Bool) {
        guard panel.frame != frame else { return }
        // The panel bounds change instantly; the layer transform below slides
        // the fan, so the cards never stretch while the window resizes.
        if panel.frame.size == frame.size { panel.setFrameOrigin(frame.origin) }
        else { panel.setFrame(frame, display: true, animate: false) }
    }

    private func makePanel() {
        let panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: DockView.collapsedWidth, height: DockView.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = settings.collectionBehavior

        let view = DockView(controller: self)
        panel.contentView = view
        self.panel = panel
        self.dockView = view
    }

    func stop() {
        cancelTransitions()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil; globalMouseMonitor = nil
        settingsCancellable = nil; storeCancellable = nil; privacySubscription = nil
        dockView?.stopAnimations()
        panel?.close()
        panel = nil; dockView = nil
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerInteraction() }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerInteraction() }
        }
    }

    fileprivate func refreshHitRegion() {
        guard let panel, let dockView else { return }
        panel.ignoresMouseEvents = !visible || !panel.isVisible || (!dockView.isDragging && !dockView.interactiveContains(screenPoint: pointerLocation(), in: panel))
    }

    fileprivate func updatePointerInteraction() {
        guard visible, let panel, panel.isVisible, let dockView else { return }
        let screenPoint = pointerLocation()
        if dockView.isDragging {
            panel.ignoresMouseEvents = false
            return
        }
        let inside = dockView.interactiveContains(screenPoint: screenPoint, in: panel)
        panel.ignoresMouseEvents = !inside
        if inside {
            dockView.updateHover(screenPoint: screenPoint, in: panel)
            if phaseMachine.phase == .collapsed { entered() } else { keepOpen() }
        } else if phaseMachine.phase == .expanded || phaseMachine.phase == .pendingClose || phaseMachine.phase == .pendingOpen {
            exited()
        }
    }

    private func retainedScreen() -> NSScreen? {
        if let appAttachment {
            guard let frame = appAttachment.windowFrame else { return nil }
            return NSScreen.screens.filter { $0.visibleFrame.intersects(frame) }.max {
                let left = $0.visibleFrame.intersection(frame)
                let right = $1.visibleFrame.intersection(frame)
                return left.width * left.height < right.width * right.height
            }
        }
        if let id = fixedDisplayID { return NSScreen.screens.first { Self.displayID(for: $0) == id } }
        if let id = primaryDisplayID,
           let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == id }) {
            return screen
        }
        let fallback = NSScreen.screens.first
        primaryDisplayID = Self.displayID(for: fallback)
        settings.defaults.set(primaryDisplayID, forKey: "edgeDisplayID")
        return fallback
    }

    private func frame(for screen: NSScreen, expanded: Bool) -> NSRect {
        let visibleFrame = anchorFrame(on: screen)
        let anchor = pendingAnchor ?? (appAttachment == nil ? settings.anchor : appAnchor)
        var center = visibleFrame.minY + visibleFrame.height * anchor
        if appAttachment != nil {
            let atScreenEdge = settings.edge == "left"
                ? visibleFrame.minX - screen.visibleFrame.minX < DockView.collapsedWidth
                : screen.visibleFrame.maxX - visibleFrame.maxX < DockView.collapsedWidth
            let screenCenter = min(max(screen.visibleFrame.minY + screen.visibleFrame.height * settings.anchor,
                                       screen.visibleFrame.minY + DockView.collapsedHeight / 2),
                                   screen.visibleFrame.maxY - DockView.collapsedHeight / 2)
            let separation = DockView.collapsedHeight + 12
            if atScreenEdge, abs(center - screenCenter) < separation {
                // Keep both stacks reachable when an app fills the screen.
                center = screenCenter + separation + DockView.collapsedHeight / 2 <= visibleFrame.maxY
                    ? screenCenter + separation : screenCenter - separation
            }
        }
        guard expanded else {
            let height = min(DockView.collapsedHeight, visibleFrame.height)
            let y = center - height / 2
            let x = settings.edge == "left"
                ? visibleFrame.minX
                : visibleFrame.maxX - DockView.collapsedWidth
            return NSRect(
                x: x,
                y: min(max(y, visibleFrame.minY), visibleFrame.maxY - height),
                width: DockView.collapsedWidth,
                height: height
            )
        }

        let cardHeight = DockView.cardHeight
        let overlap = DockView.cardOverlap
        let visibleCount = min(dockView?.visibleCardLimit ?? 1, max(1, dockView?.notes.count ?? 0))
        let desiredHeight = DockView.plusHeight + DockView.cardPadding * 2
            + cardHeight + CGFloat(max(0, visibleCount - 1)) * overlap
        let height = min(max(desiredHeight, DockView.collapsedHeight), screen.visibleFrame.height)
        let y = min(max(center - height / 2, screen.visibleFrame.minY), screen.visibleFrame.maxY - height)
        let width = DockView.expandedWidth
        let x = settings.edge == "left" ? visibleFrame.minX : visibleFrame.maxX - width
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func entered() {
        guard visible else { return }
        cancelClose()
        if phaseMachine.phase == .pendingClose {
            dockView?.cancelDeckAnimation()
            phaseMachine.showImmediately()
            refreshLayout()
            return
        }
        phaseMachine.pointerEntered()
        guard phaseMachine.phase == .pendingOpen else { return }
        scheduleOpen()
    }

    func exited() {
        guard visible, dockView?.isDragging != true else { return }
        let wasExpanded = phaseMachine.phase == .expanded
        cancelOpen()
        phaseMachine.pointerExited()
        guard wasExpanded, phaseMachine.phase == .pendingClose else { return }
        scheduleClose()
    }


    fileprivate func beginDrag() {
        cancelOpen()
        if phaseMachine.phase == .pendingOpen { phaseMachine.hideImmediately() }
        keepOpen()
    }

    fileprivate func keepOpen() {
        cancelClose()
        if phaseMachine.phase == .pendingClose {
            dockView?.cancelDeckAnimation()
            phaseMachine.showImmediately()
        }
    }

    private func scheduleOpen() {
        openWork?.cancel()
        transitionToken += 1
        let token = transitionToken
        let delay = max(0, settings.openDelay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionToken == token, self.phaseMachine.phase == .pendingOpen else { return }
            self.dockView?.prepareDeckEntry()
            self.phaseMachine.openDelayElapsed()
            self.refreshLayout(animated: false)
            self.dockView?.animateDeckEntry()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleClose(delay requestedDelay: Double? = nil) {
        closeWork?.cancel()
        transitionToken += 1
        let token = transitionToken
        let delay = max(0, requestedDelay ?? settings.closeDelay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.dockView?.animateDeckExit()
            let finish = DispatchWorkItem { [weak self] in
                guard let self, self.transitionToken == token else { return }
                self.phaseMachine.closeDelayElapsed()
                self.refreshLayout(animated: false)
            }
            self.closeWork = finish
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.deckClose
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: finish)
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
        dockView?.cancelDeckAnimation()
    }

    static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    fileprivate func moveAnchor(to screenPoint: NSPoint) {
        let screen = fixedDisplayID == nil && appAttachment == nil ? NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? retainedScreen() : retainedScreen()
        guard let screen else { return }
        if fixedDisplayID == nil && appAttachment == nil {
            primaryDisplayID = Self.displayID(for: screen)
            settings.defaults.set(primaryDisplayID, forKey: "edgeDisplayID")
        }
        let visibleFrame = anchorFrame(on: screen)
        guard visibleFrame.height > 0 else { return }
        pendingAnchor = min(1, max(0, (screenPoint.y - visibleFrame.minY) / visibleFrame.height))
        refreshLayout(animated: false)
    }

    fileprivate func finishAnchorDrag() {
        guard let pendingAnchor else { return }
        self.pendingAnchor = nil
        if appAttachment == nil { settings.anchor = pendingAnchor } else { appAnchor = pendingAnchor }
        refreshLayout(animated: false)
    }

    fileprivate func didClick(note: Note, at screenPoint: NSPoint) {
        if let privacy, privacy.isLocked {
            privacy.perform { [weak self] in self?.didClick(note: note, at: screenPoint) }
            return
        }
        keepOpen()
        openNote(note.id, cardScreenFrame(for: note.id) ?? NSRect(origin: screenPoint, size: NSSize(width: DockView.cardWidth, height: DockView.cardHeight)))
    }

    fileprivate func unlockNotes() { privacy?.perform {} }

    fileprivate func didClickCreate() {
        if let privacy, privacy.isLocked { privacy.perform { [weak self] in self?.didClickCreate() }; return }
        keepOpen()
        createNote()
    }

    fileprivate func didFinishReorder(ids: [String]) {
        guard ids.isEmpty == false else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Keep notes in other docks in their existing slots.
                let moved = Set(ids)
                var reordered = ids.makeIterator()
                let allIDs = self.store.active.map { moved.contains($0.id) ? (reordered.next() ?? $0.id) : $0.id }
                try await self.store.reorder(ids: allIDs)
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
                return "Move edge tabs"
            case .note(let id):
                if owner.privacyLocked { return "Locked note" }
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

struct DockTransition {
    let from: CGFloat
    let to: CGFloat
    let began: TimeInterval
    let duration: TimeInterval

    func finished(at time: TimeInterval) -> Bool { time >= began + duration }
    func value(at time: TimeInterval, eased: Bool = true) -> CGFloat {
        let t = min(1, max(0, (time - began) / duration))
        let progress = eased ? 1 - pow(1 - t, 3) : t
        return from + (to - from) * progress
    }
}

@MainActor
private final class DockView: NSView {
    enum Edge { case left, right }

    static let collapsedWidth: CGFloat = 30
    static let collapsedHeight: CGFloat = 108
    static let expandedWidth: CGFloat = 254
    static let cardWidth: CGFloat = 224
    static let cardHeight: CGFloat = 170
    static let cardOverlap: CGFloat = 74
    static let cardPadding: CGFloat = 14
    static let plusHeight: CGFloat = 44
    static let plusDiameter: CGFloat = 28
    static let tabWidth: CGFloat = 40
    static let peekDistance: CGFloat = 168

    weak var controller: EdgeDockController?
    var privacyLocked = false {
        didSet { previewCache.removeAll(); needsDisplay = true }
    }
    var notes: [Note] = [] {
        didSet {
            if notes.map(\.id) != oldValue.map(\.id) { resetHover() }
            let ids = Set(notes.map(\.id))
            previewCache = previewCache.filter { ids.contains($0.key) }
            needsDisplay = true
        }
    }
    var edge: Edge = .right { didSet { needsDisplay = true } }
    var visibleCardLimit = 1
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
    private var visualHoveredIndex: Int?
    private var lifts: [Int: CGFloat] = [:]
    private var hoverTransitions: [Int: DockTransition] = [:]
    private var deckTransition: DockTransition?
    private var displayLink: CADisplayLink?
    private var deckProgress: CGFloat = 1
    private var previewCache: [String: (body: String, text: NSAttributedString)] = [:]
    fileprivate var anchorY: CGFloat = collapsedHeight / 2
    private var plusHovered = false
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
        setAccessibilityLabel(controller.isAppDock ? "SHIORI app notes" : "SHIORI edge notes")
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
        containsInteraction(point) ? self : nil
    }

    fileprivate func interactiveContains(screenPoint: NSPoint, in panel: NSPanel) -> Bool {
        containsInteraction(panel.convertPoint(fromScreen: screenPoint))
    }

    private func containsInteraction(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if dockHitRect.contains(point) { return true }
        guard isExpanded else { return false }
        return plusPath.contains(point) || visibleNotes.indices.contains { cardPath(at: $0).contains(point) }
    }

    fileprivate func updateHover(screenPoint: NSPoint, in panel: NSPanel) {
        guard isExpanded else { return }
        let point = panel.convertPoint(fromScreen: screenPoint)
        let plus = plusPath.contains(point)
        if plus != plusHovered { plusHovered = plus; needsDisplay = true }
        let index = cardIndex(at: point)
        setHoveredIndex(index)
    }

    override func accessibilityChildren() -> [Any] {
        var children: [Any] = [DockAccessibilityAction(owner: self, kind: .create)]
        for note in visibleNotes {
            children.append(DockAccessibilityAction(owner: self, kind: .note(note.id)))
        }
        children.append(DockAccessibilityAction(owner: self, kind: .grip))
        return children
    }

    fileprivate func prepareDeckEntry() {
        deckTransition = nil
        resetHover()
        deckProgress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
    }

    fileprivate func animateDeckEntry() { animateDeck(to: 1, duration: Theme.Motion.deckOpen) }
    fileprivate func animateDeckExit() { animateDeck(to: 0, duration: Theme.Motion.deckClose) }
    fileprivate func cancelDeckAnimation() { animateDeck(to: 1, duration: Theme.Motion.deckOpen) }

    private func animateDeck(to target: CGFloat, duration: Double) {
        guard deckProgress != target, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            deckTransition = nil
            deckProgress = target
            needsDisplay = true
            return
        }
        deckTransition = DockTransition(from: deckProgress, to: target, began: CACurrentMediaTime(), duration: duration)
        startDisplayLink()
    }

    private func startDisplayLink() {
        if displayLink == nil {
            let link = self.displayLink(target: self, selector: #selector(advanceAnimations))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func advanceAnimations() {
        let now = CACurrentMediaTime()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let transition = deckTransition {
            deckProgress = reduced ? transition.to : transition.value(at: now, eased: false)
            if reduced || transition.finished(at: now) { deckTransition = nil }
        }
        for (index, transition) in hoverTransitions {
            lifts[index] = reduced ? transition.to : transition.value(at: now)
            if reduced || transition.finished(at: now) { hoverTransitions[index] = nil }
        }
        needsDisplay = true
        controller?.refreshHitRegion()
        if deckTransition == nil && hoverTransitions.isEmpty { displayLink?.isPaused = true }
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

    override func mouseEntered(with event: NSEvent) { controller?.updatePointerInteraction() }

    override func mouseExited(with event: NSEvent) {
        if draggingGrip || dragIndex != nil { return }
        controller?.updatePointerInteraction()
    }

    override func mouseMoved(with event: NSEvent) { controller?.updatePointerInteraction() }

    override func scrollWheel(with event: NSEvent) {
        guard isExpanded, scrollLimit > 0 else { return }
        if abs(event.scrollingDeltaY) < 0.01 { return }
        resetHover()
        scrollIndex = min(scrollLimit, max(0, scrollIndex + (event.scrollingDeltaY > 0 ? -1 : 1)))
        needsDisplay = true
        controller?.keepOpen()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if privacyLocked { controller?.unlockNotes(); return }
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        draggingGrip = !isExpanded || isGrip(point)
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
        controller?.beginDrag()
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
        guard dragStart != nil else { return }
        defer {
            dragStart = nil
            dragIndex = nil
            dragIDs = nil
            dragTargetIndex = nil
            draggingGrip = false
            plusPressed = false
            controller?.updatePointerInteraction()
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
            guard plusPath.contains(point) else { return }
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

    fileprivate var isDragging: Bool { draggingGrip || dragIndex != nil || plusPressed }

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
        let strip = NSRect(x: edge == .left ? 0 : bounds.width - 14, y: anchorY - 54, width: 14, height: 108)
        NSColor.black.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 7, yRadius: 7).fill()
        let colors = notes.isEmpty ? [0] : notes.map(\.colorIndex)
        let gap: CGFloat = 4
        let height = min(16, (92 - gap * CGFloat(colors.count - 1)) / CGFloat(colors.count))
        let total = CGFloat(colors.count) * height + CGFloat(colors.count - 1) * gap
        var y = anchorY + total / 2 - height
        for color in colors {
            Theme.nsColor(color).setFill()
            NSBezierPath(roundedRect: NSRect(x: strip.midX - 3, y: y, width: 6, height: max(1, height)), xRadius: 3, yRadius: 3).fill()
            y -= height + gap
        }
    }

    private func drawDeck() {
        let rendered = renderedNotes
        // Draw lower cards last so each upper title strip remains visible.
        for index in rendered.indices where liftProgress(at: index) == 0 {
            drawCard(rendered[index], at: index, highlighted: false)
        }
        for index in rendered.indices where liftProgress(at: index) > 0 && index != visualHoveredIndex {
            drawCard(rendered[index], at: index, highlighted: true)
        }
        if let index = visualHoveredIndex, rendered.indices.contains(index), liftProgress(at: index) > 0 {
            drawCard(rendered[index], at: index, highlighted: true)
        }
        drawGrip(at: edge == .left ? 15 : bounds.width - 15, y: anchorY)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(deckProgress)
        let plus = plusFrame
        NSColor(white: plusHovered ? 1 : 0.94, alpha: 0.98).setFill()
        plusPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        plusPath.lineWidth = 0.5
        plusPath.stroke()
        NSImage(systemSymbolName: "plus", accessibilityDescription: "Create note")?.draw(in: plus.insetBy(dx: 8, dy: 8))
    }

    private func drawCard(_ note: Note, at index: Int, highlighted: Bool) {
        let rect = displayCardFrame(at: index)
        NSGraphicsContext.saveGraphicsState()
        cardTransform(at: index).concat()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cardPath = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        let shadow = NSShadow()
        let depth = liftProgress(at: index)
        for (alpha, blur, offset) in [(0.07 + depth * 0.04, 16.0, -8.0), (0.18, 6.0, -3.0)] {
            NSGraphicsContext.saveGraphicsState()
            shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
            shadow.shadowBlurRadius = blur
            shadow.shadowOffset = NSSize(width: 0, height: offset)
            shadow.set()
            Theme.nsColor(note.colorIndex).setFill()
            cardPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.saveGraphicsState()
        cardPath.addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if privacyLocked {
            NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked note")?.draw(in: NSRect(x: edge == .left ? rect.maxX - 27 : rect.minX + 13, y: rect.maxY - 32, width: 14, height: 16))
            return
        }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : note.title
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: edge == .left ? rect.maxX - 20 : rect.minX + 20, yBy: rect.maxY - 16)
        transform.rotate(byDegrees: edge == .left ? 90 : -90)
        transform.concat()
        let labelLength = highlighted ? Self.cardHeight - 32 : Self.cardOverlap - 18
        (title as NSString).draw(in: NSRect(x: edge == .left ? -labelLength : 0, y: -9, width: labelLength, height: 20), withAttributes: [
            .font: Theme.roundedFont(size: 11, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.5),
            .kern: 0.8, .paragraphStyle: paragraph
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard highlighted else { return }
        let inset = NSRect(x: rect.minX + (edge == .right ? 38 : 32), y: rect.minY + 16, width: Self.cardWidth - 64, height: Self.cardHeight - 32)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.roundedFont(size: 15, weight: .semibold),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]
        (title as NSString).draw(in: NSRect(x: inset.minX, y: inset.maxY - 26, width: inset.width - 28, height: 26), withAttributes: titleAttributes)
        if note.pinned {
            NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?.draw(in: NSRect(x: inset.maxX - 18, y: inset.maxY - 20, width: 16, height: 16))
        }

        let timestampAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.roundedFont(size: 10),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55)
        ]
        (timestamp(note.updatedAt) as NSString).draw(in: NSRect(x: inset.minX, y: inset.maxY - 48, width: inset.width, height: 16), withAttributes: timestampAttributes)
        let bodyHeight = floor((inset.height - 68) / 19) * 19
        let bodyRect = NSRect(x: inset.minX, y: inset.maxY - 68 - bodyHeight, width: inset.width, height: bodyHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bodyRect).addClip()
        bodyPreview(note).draw(with: bodyRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func bodyPreview(_ note: Note) -> NSAttributedString {
        if let cached = previewCache[note.id], cached.body == note.body { return cached.text }
        let prefix = String(note.body.prefix(1200))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = 19
        paragraph.maximumLineHeight = 19
        let result = NSMutableAttributedString(attributedString: MarkdownPresentation.preview(prefix, attributes: [
            .font: Theme.roundedFont(size: 14),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82),
            .paragraphStyle: paragraph
        ]))
        let tasks = ChecklistEngine.tasks(in: result.string)
        for task in tasks.reversed() {
            if task.isChecked {
                result.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.52)
                ], range: task.contentRange)
            }
            let glyph = task.isChecked ? "☑ " : "☐ "
            result.replaceCharacters(in: task.markerRange, with: glyph)
        }
        previewCache[note.id] = (note.body, result)
        return result
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
        NSColor.black.withAlphaComponent(0.22).setFill()
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

    fileprivate func cardFrame(at index: Int, width: CGFloat? = nil) -> NSRect {
        let contentWidth = width ?? bounds.width
        let exposed = Self.tabWidth
        let x = edge == .left ? exposed - Self.cardWidth : contentWidth - exposed
        let y = Self.plusHeight + Self.cardPadding + CGFloat(max(0, visibleNotes.count - index - 1)) * Self.cardOverlap
        return NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight)
    }

    private func liftProgress(at index: Int) -> CGFloat {
        lifts[index] ?? 0
    }

    fileprivate func displayCardFrame(at index: Int) -> NSRect {
        var frame = cardFrame(at: index)
        let progress = Theme.Motion.deckProgress(deckProgress, index: index, count: visibleNotes.count)
        let slide = (1 - progress) * (Self.cardWidth + 24)
        let lift = Self.peekDistance * liftProgress(at: index)
        frame.origin.x += (edge == .left ? -1 : 1) * (slide - lift)
        return frame
    }

    fileprivate func visibleNoteIndex(for id: String) -> Int? {
        visibleNotes.firstIndex { $0.id == id }
    }

    private var plusFrame: NSRect {
        let restingX = edge == .left ? 9 : bounds.width - 9 - Self.plusDiameter
        let x = restingX + (edge == .left ? -1 : 1) * 16 * (1 - deckProgress)
        return NSRect(x: x, y: (Self.plusHeight - Self.plusDiameter) / 2, width: Self.plusDiameter, height: Self.plusDiameter)
    }

    private var dockHitRect: NSRect {
        NSRect(x: edge == .left ? 0 : bounds.width - 22, y: anchorY - 54, width: 22, height: 108)
    }

    private var plusPath: NSBezierPath {
        let frame = plusFrame
        return NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
    }

    private func cardTransform(at index: Int) -> NSAffineTransform {
        let rect = displayCardFrame(at: index)
        let transform = NSAffineTransform()
        let x = edge == .left ? rect.minX : rect.maxX
        transform.translateX(by: x, yBy: rect.midY)
        let angle = (edge == .left ? -1.0 : 1.0) * (0.8 + Double(index % 3) * 0.35)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -x, yBy: -rect.midY)
        return transform
    }

    private func cardPath(at index: Int) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: displayCardFrame(at: index), xRadius: Theme.corner, yRadius: Theme.corner)
        path.transform(using: cardTransform(at: index) as AffineTransform)
        return path
    }

    fileprivate func stopAnimations() {
        displayLink?.invalidate(); displayLink = nil
        deckTransition = nil
        resetHover()
    }

    private func resetHover() {
        hoverTransitions.removeAll()
        lifts.removeAll()
        hoveredIndex = nil
        visualHoveredIndex = nil
    }

    private func setHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        visualHoveredIndex = index
        let now = CACurrentMediaTime()
        for card in visibleNotes.indices {
            let target: CGFloat = card == index ? 1 : 0
            let current = hoverTransitions[card]?.value(at: now) ?? liftProgress(at: card)
            lifts[card] = current
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                lifts[card] = target
                hoverTransitions[card] = nil
            } else if hoverTransitions[card]?.to != target {
                hoverTransitions[card] = current == target ? nil : DockTransition(from: current, to: target, began: now, duration: Theme.Motion.hover)
            }
        }
        needsDisplay = true
        if !hoverTransitions.isEmpty { startDisplayLink() }
    }

    private func cardIndex(at point: NSPoint) -> Int? {
        guard isExpanded else { return nil }
        let atEdge = edge == .left ? point.x <= Self.tabWidth : point.x >= bounds.width - Self.tabWidth
        if atEdge {
            for index in visibleNotes.indices {
                let frame = cardFrame(at: index)
                if point.y <= frame.maxY && point.y > frame.maxY - Self.cardOverlap { return index }
            }
        }
        // The lifted sheet owns its whole visible body. Testing the old slots
        // first would switch to a covered neighbour as the pointer moved down.
        if let index = visualHoveredIndex, visibleNotes.indices.contains(index), cardPath(at: index).contains(point) { return index }
        for index in visibleNotes.indices.reversed() where cardPath(at: index).contains(point) { return index }
        return nil
    }

    private func targetIndex(at point: NSPoint) -> Int? {
        guard let source = dragIndex, visibleNotes.indices.contains(source) else { return nil }
        // Reorder by the exposed title strips, not the midpoint of a full sheet.
        let target = visibleNotes.indices.min {
            abs(point.y - (cardFrame(at: $0).maxY - Self.cardOverlap / 2)) <
            abs(point.y - (cardFrame(at: $1).maxY - Self.cardOverlap / 2))
        }
        return target == source ? nil : target
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
        let x = edge == .left ? 10 : bounds.width - 20
        return NSRect(x: x, y: anchorY - 20, width: 10, height: 40).contains(point)
    }

    fileprivate func actionFrame(for kind: DockAccessibilityAction.Kind) -> NSRect {
        switch kind {
        case .create:
            return plusFrame
        case .note(let id):
            guard let index = visibleNotes.firstIndex(where: { $0.id == id }) else { return .zero }
            return cardFrame(at: index)
        case .grip:
            return NSRect(x: edge == .left ? 8 : bounds.width - 24, y: anchorY - 24, width: 16, height: 48)
        }
    }

    fileprivate func accessibleOpen(_ id: String) {
        guard let index = visibleNotes.firstIndex(where: { $0.id == id }) else { return }
        let note = visibleNotes[index]
        let point = window?.convertPoint(toScreen: cardFrame(at: index).origin) ?? .zero
        controller?.didClick(note: note, at: point)
    }
}
