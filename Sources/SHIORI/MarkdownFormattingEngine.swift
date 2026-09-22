import Foundation

enum MarkdownFormat: String, CaseIterable {
    case bold = "Bold", italic = "Italic", strike = "Strikethrough", code = "Inline Code"
    case link = "Link", h1 = "Heading 1", h2 = "Heading 2", bullet = "Bullet List", checklist = "Checklist"
}

enum MarkdownFormattingEngine {
    static func edit(_ format: MarkdownFormat, text: String, selection: NSRange) -> ChecklistEngine.TextEdit? {
        guard Range(selection, in: text) != nil else { return nil }
        let source = text as NSString
        let selected = source.substring(with: selection)
        switch format {
        case .bold, .italic, .strike, .code:
            let marker = format == .bold ? "**" : format == .italic ? "_" : format == .strike ? "~~" : "`"
            let count = marker.utf16.count
            if selection.location >= count, NSMaxRange(selection) + count <= source.length,
               source.substring(with: NSRange(location: selection.location - count, length: count)) == marker,
               source.substring(with: NSRange(location: NSMaxRange(selection), length: count)) == marker {
                return .init(range: NSRange(location: selection.location - count, length: selection.length + count * 2), replacement: selected, selectionAfter: NSRange(location: selection.location - count, length: selection.length))
            }
            if selected.hasPrefix(marker), selected.hasSuffix(marker), selection.length >= count * 2 {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                return .init(range: selection, replacement: inner, selectionAfter: NSRange(location: selection.location, length: inner.utf16.count))
            }
            return .init(range: selection, replacement: marker + selected + marker, selectionAfter: NSRange(location: selection.location + count, length: selection.length))
        case .link:
            let regex = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(([^)\n]*)\)"#)
            if let match = regex.matches(in: text, range: NSRange(location: 0, length: source.length)).first(where: {
                selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
            }) {
                return .init(range: match.range, replacement: source.substring(with: match.range), selectionAfter: match.range(at: 2))
            }
            let replacement = "[\(selected)]()"
            let caret = selection.location + (selected.isEmpty ? 1 : selection.length + 3)
            return .init(range: selection, replacement: replacement, selectionAfter: NSRange(location: caret, length: 0))
        case .h1, .h2, .bullet, .checklist:
            let selectionForLines = NSRange(location: selection.location, length: max(0, selection.length - (selection.length > 0 ? 1 : 0)))
            let range = source.lineRange(for: selectionForLines)
            let original = source.substring(with: range)
            let prefix = format == .h1 ? "# " : format == .h2 ? "## " : format == .bullet ? "- " : "- [ ] "
            var lines = original.components(separatedBy: "\n")
            let count = lines.count - (original.hasSuffix("\n") ? 1 : 0)
            let allPrefixed = lines.prefix(count).allSatisfy { $0.hasPrefix(prefix) && !(format == .bullet && $0.hasPrefix("- [")) }
            for index in 0..<count {
                let line = lines[index]
                if allPrefixed { lines[index] = String(line.dropFirst(prefix.count)); continue }
                let pattern = #"^(#{1,6} |[-*] \[[ xX]\] |[-*] )"#
                lines[index] = prefix + line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            let replacement = lines.joined(separator: "\n")
            let caret = range.location + min(replacement.utf16.count, max(0, selection.location - range.location + replacement.utf16.count - range.length))
            return .init(range: range, replacement: replacement, selectionAfter: selection.length == 0 ? NSRange(location: caret, length: 0) : NSRange(location: range.location, length: replacement.utf16.count))
        }
    }

    static func bulletReturn(text: String, selection: NSRange) -> ChecklistEngine.TextEdit? {
        guard selection.length == 0, Range(selection, in: text) != nil else { return nil }
        let source = text as NSString
        let range = source.lineRange(for: selection)
        let line = source.substring(with: range).trimmingCharacters(in: .newlines)
        guard line.hasPrefix("- "), !line.hasPrefix("- [") else { return nil }
        let empty = line == "- "
        let replacement = empty ? "\n" : "\n- "
        let target = empty ? NSRange(location: range.location, length: 2) : selection
        return .init(range: target, replacement: replacement, selectionAfter: NSRange(location: target.location + replacement.utf16.count, length: 0))
    }
}
