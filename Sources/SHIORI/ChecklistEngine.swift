import Foundation

/// The small Markdown subset used by the editor.
///
/// The task marker in the note body is the source of truth.  The editor uses
/// the ranges returned here for drawing and for applying native text edits;
/// no checkbox state is stored separately.
public enum ChecklistEngine {
    public struct Task: Equatable {
        /// The line body, excluding its line ending, in UTF-16 offsets.
        public let lineRange: NSRange
        /// The complete line, including its line ending when one exists.
        public let fullLineRange: NSRange
        /// The five-character marker, for example `- [ ]`.
        public let markerRange: NSRange
        /// The single state character between the brackets.
        public let stateRange: NSRange
        /// The range containing the task's visible text.
        public let contentRange: NSRange
        /// The characters before the bullet marker, retained when continuing.
        public let indentation: String
        public let bullet: Character
        public let isChecked: Bool
        public let content: String

        public var isEmpty: Bool {
            content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public init(
            lineRange: NSRange,
            fullLineRange: NSRange,
            markerRange: NSRange,
            stateRange: NSRange,
            contentRange: NSRange,
            indentation: String,
            bullet: Character,
            isChecked: Bool,
            content: String
        ) {
            self.lineRange = lineRange
            self.fullLineRange = fullLineRange
            self.markerRange = markerRange
            self.stateRange = stateRange
            self.contentRange = contentRange
            self.indentation = indentation
            self.bullet = bullet
            self.isChecked = isChecked
            self.content = content
        }
    }

    /// A text replacement that can be applied through NSTextView's normal
    /// `shouldChangeText` / `didChangeText` path, preserving undo history.
    public struct TextEdit: Equatable {
        public let range: NSRange
        public let replacement: String
        public let selectionAfter: NSRange?

        public init(range: NSRange, replacement: String, selectionAfter: NSRange? = nil) {
            self.range = range
            self.replacement = replacement
            self.selectionAfter = selectionAfter
        }

        public func applying(to text: String) -> String {
            guard let stringRange = Range(range, in: text) else { return text }
            return text.replacingCharacters(in: stringRange, with: replacement)
        }
    }

    private struct Line {
        let text: String
        let bodyRange: NSRange
        let fullRange: NSRange
    }

    /// Returns all task lines outside fenced code blocks.
    public static func tasks(in text: String) -> [Task] {
        var result: [Task] = []
        var fence: (marker: UInt16, length: Int)?

        for line in lines(in: text) {
            if let fenceLine = fenceMarker(in: line.text) {
                if let openFence = fence {
                    if fenceLine.marker == openFence.marker,
                       fenceLine.length >= openFence.length,
                       fenceLine.trailingWhitespaceOnly {
                        fence = nil
                    }
                } else {
                    fence = (fenceLine.marker, fenceLine.length)
                }
                continue
            }

            guard fence == nil, let task = parseTask(in: line) else { continue }
            result.append(task)
        }

        return result
    }

    public static func task(atUTF16Location location: Int, in text: String) -> Task? {
        let clampedLocation = max(0, min(location, text.utf16.count))
        return tasks(in: text).first { task in
            clampedLocation >= task.lineRange.location &&
                clampedLocation <= NSMaxRange(task.lineRange)
        }
    }

    /// Finds the task intersecting a selection. A caret at either end of the
    /// line is considered part of that line, matching NSTextView conventions.
    public static func task(intersecting selection: NSRange, in text: String) -> Task? {
        let location = max(0, min(selection.location, text.utf16.count))
        return tasks(in: text).first { task in
            if selection.length == 0 {
                return location >= task.lineRange.location && location <= NSMaxRange(task.lineRange)
            }
            return NSIntersectionRange(task.lineRange, selection).length > 0 ||
                location == NSMaxRange(task.lineRange)
        }
    }

    /// Returns an edit for toggling the task containing a UTF-16 caret/range.
    public static func toggleTask(atUTF16Location location: Int, in text: String) -> TextEdit? {
        guard let task = task(atUTF16Location: location, in: text) else { return nil }
        return toggleEdit(for: task)
    }

    public static func toggleTask(intersecting selection: NSRange, in text: String) -> TextEdit? {
        guard let task = task(intersecting: selection, in: text) else { return nil }
        return toggleEdit(for: task)
    }

    public static func toggleEdit(for task: Task) -> TextEdit {
        TextEdit(
            range: task.stateRange,
            replacement: task.isChecked ? " " : "x"
        )
    }

    /// Recognizes the moment the user types `- ` or `* ` on an otherwise empty
    /// normal line. It intentionally does not rewrite arbitrary pasted text.
    public static func bulletTriggerEdit(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let location = max(0, min(selection.location, text.utf16.count))
        guard let line = line(containingUTF16Location: location, in: text),
              let bullet = bulletTrigger(in: line.text),
              !isInsideFence(line, in: text)
        else { return nil }

        // A trigger is only valid when the caret is immediately after the
        // single space. This excludes a later edit in a title or paragraph.
        guard location == NSMaxRange(line.bodyRange) else { return nil }
        let bulletOffset = line.bodyRange.location + bullet.offset
        let range = NSRange(location: bulletOffset, length: 2)
        let replacement = "\(bullet.character) [ ] "
        let newLocation = location + replacement.utf16.count - range.length
        return TextEdit(
            range: range,
            replacement: replacement,
            selectionAfter: NSRange(location: newLocation, length: 0)
        )
    }

