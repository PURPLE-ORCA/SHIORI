import SwiftUI

struct AllNotesView: View {
    @ObservedObject var store: NotesStore
    let open: (String) -> Void
    let reportError: (Error) -> Void
    @State private var query = ""
    @State private var archived = false
    @State private var selected: String?
    private var matches: [Note] {
        store.notes.filter { note in
            (note.archivedAt != nil) == archived && (query.isEmpty || (note.title + "\n" + note.body).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }.sorted { $0.sortIndex < $1.sortIndex }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search notes", text: $query).textFieldStyle(.roundedBorder)
                Picker("Notes", selection: $archived) { Text("Active").tag(false); Text("Archived").tag(true) }.pickerStyle(.segmented).frame(width: 180)
            }.padding(16)
            HSplitView {
                List(selection: $selected) {
                    ForEach(matches) { note in
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.color(note.colorIndex)).frame(width: 7, height: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title.isEmpty ? "Untitled note" : note.title).fontWeight(.medium).lineLimit(1)
                                Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.padding(.vertical, 5).tag(note.id)
                    }
                }.frame(minWidth: 220, idealWidth: 260)
                if let note = matches.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(note.title.isEmpty ? "Untitled note" : note.title).font(.title2).fontWeight(.semibold)
                        Text(Date(timeIntervalSince1970: note.updatedAt), style: .date).font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(note.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        if archived {
                            Button("Restore Note", systemImage: "arrow.uturn.backward") {
                                Task { do { try await store.restore(note.id) } catch { reportError(error) } }
                            }
                        } else { Button("Open Note", systemImage: "arrow.up.right") { open(note.id) } }
                    }.padding(24).frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView(matches.isEmpty ? "No notes found" : "Select a note", systemImage: "note.text", description: Text(matches.isEmpty ? "Try another search or switch between Active and Archived." : "Your note will appear here."))
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(minWidth: 600, minHeight: 380)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let reset: () -> Void
    var body: some View {
        Form {
            Picker("Screen edge", selection: $settings.edge) { Text("Left").tag("left"); Text("Right").tag("right") }
            HStack {
                Text("Open delay")
                Slider(value: $settings.openDelay, in: 0...0.8, step: 0.05)
                Text("\(Int(settings.openDelay * 1000)) ms").monospacedDigit().frame(width: 60)
            }
            HStack {
                Text("Close delay")
                Slider(value: $settings.closeDelay, in: 0.1...1, step: 0.05)
                Text("\(Int(settings.closeDelay * 1000)) ms").monospacedDigit().frame(width: 60)
            }
            Toggle("Show across Spaces", isOn: $settings.acrossSpaces)
            Toggle("Show over full-screen applications", isOn: $settings.fullscreen)
            Button("Reset Dock and Window Positions", action: reset)
        }.formStyle(.grouped).padding(8).frame(minWidth: 380, minHeight: 290)
    }
}
