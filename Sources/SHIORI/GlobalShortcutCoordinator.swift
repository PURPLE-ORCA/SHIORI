import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class GlobalShortcutCoordinator: ObservableObject {
    enum Command: String, CaseIterable {
        case newNote, quickSearch, floatingNotes
        var title: String {
            switch self {
            case .newNote: "New Note"
            case .quickSearch: "Quick Search"
            case .floatingNotes: "Hide / Show Notes"
            }
        }
        var defaultShortcut: KeyboardShortcuts.Shortcut {
            switch self {
            case .newNote: .init(.n, modifiers: .option)
            case .quickSearch: .init(.space, modifiers: .option)
            case .floatingNotes: .init(.h, modifiers: [.option, .shift])
            }
        }
    }
    @Published private(set) var errors: [Command: String] = [:]
    let namespace: String
    private let registersHotkeys: Bool
    private let route: (Command) -> Void
    init(namespace: String = "shiori", registersHotkeys: Bool = true, route: @escaping (Command) -> Void) {
        self.namespace = namespace
        self.registersHotkeys = registersHotkeys
        self.route = route
        for command in Command.allCases {
            let name = name(command)
            if registersHotkeys {
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.perform(command) }
                validate(command)
            }
        }
    }
    func perform(_ command: Command) { route(command) }
    func name(_ command: Command) -> KeyboardShortcuts.Name {
        .init("\(namespace).\(command.rawValue)", default: command.defaultShortcut)
    }
    func validate(_ command: Command) {
        guard registersHotkeys else { return }
        let name = name(command)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { errors[command] = nil; return }
        let duplicate = Command.allCases.contains { $0 != command && KeyboardShortcuts.getShortcut(for: self.name($0)) == shortcut }
        if shortcut.isTakenBySystem || duplicate {
            KeyboardShortcuts.disable(name)
            errors[command] = "This shortcut is already in use. Choose another combination."
        } else {
            KeyboardShortcuts.enable(name)
            errors[command] = KeyboardShortcuts.isEnabled(for: name) ? nil : "This shortcut is unavailable. Choose another combination."
        }
    }
    func refresh() { for command in Command.allCases { validate(command) } }
    func reset() {
        KeyboardShortcuts.reset(Command.allCases.map { name($0) })
        refresh()
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: GlobalShortcutCoordinator
    var body: some View {
        Section("Keyboard Shortcuts") {
            ForEach(GlobalShortcutCoordinator.Command.allCases, id: \.rawValue) { command in
                KeyboardShortcuts.Recorder(command.title, name: shortcuts.name(command)) { _ in
                    // The recorder temporarily suspends hotkeys while editing.
                    DispatchQueue.main.async { shortcuts.refresh() }
                }
                if let error = shortcuts.errors[command] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Button("Reset to Defaults") { shortcuts.reset() }
        }
    }
}
