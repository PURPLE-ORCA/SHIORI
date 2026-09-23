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
    struct DetachedGroup: Codable, Equatable {
        var id: String = UUID().uuidString
        var displayID: UInt32
        var edge: String
        var anchor: Double
        var noteIDs: [String]
    }
    @Published var detachedGroups: [DetachedGroup] {
        didSet { if let data = try? JSONEncoder().encode(detachedGroups) { defaults.set(data, forKey: "detachedGroups") } }
    }
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
        detachedGroups = defaults.data(forKey: "detachedGroups")
            .flatMap { try? JSONDecoder().decode([DetachedGroup].self, from: $0) }?
            .filter { $0.anchor.isFinite && (0...1).contains($0.anchor) && ["left", "right"].contains($0.edge) } ?? []
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

    func detachedGroup(for id: String) -> DetachedGroup? { detachedGroups.first { $0.noteIDs.contains(id) } }

    func removeFromDetachedGroup(_ id: String) {
        var groups = detachedGroups
        for index in groups.indices { groups[index].noteIDs.removeAll { $0 == id } }
        groups.removeAll { $0.noteIDs.isEmpty }
        if groups != detachedGroups { detachedGroups = groups }
    }

    func dockDetached(_ id: String, at point: NSPoint, displayID: UInt32, screen: NSRect, allowMain: Bool = false) {
        guard screen.height > 0, point.x.isFinite, point.y.isFinite else { return }
        let side = abs(point.x - screen.minX) < abs(point.x - screen.maxX) ? "left" : "right"
        let position = min(1, max(0, (point.y - screen.minY) / screen.height))
        let target = detachedGroups.filter { $0.displayID == displayID && $0.edge == side && $0.noteIDs.contains(where: { $0 != id }) }
            .min { abs($0.anchor - position) < abs($1.anchor - position) }
        removeFromDetachedGroup(id)
        if let target, abs(target.anchor - position) * screen.height < 120,
           let index = detachedGroups.firstIndex(where: { $0.id == target.id }) {
            detachedGroups[index].noteIDs.append(id)
        } else if allowMain, side == edge, abs(anchor - position) * screen.height < 80 {
            return
        } else {
            let occupied = detachedGroups.filter { $0.displayID == displayID && $0.edge == side }.map(\.anchor)
                + (side == edge ? [anchor] : [])
            let step = 120 / screen.height
            var candidates: [Double] = [position]
            for offset in 1...max(1, Int(screen.height / 120) + 1) {
                candidates.append(position + Double(offset) * step)
                candidates.append(position - Double(offset) * step)
            }
            let placement = candidates.first { candidate in
                (0...1).contains(candidate) && occupied.allSatisfy { abs($0 - candidate) * screen.height >= 119 }
            }
            if let placement {
                detachedGroups.append(DetachedGroup(displayID: displayID, edge: side, anchor: placement, noteIDs: [id]))
            } else if let target, let index = detachedGroups.firstIndex(where: { $0.id == target.id }) {
                detachedGroups[index].noteIDs.append(id)
            } else {
                detachedGroups.append(DetachedGroup(displayID: displayID, edge: side, anchor: position, noteIDs: [id]))
            }
        }
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
    static let names = ["Yellow", "Coral", "Mint", "Sky blue", "Lavender", "Pink", "Orange", "Lime", "Turquoise", "Ivory", "Red", "Brown", "Purple", "Blue", "Cyan", "Green", "Olive", "Gold", "Terracotta", "Gray"]
    static let palette: [UInt32] = [0xFED866, 0xFE9D7C, 0xA8E5CF, 0xA9D6FE, 0xD7C6FE, 0xF28CC2, 0xF5AB52, 0xC5DE62, 0x63CEC0, 0xF1E7D2, 0xE97878, 0xBD916F, 0xB88BD9, 0x7DA4E5, 0x6DCDE5, 0x83BB7D, 0xB4B36B, 0xDAB34F, 0xD18C72, 0xB7BDC5]
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