    /// Produces the edit for Return in a task line. A non-empty task continues
    /// the same bullet; an empty task removes its marker and leaves a plain
    /// line, exiting checklist mode.
    public static func returnEdit(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0,
              let task = task(intersecting: selection, in: text)
        else { return nil }

        if task.isEmpty {
            let replacement = task.indentation + "\n"
            let caret = task.lineRange.location + replacement.utf16.count
            return TextEdit(
                range: task.lineRange,
                replacement: replacement,
                selectionAfter: NSRange(location: caret, length: 0)
            )
        }

        let replacement = "\n\(task.indentation)\(task.bullet) [ ] "
        let caret = selection.location + replacement.utf16.count
        return TextEdit(
            range: selection,
            replacement: replacement,
            selectionAfter: NSRange(location: caret, length: 0)
        )
    }

    /// Marks every recognized unfinished task complete, preserving all other
    /// text byte-for-byte and ignoring fenced code blocks.
    public static func completeAll(text: String) -> String {
        let unfinished = tasks(in: text).filter { !$0.isChecked }
        guard !unfinished.isEmpty else { return text }

        var units = Array(text.utf16)
        for task in unfinished where task.stateRange.location < units.count {
            units[task.stateRange.location] = 0x78 // x
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Parsing

    private static func parseTask(in line: Line) -> Task? {
        let units = Array(line.text.utf16)
        var offset = 0
        while offset < units.count, units[offset] == 0x20 || units[offset] == 0x09 {
            offset += 1
        }

        guard offset + 4 < units.count,
              units[offset] == 0x2D || units[offset] == 0x2A,
              units[offset + 1] == 0x20,
              units[offset + 2] == 0x5B,
              units[offset + 4] == 0x5D
        else { return nil }

        let stateUnit = units[offset + 3]
        guard stateUnit == 0x20 || stateUnit == 0x78 || stateUnit == 0x58 else { return nil }

        var contentOffset = offset + 5
        while contentOffset < units.count,
              units[contentOffset] == 0x20 || units[contentOffset] == 0x09 {
            contentOffset += 1
        }

        let indentation = String(decoding: units[0..<offset], as: UTF16.self)
        let content = String(decoding: units[contentOffset..<units.count], as: UTF16.self)
        let markerLocation = line.bodyRange.location + offset
        let contentLocation = line.bodyRange.location + contentOffset

        return Task(
            lineRange: line.bodyRange,
            fullLineRange: line.fullRange,
            markerRange: NSRange(location: markerLocation, length: 5),
            stateRange: NSRange(location: markerLocation + 3, length: 1),
            contentRange: NSRange(location: contentLocation, length: units.count - contentOffset),
            indentation: indentation,
            bullet: units[offset] == 0x2D ? "-" : "*",
            isChecked: stateUnit == 0x78 || stateUnit == 0x58,
            content: content
        )
    }

    private static func bulletTrigger(in line: String) -> (character: Character, offset: Int)? {
        let units = Array(line.utf16)
        var offset = 0
        while offset < units.count, units[offset] == 0x20 || units[offset] == 0x09 {
            offset += 1
        }
        guard units.count == offset + 2,
              units[offset] == 0x2D || units[offset] == 0x2A,
              units[offset + 1] == 0x20
        else { return nil }
        return (units[offset] == 0x2D ? "-" : "*", offset)
    }

    private static func fenceMarker(in line: String) -> (marker: UInt16, length: Int, trailingWhitespaceOnly: Bool)? {
        let units = Array(line.utf16)
        var offset = 0
        while offset < units.count, units[offset] == 0x20 {
            offset += 1
        }
        guard offset <= 3, offset < units.count,
              units[offset] == 0x60 || units[offset] == 0x7E
        else { return nil }

        let marker = units[offset]
        var length = 0
        while offset + length < units.count, units[offset + length] == marker {
            length += 1
        }
        guard length >= 3 else { return nil }
        let trailingWhitespaceOnly = units[(offset + length)...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        return (marker, length, trailingWhitespaceOnly)
    }

    private static func lines(in text: String) -> [Line] {
        let units = Array(text.utf16)
        var starts = [0]
        for index in units.indices where units[index] == 0x0A {
            starts.append(index + 1)
        }

        return starts.compactMap { start in
            guard start <= units.count else { return nil }
            let fullEnd = starts.first(where: { $0 > start }) ?? units.count
            var bodyEnd = fullEnd
            if bodyEnd > start, units[bodyEnd - 1] == 0x0A {
                bodyEnd -= 1
                if bodyEnd > start, units[bodyEnd - 1] == 0x0D {
                    bodyEnd -= 1
                }
            }

            return Line(
                text: String(decoding: units[start..<bodyEnd], as: UTF16.self),
                bodyRange: NSRange(location: start, length: bodyEnd - start),
                fullRange: NSRange(location: start, length: fullEnd - start)
            )
        }
    }

    private static func line(containingUTF16Location location: Int, in text: String) -> Line? {
        let clamped = max(0, min(location, text.utf16.count))
        return lines(in: text).first { line in
            clamped >= line.bodyRange.location && clamped <= NSMaxRange(line.bodyRange)
        }
    }

    private static func isInsideFence(_ target: Line, in text: String) -> Bool {
        var fence: (marker: UInt16, length: Int)?
        for line in lines(in: text) {
            if line.bodyRange == target.bodyRange { return fence != nil }
            guard let fenceLine = fenceMarker(in: line.text) else { continue }
            if let openFence = fence {
                if fenceLine.marker == openFence.marker,
                   fenceLine.length >= openFence.length,
                   fenceLine.trailingWhitespaceOnly {
                    fence = nil
                }
            } else {
                fence = (fenceLine.marker, fenceLine.length)
            }
        }
        return false
    }
}
