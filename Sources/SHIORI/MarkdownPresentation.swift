import AppKit

/// Display attributes and hidden syntax use source offsets; the Markdown string never changes.
@MainActor
struct MarkdownPresentation {
    let text: NSAttributedString
    let hidden: IndexSet
    let bullets: [Int]

    init(source: String, baseAttributes: [NSAttributedString.Key: Any]) {
        let display = NSMutableAttributedString(string: source, attributes: baseAttributes)
        let nsSource = source as NSString
        var hidden = IndexSet()
        var bullets = Set<Int>()
        let tasks = ChecklistEngine.tasks(in: source)
        let baseFont = baseAttributes[.font] as? NSFont ?? Theme.bodyFont
        if let parsed = try? AttributedString(markdown: source, options: .init(appliesSourcePositionAttributes: true)) {
            hidden = IndexSet(integersIn: 0..<nsSource.length)
            for run in parsed.runs {
                guard let position = run.markdownSourcePosition, let sourceRange = Range(position, in: source) else { continue }
                let range = NSRange(sourceRange, in: source)
                hidden.remove(integersIn: range.location..<NSMaxRange(range))
                let inline = run.inlinePresentationIntent ?? []
                var font = baseFont
                for component in run.presentationIntent?.components ?? [] {
                    switch component.kind {
                    case .header(let level): font = Theme.roundedFont(size: level == 1 ? 24 : 20, weight: .semibold)
                    case .codeBlock: font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                    case .unorderedList:
                        let line = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
                        let prefix = nsSource.substring(with: NSRange(location: line.location, length: range.location - line.location))
                        if prefix.trimmingCharacters(in: .whitespaces) == "-" || prefix.trimmingCharacters(in: .whitespaces) == "*" {
                            if !tasks.contains(where: { $0.lineRange.location == line.location }) { bullets.insert(range.location) }
                        }
                    default: break
                    }
                }
                if inline.contains(.code) { font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular) }
                if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
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
        }
        for task in tasks {
            hidden.insert(integersIn: task.markerRange.location..<task.contentRange.location)
            if task.isChecked {
                display.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.black.withAlphaComponent(0.48)], range: task.contentRange)
            }
        }
        self.text = display
        self.hidden = hidden
        self.bullets = bullets.sorted()
    }
}
