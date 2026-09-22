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

    func testBulletTriggerAndFenceGuard() throws {
        let text = "- \n```\n- \n```"
        let firstCaret = (text as NSString).range(of: "- ").location + 2
        let firstEdit = try XCTUnwrap(ChecklistEngine.bulletTriggerEdit(in: text, selection: NSRange(location: firstCaret, length: 0)))
        XCTAssertEqual(firstEdit.applying(to: text), "- [ ] \n```\n- \n```")

        let fencedCaret = (text as NSString).range(of: "- ", options: [], range: NSRange(location: firstCaret + 1, length: text.utf16.count - firstCaret - 1)).location + 2
        XCTAssertNil(ChecklistEngine.bulletTriggerEdit(in: text, selection: NSRange(location: fencedCaret, length: 0)))
    }

    func testReturnContinuesNonEmptyTaskAndExitsEmptyTask() throws {
        let continuing = "- [ ] First task"
        let continuation = try XCTUnwrap(ChecklistEngine.returnEdit(in: continuing, selection: NSRange(location: continuing.utf16.count, length: 0)))
        XCTAssertEqual(continuation.applying(to: continuing), "- [ ] First task\n- [ ] ")

        let empty = "  * [ ] "
        let exit = try XCTUnwrap(ChecklistEngine.returnEdit(in: empty, selection: NSRange(location: empty.utf16.count, length: 0)))
        XCTAssertEqual(exit.applying(to: empty), "  \n")
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
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let image = NSImage(size: editor.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Native Markdown rendering"
        attachment.lifetime = .keepAlways
        add(attachment)
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
