import AppKit

/// Display attributes and hidden syntax use source offsets; the Markdown string never changes.
@MainActor
struct MarkdownPresentation {
    let text: NSAttributedString
    let hidden: IndexSet
    let listItems: [ChecklistEngine.ListItem]

    init(source: String, baseAttributes: [NSAttributedString.Key: Any]) {
        let display = NSMutableAttributedString(string: source, attributes: baseAttributes)
        let nsSource = source as NSString
        var hidden = IndexSet()
        let items = ChecklistEngine.listItems(in: source)
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
}
