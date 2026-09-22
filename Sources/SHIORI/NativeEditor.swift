import AppKit
import SwiftUI

/// A native NSTextView bridge for a note body. The binding is updated from the
/// text view delegate; updateNSView only applies an external value when it is
/// actually different, so normal caret, selection, undo, and IME state stay
/// owned by NSTextView.
public struct NativeEditor: NSViewRepresentable {
    public typealias NSViewType = NSScrollView

    @Binding public var text: String
    private let focusBinding: Binding<Bool>?
    private let focusToken: Int?
    private let onTextChange: ((String) -> Void)?

    public init(
        text: Binding<String>,
        focus: Binding<Bool>? = nil,
        focusToken: Int? = nil,
        onTextChange: ((String) -> Void)? = nil
    ) {
        _text = text
        focusBinding = focus
        self.focusToken = focusToken
        self.onTextChange = onTextChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = ChecklistTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = NSColor.black.withAlphaComponent(0.84)
        textView.insertionPointColor = NSColor.black.withAlphaComponent(0.84)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.setAccessibilityLabel("Note body")
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 30, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.black.withAlphaComponent(0.84)
        ]
        textView.refreshChecklistAppearance()

        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.documentView = textView
        context.coordinator.view = textView
        context.coordinator.lastText = text
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? ChecklistTextView else { return }
        textView.isEditable = context.environment.isEnabled
        textView.isSelectable = true

        // A parent observation can arrive while NSTextView is composing an
        // IME marked string. Do not replace that text or its marked range.
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            guard textView.shouldChangeText(in: NSRange(location: 0, length: textView.string.utf16.count), replacementString: text) else { return }
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: textView.typingAttributes))
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
        context.coordinator.lastText = text

        if let focusBinding, focusBinding.wrappedValue {
            context.coordinator.focus()
            DispatchQueue.main.async {
                focusBinding.wrappedValue = false
            }
        }
        if let focusToken, focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            context.coordinator.focus()
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var parent: NativeEditor
        fileprivate weak var view: ChecklistTextView?
        fileprivate var lastText = ""
        fileprivate var lastFocusToken: Int?

        fileprivate init(parent: NativeEditor) {
            self.parent = parent
        }

        fileprivate func focus() {
            guard let view else { return }
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            }
        }

        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ChecklistTextView else { return }
            let value = view.string
            lastText = value
            parent.text = value
            parent.onTextChange?(value)
        }

    }
}

/// NSTextView subclass that draws task checkboxes from NSLayoutManager line
/// fragments and routes interactions through ChecklistEngine edits.
public final class ChecklistTextView: NSTextView {
    private var cachedTasks: [ChecklistEngine.Task] = []

    private struct CheckboxHit {
        let task: ChecklistEngine.Task
        let rect: NSRect
    }

