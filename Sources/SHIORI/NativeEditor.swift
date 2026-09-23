import AppKit
import SwiftUI
import QuartzCore

/// A native NSTextView bridge for a note body. The binding is updated from the
/// text view delegate; updateNSView only applies an external value when it is
/// actually different, so normal caret, selection, undo, and IME state stay
/// owned by NSTextView.
public struct NativeEditor: NSViewRepresentable {
    public typealias NSViewType = NSScrollView

    @Binding public var text: String
    private let focusBinding: Binding<Bool>?
    private let bodyFont: NSFont?
    private let focusToken: Int?
    private var onReady: ((ChecklistTextView) -> Void)?
    private let onTextChange: ((String) -> Void)?

    public init(
        text: Binding<String>,
        focus: Binding<Bool>? = nil,
        focusToken: Int? = nil,
        onTextChange: ((String) -> Void)? = nil,
        bodyFont: NSFont? = nil
    ) {
        _text = text
        focusBinding = focus
        self.focusToken = focusToken
        self.onTextChange = onTextChange
        self.bodyFont = bodyFont
    }

    func connecting(_ onReady: @escaping (ChecklistTextView) -> Void) -> Self {
        var copy = self
        copy.onReady = onReady
        return copy
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = ChecklistTextView(frame: .zero)
        let bodyFont = bodyFont ?? Theme.bodyFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 4
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = bodyFont
        textView.defaultParagraphStyle = paragraphStyle
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
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
        textView.textContainerInset = NSSize(width: 30, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [
            .font: bodyFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.84),
            .paragraphStyle: paragraphStyle
        ]
        textView.setBodyFont(bodyFont)
        textView.refreshChecklistAppearance()

        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.documentView = textView
        DispatchQueue.main.async { onReady?(textView) }
        context.coordinator.view = textView
        context.coordinator.lastText = text
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? ChecklistTextView else { return }
        textView.setBodyFont(bodyFont ?? Theme.bodyFont)
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
            guard let view, !view.isHiddenOrHasHiddenAncestor else { return }
            DispatchQueue.main.async {
                guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
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
public final class ChecklistTextView: NSTextView, @preconcurrency NSLayoutManagerDelegate {
    private var retainedStorage: NSTextStorage?
    private var hiddenSyntax = IndexSet()
    private var listItems: [ChecklistEngine.ListItem] = []
    private var applyingPresentation = false
    private(set) var bodyFont = Theme.bodyFont
    private var pendingBodyFont: NSFont?

    func setBodyFont(_ font: NSFont) {
        pendingBodyFont = font
        guard !hasMarkedText() else { return }
        pendingBodyFont = nil
        guard bodyFont != font else { return }
        let selection = selectedRanges
        let origin = enclosingScrollView?.contentView.bounds.origin
        bodyFont = font
        refreshChecklistAppearance()
        selectedRanges = selection
        if let scroll = enclosingScrollView, let origin {
            if let textContainer { layoutManager?.ensureLayout(for: textContainer) }
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        // Checkbox drawing and source-index glyph hiding share one TextKit 1 layout manager.
        let textContainer: NSTextContainer
        if let container { textContainer = container }
        else {
            let storage = NSTextStorage()
            retainedStorage = storage
            let layout = NSLayoutManager()
            textContainer = NSTextContainer(containerSize: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(textContainer)
        }
        super.init(frame: frameRect, textContainer: textContainer)
        layoutManager?.backgroundLayoutEnabled = false
        layoutManager?.delegate = self
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        layoutManager?.backgroundLayoutEnabled = false
        layoutManager?.delegate = self
    }

    public func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !hasMarkedText(), !hiddenSyntax.isEmpty else { return 0 }
        var adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for index in adjusted.indices where hiddenSyntax.contains(characterIndexes[index]) { adjusted[index].insert(.null) }
        layoutManager.setGlyphs(glyphs, properties: &adjusted, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    private var cachedTasks: [ChecklistEngine.Task] = []

    private struct CheckboxHit {
        let task: ChecklistEngine.Task
        let rect: NSRect
    }

    override public var acceptsFirstResponder: Bool { true }

    override public func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        drawCheckboxes(in: dirtyRect)
        drawBullets()
    }

    override public func didChangeText() {
        super.didChangeText()
        if !hasMarkedText() {
            if let pendingBodyFont { setBodyFont(pendingBodyFont) }
            refreshChecklistAppearance()
        }
    }

    override public func unmarkText() {
        super.unmarkText()
        if let pendingBodyFont { setBodyFont(pendingBodyFont) }
        refreshChecklistAppearance()
    }

    override public func accessibilityChildren() -> [Any]? {
        checkboxHits().map { ChecklistAccessibilityElement(owner: self, task: $0.task, rect: $0.rect) }
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let format = ["b": MarkdownFormat.bold, "i": .italic, "k": .link][event.charactersIgnoringModifiers ?? ""] {
            formatText(format)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func formatText(_ format: MarkdownFormat) {
        guard isEditable, !hasMarkedText(), let edit = MarkdownFormattingEngine.edit(format, text: string, selection: selectedRange()) else { return }
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        apply(edit)
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
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
        if let hit = checkboxHits().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }),
           let edit = ChecklistEngine.toggleTask(intersecting: hit.task.lineRange, in: string) {
            apply(edit)
            animateCheckbox(at: hit.rect)
            return
        }
        super.mouseDown(with: event)
    }

    override public func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), let edit = ChecklistEngine.indentEdit(in: string, selection: selectedRange(), outdent: false) else { super.insertTab(sender); return }
        apply(edit)
    }

    override public func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText(), let edit = ChecklistEngine.indentEdit(in: string, selection: selectedRange(), outdent: true) else { super.insertBacktab(sender); return }
        apply(edit)
    }

    override public func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), let edit = ChecklistEngine.removeListMarker(in: string, selection: selectedRange()) else { super.deleteBackward(sender); return }
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
        guard !applyingPresentation, !hasMarkedText(), let layoutManager, let textStorage else { return }
        applyingPresentation = true
        defer { applyingPresentation = false }
        cachedTasks = ChecklistEngine.tasks(in: string)
        let paragraph = defaultParagraphStyle ?? NSParagraphStyle.default
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.black.withAlphaComponent(0.84), .paragraphStyle: paragraph]
        let presentation = MarkdownPresentation(source: string, baseAttributes: base)
        hiddenSyntax = presentation.hidden
        listItems = presentation.listItems
        let all = NSRange(location: 0, length: textStorage.length)
        // Only presentation attributes change here: no source replacements, binding writes or undo entries.
        textStorage.beginEditing()
        presentation.text.enumerateAttributes(in: all) { attributes, range, _ in
            textStorage.setAttributes(attributes, range: range)
        }
        textStorage.endEditing()
        typingAttributes = base
        layoutManager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        needsDisplay = true
    }

    private func drawBullets() {
        guard let layoutManager, !string.isEmpty else { return }
        NSColor.black.withAlphaComponent(0.7).setFill()
        for item in listItems where !item.isChecklist {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(item.contentRange.location, string.utf16.count - 1))
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = textContainerOrigin.x + line.minX + (item.indentation as NSString).size(withAttributes: [.font: bodyFont]).width
            let y = textContainerOrigin.y + line.midY
            if Int(item.marker.dropLast()) != nil {
                let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.black.withAlphaComponent(0.7)]
                let label = item.marker as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: x - size.width - 7, y: y - size.height / 2), withAttributes: attributes)
            } else {
                NSBezierPath(ovalIn: NSRect(x: x - 17, y: y - 2, width: 4, height: 4)).fill()
            }
        }
    }

    private func animateCheckbox(at rect: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        wantsLayer = true
        let pulse = CAShapeLayer()
        pulse.path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        pulse.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        pulse.opacity = 0
        layer?.addSublayer(pulse)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak pulse] in pulse?.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = Theme.Motion.checklist
        pulse.add(fade, forKey: "check")
        CATransaction.commit()
    }

    private func drawCheckboxes(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        let hits = checkboxHits(layoutManager: layoutManager, textContainer: textContainer)
        for hit in hits where hit.rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: hit.rect, xRadius: 3.5, yRadius: 3.5)
            (hit.task.isChecked ? NSColor.black.withAlphaComponent(0.7) : NSColor.black.withAlphaComponent(0.55)).setStroke()
            if hit.task.isChecked { NSColor.black.withAlphaComponent(0.06).setFill(); path.fill() }
            path.lineWidth = 1.1
            path.stroke()
            if hit.task.isChecked {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: hit.rect.minX + 3, y: hit.rect.midY))
                check.line(to: NSPoint(x: hit.rect.midX - 1, y: hit.rect.maxY - 3))
                check.line(to: NSPoint(x: hit.rect.maxX - 2.5, y: hit.rect.minY + 3))
                check.lineCapStyle = .round; check.lineJoinStyle = .round
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
                forCharacterRange: NSRange(location: min(task.contentRange.location, length - 1), length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0, glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let glyphIndex = glyphRange.location
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let lineRect = rect.offsetBy(dx: origin.x, dy: origin.y)
            let size = min(17, max(13, bodyFont.pointSize * 0.75))
            let baseline = lineRect.minY + layoutManager.location(forGlyphAt: glyphIndex).y
            let center = baseline - bodyFont.xHeight / 2
            let checkbox = NSRect(x: lineRect.minX + (task.indentation as NSString).size(withAttributes: [.font: bodyFont]).width - 22, y: center - size / 2, width: size, height: size)
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
