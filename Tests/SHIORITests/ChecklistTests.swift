import XCTest
import AppKit
@testable import SHIORI

final class ChecklistTests: XCTestCase {
    func testRecognizesUnicodeTasksAndSkipsFencedCode() {
        let text = "- [ ] Café 😀\n```markdown\n- [ ] inside code\n```\n\t* [x] مرحباً"

        let tasks = ChecklistEngine.tasks(in: text)

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].content, "Café 😀")
        XCTAssertFalse(tasks[0].isChecked)
        XCTAssertEqual(tasks[1].content, "مرحباً")
        XCTAssertTrue(tasks[1].isChecked)
    }

    func testToggleChangesOnlyTheSelectedMarkerAndPreservesText() throws {
        let text = "- [ ] Déjeuner\n- [x] قهوة"
        let location = (text as NSString).range(of: "Déjeuner").location

        let edit = try XCTUnwrap(ChecklistEngine.toggleTask(atUTF16Location: location, in: text))
        XCTAssertEqual(edit.applying(to: text), "- [x] Déjeuner\n- [x] قهوة")
    }

    func testListContinuationPreservesMarkersIndentationAndFencedCode() throws {
        for (text, next) in [("- Café 😀", "- "), ("* one", "* "), ("+ one", "+ "), ("9. مرحباً", "10. "), ("  - [x] done", "  - [ ] ")] {
            let edit = try XCTUnwrap(ChecklistEngine.returnEdit(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
            XCTAssertEqual(edit.applying(to: text), text + "\n" + next)
        }
        let fenced = "```\n- literal\n```"
        let caret = (fenced as NSString).range(of: "literal").upperBound
        XCTAssertNil(ChecklistEngine.returnEdit(in: fenced, selection: NSRange(location: caret, length: 0)))
        XCTAssertNil(ChecklistEngine.indentEdit(in: "plain", selection: NSRange(location: 5, length: 0), outdent: false))
    }

    func testReturnContinuesNonEmptyTaskAndExitsEmptyTask() throws {
        let continuing = "- [ ] First task"
        let continuation = try XCTUnwrap(ChecklistEngine.returnEdit(in: continuing, selection: NSRange(location: continuing.utf16.count, length: 0)))
        XCTAssertEqual(continuation.applying(to: continuing), "- [ ] First task\n- [ ] ")

        let empty = "  * [ ] "
        let exit = try XCTUnwrap(ChecklistEngine.returnEdit(in: empty, selection: NSRange(location: empty.utf16.count, length: 0)))
        XCTAssertEqual(exit.applying(to: empty), "* [ ] ")
    }

    func testCompleteAllLeavesCheckedAndCodeUntouched() {
        let text = "- [ ] One\n- [x] Two\n~~~swift\n- [ ] source\n~~~"

        XCTAssertEqual(
            ChecklistEngine.completeAll(text: text),
            "- [x] One\n- [x] Two\n~~~swift\n- [ ] source\n~~~"
        )
    }

    @MainActor
    func testMarkdownRendersWithoutChangingSourceOrUndoHistory() throws {
        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 340))
        let source = "# Heading\n**Café 😀** _italic_ ~~strike~~ `code`\n[link](https://example.com)\n- [ ] Do this\n- [x] مرحباً\n- bullet\n\n```\n**literal**\n```"
        editor.isRichText = false; editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 30, height: 10)
        editor.string = source
        editor.didChangeText()
        let container = try XCTUnwrap(editor.textContainer)
        container.containerSize = NSSize(width: 360, height: 340)
        let layout = try XCTUnwrap(editor.layoutManager)
        layout.ensureLayout(for: container)
        let storage = try XCTUnwrap(editor.textStorage)
        let boldRange = (source as NSString).range(of: "Café 😀")
        let font = try XCTUnwrap(storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let italicRange = (source as NSString).range(of: "italic")
        let italic = try XCTUnwrap(storage.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        let heading = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, Theme.bodyFont.pointSize)
        let marker = layout.glyphIndexForCharacter(at: boldRange.location - 2)
        XCTAssertTrue(layout.propertyForGlyph(at: marker).contains(.null))
        let literal = (source as NSString).range(of: "**literal**")
        XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: literal.location)).contains(.null))
        XCTAssertEqual(editor.accessibilityChildren()?.count, 2)
        XCTAssertEqual(editor.string, source)
        XCTAssertFalse(editor.undoManager?.canUndo ?? false)
        editor.backgroundColor = Theme.nsColor(0)
        for face in NoteBodyFont.allCases {
            editor.setBodyFont(face.resolve(size: 18))
            layout.ensureLayout(for: container)
            let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            let image = NSImage(size: editor.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Native Markdown rendering - " + face.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testTrailingSpacesLayOutImmediatelyAndReturnKeepsUnicodeSafe() throws {
        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        editor.isRichText = false; editor.allowsUndo = true
        for prefix in ["Café", "مرحبا 😀", "**bold**", "- item", "- [ ] task"] {
            editor.string = prefix
            editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            editor.insertText(" ", replacementRange: editor.selectedRange())
            let layout = try XCTUnwrap(editor.layoutManager)
            layout.ensureLayout(for: editor.textContainer!)
            let glyph = layout.glyphIndexForCharacter(at: editor.string.utf16.count - 1)
            XCTAssertFalse(layout.propertyForGlyph(at: glyph).contains(.null), prefix)
            XCTAssertEqual(editor.string, prefix + " ")
            editor.insertNewline(nil)
            XCTAssertTrue(editor.string.contains(prefix + " \n"))
        }
    }

    @MainActor
    func testMarkdownSourceCoordinatesRejectInvalidBoundsWithoutTrapping() throws {
        let source = "**Café 😀**\r\nمرحبا\rnext"
        let map = MarkdownPresentation.SourceMap(source)
        let valid = AttributedString.MarkdownSourcePosition(startLine: 1, startColumn: 3, endLine: 1, endColumn: 12)
        XCTAssertEqual(map.range(valid), (source as NSString).range(of: "Café 😀"))
        for position in [
            AttributedString.MarkdownSourcePosition(startLine: 0, startColumn: 1, endLine: 1, endColumn: 1),
            .init(startLine: 1, startColumn: 1, endLine: 99, endColumn: 1),
            .init(startLine: 1, startColumn: 1, endLine: 1, endColumn: Int.max),
            .init(startLine: 1, startColumn: 7, endLine: 1, endColumn: 12)
        ] { XCTAssertNil(map.range(position)) }
        for text in [source, "😀\n", "\n\n", "**e\u{301}**\n", "- [ ] مرحبا\n\n", "a  \nb\n", "```\n😀\n```\n"] {
            let presentation = MarkdownPresentation(source: text, baseAttributes: [.font: Theme.bodyFont])
            XCTAssertEqual(presentation.text.string, text)
            XCTAssertTrue(presentation.hidden.allSatisfy { $0 < text.utf16.count })
        }
    }

    @MainActor
    func testTypingListsContinuesVisibleEmptyItemsAndSupportsUndo() throws {
        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = editor
        editor.isRichText = false; editor.allowsUndo = true
        defer { window.orderOut(nil) }
        for (prefix, next) in [("- ", "- "), ("* ", "* "), ("1. ", "2. "), ("- [ ] ", "- [ ] "), ("- [x] ", "- [ ] ")] {
            editor.string = ""
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText(prefix, replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, prefix)
            editor.insertText("Café 😀", replacementRange: editor.selectedRange())
            let original = editor.string
            editor.breakUndoCoalescing(); editor.undoManager?.removeAllActions()
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(editor.string, original + "\n" + next)
            XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
            let layout = try XCTUnwrap(editor.layoutManager)
            layout.ensureLayout(for: editor.textContainer!)
            let lastGlyph = layout.glyphIndexForCharacter(at: editor.string.utf16.count - 1)
            XCTAssertFalse(layout.propertyForGlyph(at: lastGlyph).contains(.null))
            editor.undoManager?.undo()
            XCTAssertEqual(editor.string, original)
            editor.undoManager?.redo()
            XCTAssertEqual(editor.string, original + "\n" + next)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewline(nil)
            XCTAssertEqual(editor.string, original + "\n")
        }
        editor.string = "- first"; editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  - first")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, "- first")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "first")
    }

    @MainActor
    func testNativeCheckboxPressUsesUndo() throws {
        let editor = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        editor.string = "- [ ] Task"
        editor.didChangeText()
        editor.isEditable = true
        editor.allowsUndo = true
        editor.textContainer?.containerSize = NSSize(width: 320, height: 120)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.contentView = editor

        let checkbox = try XCTUnwrap(editor.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertTrue(checkbox.accessibilityPerformPress())
        XCTAssertEqual(editor.string, "- [x] Task")

        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "- [ ] Task")
        window.orderOut(nil)
    }
}
