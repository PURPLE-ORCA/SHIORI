import AppKit

/// Display attributes and hidden syntax use source offsets; the Markdown string never changes.
@MainActor
struct MarkdownPresentation {
    let text: NSAttributedString
    let hidden: IndexSet
    let listItems: [ChecklistEngine.ListItem]

    static func preview(_ source: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let result = parsed.map { NSMutableAttributedString(attributedString: NSAttributedString($0)) }
            ?? NSMutableAttributedString(string: source)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttributes(attributes, range: whole)
        result.enumerateAttribute(.link, in: whole) { link, range, _ in
            if link != nil {
                result.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
        }
        return result
    }

    init(source: String, baseAttributes: [NSAttributedString.Key: Any]) {
        let display = NSMutableAttributedString(string: source, attributes: baseAttributes)
        let nsSource = source as NSString
        let sourceMap = SourceMap(source)
        var hidden = IndexSet()
        let items = ChecklistEngine.listItems(in: source)
        let tasks = ChecklistEngine.tasks(in: source)
        let baseFont = baseAttributes[.font] as? NSFont ?? Theme.bodyFont
        if let parsed = try? AttributedString(markdown: source, options: .init(appliesSourcePositionAttributes: true)) {
            hidden = IndexSet(integersIn: 0..<nsSource.length)
            var sourceCursor = 0
            for run in parsed.runs {
                let content = String(parsed[run.range].characters)
                // Synthetic separators have no source position and are preserved below.
                if run.markdownSourcePosition == nil,
                   parsed[run.range].characters.allSatisfy({ $0.isWhitespace }) { continue }
                var sourceRange = run.markdownSourcePosition.flatMap { sourceMap.range($0) }
                if run.link != nil, sourceRange.map({ nsSource.substring(with: $0) != content }) ?? true {
                    // Foundation autolinks can omit or misreport coordinates. Match in source order.
                    let match = nsSource.range(of: content, options: .literal,
                                               range: NSRange(location: sourceCursor, length: nsSource.length - sourceCursor))
                    sourceRange = match.location == NSNotFound ? nil : match
                }
                guard let range = sourceRange else {
                    // Preserve source text if parser coordinates cannot be recovered.
                    self.text = NSAttributedString(string: source, attributes: baseAttributes)
                    self.hidden = []
                    self.listItems = items
                    return
                }
                sourceCursor = min(NSMaxRange(range), range.location + content.utf16.count)
                hidden.remove(integersIn: range.location..<NSMaxRange(range))
                let inline = run.inlinePresentationIntent ?? []
                var font = baseFont
                for component in run.presentationIntent?.components ?? [] {
                    switch component.kind {
                    case .header(let level): font = NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize * (level == 1 ? 1.5 : 1.25))
                    case .codeBlock: font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                    default: break
                    }
                }
                if inline.contains(.code) { font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular) }
                if inline.contains(.stronglyEmphasized) {
                    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    font = NSFontManager.shared.traits(of: bold).contains(.boldFontMask) ? bold : .systemFont(ofSize: font.pointSize, weight: .bold)
                }
                if inline.contains(.emphasized) {
                    // The rounded system face has no italic variant; use its native italic sibling.
                    let italicBase = NSFont.systemFont(ofSize: font.pointSize, weight: inline.contains(.stronglyEmphasized) ? .bold : .regular)
                    font = NSFontManager.shared.convert(italicBase, toHaveTrait: .italicFontMask)
                }
                display.addAttribute(.font, value: font, range: range)
                if inline.contains(.strikethrough) { display.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                if inline.contains(.code) { display.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.06), range: range) }
                if let link = run.link {
                    display.addAttributes([.link: link, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                }
            }
            // Keep every source line, including empty lines and trailing Return.
            for (index, unit) in source.utf16.enumerated() where unit == 10 || unit == 13 { hidden.remove(index) }
            // Markdown omits trailing whitespace; an editor must still lay it out as it is typed.
            let units = Array(source.utf16)
            var trailing = true
            for index in units.indices.reversed() {
                let unit = units[index]
                if unit == 10 || unit == 13 { trailing = true }
                else if trailing, unit == 32 || unit == 9 || unit == 0xA0 { hidden.remove(index) }
                else { trailing = false }
            }
        }
        for item in items {
            hidden.insert(integersIn: item.markerRange.location..<item.contentRange.location)
            hidden.remove(integersIn: item.lineRange.location..<item.markerRange.location)
            // An empty item still needs a laid-out space for its marker and insertion caret.
            if item.contentRange.length == 0, item.contentRange.location > NSMaxRange(item.markerRange) {
                hidden.remove(item.contentRange.location - 1)
            }
            let paragraph = (baseAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
            paragraph.headIndent = (item.indentation as NSString).size(withAttributes: [.font: baseFont]).width
            display.addAttribute(.paragraphStyle, value: paragraph, range: item.lineRange)
        }
        for task in tasks {
            if task.isChecked {
                display.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.black.withAlphaComponent(0.48)], range: task.contentRange)
            }
        }
        self.text = display
        self.hidden = hidden
        self.listItems = items
    }

    /// Parser columns are UTF-8 byte offsets, with an inclusive end. Resolve only
    /// valid scalar boundaries instead of Foundation's trapping Range initializer.
    struct SourceMap {
        private let starts: [Int]
        private let ends: [Int]
        private let utf16Offsets: [Int]

        init(_ source: String) {
            let bytes = Array(source.utf8)
            var starts = [0], ends: [Int] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] == 10 || bytes[index] == 13 {
                    ends.append(index)
                    if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                    starts.append(index + 1)
                }
                index += 1
            }
            ends.append(bytes.count)
            var offsets = Array(repeating: -1, count: bytes.count + 1)
            var byte = 0, utf16 = 0
            offsets[0] = 0
            for scalar in source.unicodeScalars {
                byte += scalar.utf8.count
                utf16 += scalar.utf16.count
                offsets[byte] = utf16
            }
            self.starts = starts; self.ends = ends; self.utf16Offsets = offsets
        }

        func range(_ position: AttributedString.MarkdownSourcePosition) -> NSRange? {
            guard position.startLine > 0, position.endLine >= position.startLine,
                  position.endLine <= starts.count, position.startColumn > 0, position.endColumn > 0 else { return nil }
            let first = position.startLine - 1, last = position.endLine - 1
            guard position.startColumn <= ends[first] - starts[first],
                  position.endColumn <= ends[last] - starts[last] else { return nil }
            let lower = starts[first] + position.startColumn - 1
            let upper = starts[last] + position.endColumn
            guard lower < upper, utf16Offsets[lower] >= 0, utf16Offsets[upper] >= 0 else { return nil }
            return NSRange(location: utf16Offsets[lower], length: utf16Offsets[upper] - utf16Offsets[lower])
        }
    }

}
