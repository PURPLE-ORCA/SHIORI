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

    /// One source-based list model drives Return, indentation and visible list markers.
    struct ListItem {
        let lineRange: NSRange
        let markerRange: NSRange
        let contentRange: NSRange
        let indentation: String
        let marker: String
        let nextPrefix: String
        let isChecklist: Bool
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|[0-9]{1,9}[.)])[ \t]+(.*)$"#)

    static func listItems(in text: String) -> [ListItem] {
        activeLines(in: text).compactMap { line in
            if let task = parseTask(in: line) {
                return ListItem(lineRange: task.lineRange, markerRange: task.markerRange, contentRange: task.contentRange,
                    indentation: task.indentation, marker: String(task.bullet), nextPrefix: "\(task.indentation)\(task.bullet) [ ] ", isChecklist: true)
            }
            let source = line.text as NSString
            guard let match = listPattern.firstMatch(in: line.text, range: NSRange(location: 0, length: source.length)) else { return nil }
            let indentation = source.substring(with: match.range(at: 1))
            let marker = source.substring(with: match.range(at: 2))
            let nextMarker = Int(marker.dropLast()).map { "\($0 + 1)\(marker.suffix(1))" } ?? marker
            let markerRange = match.range(at: 2)
            let contentRange = match.range(at: 3)
            return ListItem(lineRange: line.bodyRange,
                markerRange: NSRange(location: line.bodyRange.location + markerRange.location, length: markerRange.length),
                contentRange: NSRange(location: line.bodyRange.location + contentRange.location, length: contentRange.length),
                indentation: indentation, marker: marker, nextPrefix: indentation + nextMarker + " ", isChecklist: false)
        }
    }

    public static func tasks(in text: String) -> [Task] { activeLines(in: text).compactMap(parseTask) }

    private static func activeLines(in text: String) -> [Line] {
        var fence: (marker: UInt16, length: Int)?
        return lines(in: text).filter { line in
            if let fenceLine = fenceMarker(in: line.text) {
                if let open = fence {
                    if fenceLine.marker == open.marker, fenceLine.length >= open.length, fenceLine.trailingWhitespaceOnly { fence = nil }
                } else { fence = (fenceLine.marker, fenceLine.length) }
                return false
            }
            return fence == nil
        }
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

    /// Continue the current list, resetting checked tasks and incrementing numbered items.
    /// Return on an empty item outdents one level, or leaves the list at the root.
    public static func returnEdit(in text: String, selection: NSRange) -> TextEdit? {
        guard Range(selection, in: text) != nil,
              let item = listItems(in: text).first(where: {
                  selection.location >= $0.contentRange.location && NSMaxRange(selection) <= NSMaxRange($0.lineRange)
              }) else { return nil }
        let source = text as NSString
        if source.substring(with: item.contentRange).trimmingCharacters(in: .whitespaces).isEmpty {
            if !item.indentation.isEmpty { return indentEdit(in: text, selection: selection, outdent: true) }
            return TextEdit(range: item.lineRange, replacement: "", selectionAfter: NSRange(location: item.lineRange.location, length: 0))
        }
        let replacement = "\n" + item.nextPrefix
        return TextEdit(range: selection, replacement: replacement,
            selectionAfter: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    static func indentEdit(in text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        guard selection.length == 0, let item = listItems(in: text).first(where: {
            selection.location >= $0.lineRange.location && selection.location <= NSMaxRange($0.lineRange)
        }) else { return nil }
        let removed = outdent ? (item.indentation.hasPrefix("\t") ? 1 : min(2, item.indentation.utf16.count)) : 0
        let replacement = outdent ? "" : "  "
        return TextEdit(range: NSRange(location: item.lineRange.location, length: removed), replacement: replacement,
            selectionAfter: NSRange(location: max(item.lineRange.location, selection.location + replacement.utf16.count - removed), length: 0))
    }

    static func removeListMarker(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let item = listItems(in: text).first(where: { $0.contentRange.location == selection.location }) else { return nil }
        return TextEdit(range: NSRange(location: item.markerRange.location, length: item.contentRange.location - item.markerRange.location),
            replacement: "", selectionAfter: NSRange(location: item.markerRange.location, length: 0))
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
              units[offset] == 0x2D || units[offset] == 0x2A || units[offset] == 0x2B,
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
            bullet: Character(UnicodeScalar(units[offset])!),
            isChecked: stateUnit == 0x78 || stateUnit == 0x58,
            content: content
        )
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

}
