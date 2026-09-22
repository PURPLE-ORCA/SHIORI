import AppKit
import SwiftUI

@MainActor
final class QuickSearchController: NSObject, NSWindowDelegate {
    private var panel: SearchPanel?
    let settings: SettingsStore
    let store: NotesStore
    let open: (String) -> Void
    let create: () -> Void
    init(store: NotesStore, settings: SettingsStore, open: @escaping (String) -> Void, create: @escaping () -> Void) {
        self.store = store; self.settings = settings; self.open = open; self.create = create
    }
    func show() {
        dismiss()
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.collectionBehavior = settings.collectionBehavior
        panel.contentView = NSHostingView(rootView: QuickSearchView(store: store, open: { [weak self] id in
            self?.dismiss(); self?.open(id)
        }, create: { [weak self] in self?.dismiss(); self?.create() }, dismiss: { [weak self] in self?.dismiss() }, resize: { [weak panel] count in
            guard let panel else { return }
            let height = 55 + CGFloat(min(max(count, 1), 6)) * 56
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: 480, height: height), display: true)
        }))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.midY + frame.height * 0.15 - 90))
        }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func dismiss() { panel?.orderOut(nil); panel = nil }
    func windowDidResignKey(_ notification: Notification) { dismiss() }
}

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct QuickSearchView: View {
    @ObservedObject var store: NotesStore
    let open: (String) -> Void
    let create: () -> Void
    let dismiss: () -> Void
    let resize: (Int) -> Void
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var focused: Bool
    private var results: [Note] { store.search(query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let id = selectedID ?? results.first?.id { open(id) } }
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(results) { note in
                            Button { open(note.id) } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(Theme.color(note.colorIndex)).frame(width: 9, height: 9)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(note.title.isEmpty ? "Untitled note" : note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        if !note.body.isEmpty { Text(note.body.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedID == note.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).id(note.id)
                        }
                        if results.isEmpty { Text("No matching notes").foregroundStyle(.secondary).padding(20) }
                    }.padding(7)
                }.frame(height: CGFloat(min(max(results.count, 1), 6)) * 56)
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 480).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { selectedID = results.first?.id; focused = true; resize(results.count) }
        .onChange(of: results.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
            resize(ids.count)
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onExitCommand(perform: dismiss)
        .background(Button("New Note", action: create).keyboardShortcut("n").hidden())
    }
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[min(max(index + delta, 0), results.count - 1)].id
    }
}
