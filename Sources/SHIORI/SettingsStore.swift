import AppKit
import SwiftUI

enum NoteBodyFont: String, CaseIterable {
    case architectsDaughter = "Architects Daughter", indieFlower = "Indie Flower", kalam = "Kalam", system = "System"

    @MainActor func resolve(size: Double) -> NSFont {
        let name: String
        switch self {
        case .architectsDaughter: name = "ArchitectsDaughter-Regular"
        case .indieFlower: name = "IndieFlower-Regular"
        case .kalam: name = "Kalam-Regular"
        case .system: return NSFont.systemFont(ofSize: size)
        }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    let defaults: UserDefaults
    @Published var edge: String { didSet { defaults.set(edge, forKey: "edge") } }
    @Published var anchor: Double { didSet { defaults.set(anchor, forKey: "anchor") } }
    @Published var openDelay: Double { didSet { defaults.set(openDelay, forKey: "openDelay") } }
    @Published var closeDelay: Double { didSet { defaults.set(closeDelay, forKey: "closeDelay") } }
    @Published var acrossSpaces: Bool { didSet { defaults.set(acrossSpaces, forKey: "acrossSpaces") } }
    @Published var fullscreen: Bool { didSet { defaults.set(fullscreen, forKey: "fullscreen") } }
    @Published var noteFont: NoteBodyFont { didSet {
        defaults.set(noteFont.rawValue, forKey: "noteFont")
        bodyFont = noteFont.resolve(size: noteFontSize)
    } }
    @Published var noteFontSize: Double { didSet {
        let size = Self.validFontSize(noteFontSize)
        if noteFontSize != size { noteFontSize = size; return }
        defaults.set(noteFontSize, forKey: "noteFontSize")
        bodyFont = noteFont.resolve(size: noteFontSize)
    } }
    private(set) var bodyFont: NSFont
    private static func validFontSize(_ size: Double) -> Double { size.isFinite ? min(24, max(14, size)) : 16 }
    var initialized: Bool {
        get { defaults.bool(forKey: "initialized") }
        set { defaults.set(newValue, forKey: "initialized") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["edge": "right", "anchor": 0.5, "openDelay": 0.15, "closeDelay": 0.1, "acrossSpaces": true, "fullscreen": false, "noteFont": NoteBodyFont.architectsDaughter.rawValue, "noteFontSize": 16.0])
        edge = defaults.string(forKey: "edge") == "left" ? "left" : "right"
        anchor = min(1, max(0, defaults.double(forKey: "anchor")))
        openDelay = max(0, defaults.double(forKey: "openDelay"))
        closeDelay = max(0, defaults.double(forKey: "closeDelay"))
        acrossSpaces = defaults.bool(forKey: "acrossSpaces")
        fullscreen = defaults.bool(forKey: "fullscreen")
        let selectedFont = NoteBodyFont(rawValue: defaults.string(forKey: "noteFont") ?? "") ?? .architectsDaughter
        let selectedSize = Self.validFontSize(defaults.double(forKey: "noteFontSize"))
        noteFont = selectedFont
        noteFontSize = selectedSize
        bodyFont = selectedFont.resolve(size: selectedSize)
    }
    var collectionBehavior: NSWindow.CollectionBehavior {
        var result: NSWindow.CollectionBehavior = [.ignoresCycle]
        if acrossSpaces { result.insert(.canJoinAllSpaces) }
        if fullscreen { result.insert(.fullScreenAuxiliary) } else { result.insert(.fullScreenNone) }
        return result
    }
    func saveFrame(_ frame: NSRect, id: String, display: String?) {
        defaults.set(["frame": NSStringFromRect(frame), "display": display ?? ""], forKey: "window.\(id)")
    }
    func frame(id: String) -> NSRect? {
        guard let value = defaults.dictionary(forKey: "window.\(id)")?["frame"] as? String else { return nil }
        return NSRectFromString(value)
    }
    func resetPositions() {
        anchor = 0.5
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("window.") { defaults.removeObject(forKey: key) }
    }
}

enum WindowGeometry {
    static func clamp(_ frame: NSRect, to screens: [NSRect]) -> NSRect {
        guard let screen = screens.max(by: { area(frame.intersection($0)) < area(frame.intersection($1)) }) else { return frame }
        let width = min(max(frame.width, 280), screen.width)
        let height = min(max(frame.height, 260), screen.height)
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

enum Theme {
    static let names = ["Yellow", "Coral", "Mint", "Sky blue", "Lavender", "Rose", "Peach", "Lime", "Aqua", "Ivory", "Apricot", "Blush", "Lilac", "Periwinkle", "Ice blue", "Seafoam", "Sage", "Butter", "Sand", "Pearl"]
    static let palette: [UInt32] = [0xFED866, 0xFE9D7C, 0xA8E5CF, 0xA9D6FE, 0xD7C6FE, 0xF5B8CF, 0xFFD0A6, 0xD5E99C, 0xA5E3E5, 0xF1E7D2, 0xF7B98B, 0xF7D0D8, 0xE8BFE8, 0xBEC8F5, 0xC6E8F5, 0xBDE8DC, 0xC4D8B5, 0xF4E7A2, 0xDDC8AC, 0xE4E4EB]
    static func nsColor(_ index: Int) -> NSColor {
        let hex = palette[min(palette.count - 1, max(0, index))]
        return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }
    static func roundedFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
    static var bodyFont: NSFont { roundedFont(size: 16) }
    enum Motion {
        static let deckOpen = 0.28
        static let deckClose = 0.24
        static let hover = 0.12
        static let deckStagger = 0.03
        static func deckProgress(_ progress: CGFloat, index: Int, count: Int) -> CGFloat {
            let span = deckOpen - Double(max(0, count - 1)) * deckStagger
            let t = min(1, max(0, (progress * deckOpen - Double(index) * deckStagger) / span))
            return 1 - pow(1 - t, 3)
        }
        static let editorOpen = 0.18
        static let editorClose = 0.17
        static let create = 0.18
        static let checklist = 0.16
        static func duration(_ duration: Double, reduceMotion: Bool) -> Double { reduceMotion ? 0.12 : duration }
        // Normalized critically damped response: physical settling without overshoot.
        static func progress(_ t: Double) -> Double {
            let t = min(1, max(0, t)), k = 7.0
            return (1 - (1 + k * t) * exp(-k * t)) / (1 - (1 + k) * exp(-k))
        }
    }
    static let corner: CGFloat = 16
    static let editorSize = NSSize(width: 360, height: 400)
}
