import AppKit
import Combine
import LocalAuthentication

@MainActor
protocol NoteAuthenticator: AnyObject {
    func authenticate() async throws -> Bool
    func cancel()
}

@MainActor
final class TouchIDAuthenticator: NoteAuthenticator {
    private var context: LAContext?
    func authenticate() async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        self.context = context
        defer { context.invalidate(); if self.context === context { self.context = nil } }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Reveal your SHIORI notes.")
    }
    func cancel() { context?.invalidate(); context = nil }
}

@MainActor
final class PrivacyLock: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let authenticator: NoteAuthenticator
    private var generation = 0
    var reportUnavailable: ((String) -> Void)?

    init(defaults: UserDefaults, authenticator: NoteAuthenticator = TouchIDAuthenticator()) {
        self.defaults = defaults; self.authenticator = authenticator
        let enabled = defaults.bool(forKey: "privacyEnabled")
        self.enabled = enabled
        isLocked = enabled
    }

    func lock() {
        generation += 1
        authenticator.cancel()
        isAuthenticating = false
        error = nil
        if enabled { isLocked = true }
    }

    func unlock() async -> Bool {
        if !isLocked { return true }
        return await authenticate()
    }

    func setEnabled(_ value: Bool) async {
        guard value != enabled, !isAuthenticating else { return }
        // Enabling verifies usable biometrics; disabling a locked session cannot bypass authentication.
        if value || isLocked { guard await authenticate() else { return } }
        enabled = value
        defaults.set(value, forKey: "privacyEnabled")
        isLocked = false
        error = nil
    }

    private func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true; error = nil
        let token = generation
        defer { if token == generation { isAuthenticating = false } }
        do {
            let success = try await authenticator.authenticate()
            guard token == generation else { return false }
            if success { isLocked = false }
            else { error = "Touch ID did not unlock SHIORI. Try again when you’re ready." }
            return success
        } catch {
            guard token == generation else { return false }
            switch (error as? LAError)?.code {
            case .userCancel, .appCancel, .systemCancel:
                self.error = nil
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                self.error = "Touch ID is unavailable. Check Touch ID in System Settings, then try again."
            default:
                self.error = "SHIORI is still locked. Touch ID could not verify you."
            }
            return false
        }
    }

    func perform(_ action: @escaping @MainActor () -> Void) {
        guard isLocked else { action(); return }
        guard !isAuthenticating else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.unlock(), !self.isLocked { action() }
            else if let error = self.error { self.reportUnavailable?(error) }
        }
    }

    func search(_ query: String, in store: NotesStore) -> [Note] { isLocked ? [] : store.search(query) }
    static func concealed(_ note: Note) -> Note {
        var copy = note
        copy.title = ""; copy.body = ""
        return copy
    }
}

/// Hides the existing editor subtree (including accessibility) without replacing it.
@MainActor
final class PrivateNoteContent: NSView {
    let editor: NSView
    private let cover = NSButton(title: "Unlock SHIORI", target: nil, action: nil)
    var color: NSColor
    var unlock: (() -> Void)?
    private(set) var locked = false
    private weak var previousResponder: NSResponder?

    init(editor: NSView, color: NSColor, unlock: @escaping () -> Void) {
        self.editor = editor; self.color = color; self.unlock = unlock
        super.init(frame: editor.frame)
        editor.autoresizingMask = [.width, .height]
        addSubview(editor)
        cover.target = self; cover.action = #selector(reveal)
        cover.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        cover.imagePosition = .imageAbove
        cover.isBordered = false; cover.isHidden = true
        cover.setAccessibilityLabel("Unlock SHIORI")
        addSubview(cover)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        editor.frame = bounds
        cover.frame = NSRect(x: bounds.midX - 75, y: bounds.midY - 30, width: 150, height: 60)
    }
    func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        if value {
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(nil)
            window?.childWindows?.forEach { $0.orderOut(nil) }
        }
        editor.isHidden = value
        cover.isHidden = !value
        needsLayout = true; layoutSubtreeIfNeeded()
        needsDisplay = true
        displayIfNeeded()
        if !value, let previousResponder, window?.isKeyWindow == true { window?.makeFirstResponder(previousResponder) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if locked {
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.corner, yRadius: Theme.corner).fill()
        }
    }
    override func accessibilityChildren() -> [Any]? { locked ? [cover] : [editor] }
    @objc private func reveal() { unlock?() }
}
