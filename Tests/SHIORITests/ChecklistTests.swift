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