    override public var acceptsFirstResponder: Bool { true }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCheckboxes(in: dirtyRect)
    }

    override public func didChangeText() {
        super.didChangeText()
        if !hasMarkedText() {
            refreshChecklistAppearance()
        }
    }

    override public func unmarkText() {
        super.unmarkText()
        refreshChecklistAppearance()
    }

    override public func accessibilityChildren() -> [Any]? {
        checkboxHits().map { ChecklistAccessibilityElement(owner: self, task: $0.task, rect: $0.rect) }
    }

    override public func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        guard !hasMarkedText(), let string = insertString as? String, string.contains(" ") else { return }
        applyBulletTriggerIfNeeded()
    }

    override public func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(),
              let edit = ChecklistEngine.returnEdit(in: string, selection: selectedRange())
        else {
            super.insertNewline(sender)
            return
        }
        apply(edit)
    }

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = checkboxHits().first(where: { $0.rect.contains(point) }),
           let edit = ChecklistEngine.toggleTask(intersecting: hit.task.lineRange, in: string) {
            apply(edit)
            return
        }
        super.mouseDown(with: event)
    }

    private func applyBulletTriggerIfNeeded() {
        guard let edit = ChecklistEngine.bulletTriggerEdit(in: string, selection: selectedRange()) else { return }
        apply(edit)
    }

    private func apply(_ edit: ChecklistEngine.TextEdit) {
        guard isEditable, !hasMarkedText() else { return }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        if let selectionAfter = edit.selectionAfter {
            setSelectedRange(selectionAfter)
        }
    }

    fileprivate func applyAccessibilityEdit(_ edit: ChecklistEngine.TextEdit) {
        apply(edit)
    }

    fileprivate func refreshChecklistAppearance() {
        cachedTasks = ChecklistEngine.tasks(in: string)
        guard let layoutManager, let textStorage else { return }
        let all = NSRange(location: 0, length: textStorage.length)
        if all.length > 0 {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            layoutManager.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: all)
        }
        for task in cachedTasks where task.isChecked && task.contentRange.length > 0 {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.black.withAlphaComponent(0.48),
                forCharacterRange: task.contentRange
            )
            layoutManager.addTemporaryAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: task.contentRange
            )
        }
    }

    private func drawCheckboxes(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        let hits = checkboxHits(layoutManager: layoutManager, textContainer: textContainer)
        for hit in hits where hit.rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: hit.rect, xRadius: 3.5, yRadius: 3.5)
            (hit.task.isChecked ? NSColor.black.withAlphaComponent(0.7) : NSColor.black.withAlphaComponent(0.55)).setStroke()
            path.lineWidth = 1.2
            path.stroke()
            if hit.task.isChecked {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: hit.rect.minX + 3, y: hit.rect.midY))
                check.line(to: NSPoint(x: hit.rect.midX - 1, y: hit.rect.maxY - 3))
                check.line(to: NSPoint(x: hit.rect.maxX - 2.5, y: hit.rect.minY + 3))
                check.lineWidth = 1.4
                NSColor.black.withAlphaComponent(0.8).setStroke()
                check.stroke()
            }
        }
    }

    private func checkboxHits() -> [CheckboxHit] {
        guard let layoutManager, let textContainer else { return [] }
        return checkboxHits(layoutManager: layoutManager, textContainer: textContainer)
    }

    private func checkboxHits(layoutManager: NSLayoutManager, textContainer: NSTextContainer) -> [CheckboxHit] {
        let tasks = cachedTasks
        guard !tasks.isEmpty else { return [] }
        var result: [CheckboxHit] = []
        let origin = textContainerOrigin
        let length = textStorage?.length ?? 0
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        for task in tasks {
            guard task.markerRange.location < length,
                  NSLocationInRange(task.markerRange.location, visibleCharacters) else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: task.markerRange.location, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0, glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let glyphIndex = glyphRange.location
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let lineRect = rect.offsetBy(dx: origin.x, dy: origin.y)
            let checkbox = NSRect(x: origin.x - 22, y: lineRect.minY + max(0, (lineRect.height - 13) / 2), width: 13, height: 13)
            result.append(CheckboxHit(task: task, rect: checkbox))
        }
        return result
    }
}

private final class ChecklistAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    nonisolated(unsafe) weak var owner: ChecklistTextView?
    let task: ChecklistEngine.Task
    let rect: NSRect

    init(owner: ChecklistTextView, task: ChecklistEngine.Task, rect: NSRect) {
        self.owner = owner
        self.task = task
        self.rect = rect
        super.init()
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner
        let rect = rect
        return MainActor.assumeIsolated { () -> NSRect in
            guard let owner, let window = owner.window else { return .zero }
            return window.convertToScreen(owner.convert(rect, to: nil))
        }
    }

    override func accessibilityParent() -> Any? {
        owner
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? {
        task.content.isEmpty ? "Checklist item" : task.content
    }
    override func accessibilityValue() -> Any? {
        NSNumber(value: task.isChecked)
    }
    override func accessibilityPerformPress() -> Bool {
        let owner = owner
        let lineRange = task.lineRange
        return MainActor.assumeIsolated {
            guard let owner,
                  let edit = ChecklistEngine.toggleTask(intersecting: lineRange, in: owner.string)
            else { return false }
            owner.applyAccessibilityEdit(edit)
            return true
        }
    }
}
