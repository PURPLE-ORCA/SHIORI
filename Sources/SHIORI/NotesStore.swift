import Combine
import Foundation
import OSLog

public enum NoteSaveState: Equatable, Sendable {
    case clean, dirty, saving
    case error(String)
}

public struct NoteDraft: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let colorIndex: Int
    public let revision: UInt64
}

@MainActor
public final class NotesStore: ObservableObject {
    @Published public private(set) var notes: [Note] = []
    @Published public private(set) var drafts: [String: NoteDraft] = [:]
    @Published public private(set) var saveStates: [String: NoteSaveState] = [:]
    @Published public private(set) var busyIDs = Set<String>()
    public let repository: NoteRepository
    public var active: [Note] { notes.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex } }

    private struct Pending {
        var snapshot: Note
        var revision: UInt64
        var textChanged: Bool
        var colorChanged: Bool
        var firstEdit: ContinuousClock.Instant
        var lastEdit: ContinuousClock.Instant
    }
    private var pending: [String: Pending] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var writes: [String: Task<Void, Error>] = [:]
    private var revision: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let debounce: Duration
    private let maxInterval: Duration
    private let writeOverride: (@Sendable (Note, Bool, Bool) async throws -> Void)?

    public init(repository: NoteRepository, debounce: Duration = .milliseconds(300), maxInterval: Duration = .seconds(2), writeOverride: (@Sendable (Note, Bool, Bool) async throws -> Void)? = nil) {
        self.repository = repository
        self.debounce = debounce
        self.maxInterval = maxInterval
        self.writeOverride = writeOverride
    }

    @discardableResult
    public func load() async throws -> [Note] {
        let loaded = try await repository.loadAllNotes()
        notes = loaded.map { pending[$0.id]?.snapshot ?? $0 }
        for note in loaded where pending[note.id] == nil { saveStates[note.id] = .clean }
        return notes
    }
    @discardableResult
    public func create() async throws -> Note {
        let note = try await repository.create()
        notes.insert(note, at: 0)
        saveStates[note.id] = .clean
        return note
    }
    public func note(id: String) -> Note? { notes.first { $0.id == id } }
    public func isBusy(_ id: String) -> Bool { busyIDs.contains(id) }
    public func hasError(_ id: String) -> Bool { if case .error = saveStates[id] { return true }; return false }
    public func saveError(_ id: String) -> String? { if case .error(let message) = saveStates[id] { return message }; return nil }
    public func saveStatus(_ id: String) -> String {
        if isBusy(id) { return "Saving…" }
        return switch saveStates[id] ?? .clean {
        case .clean: "Saved"
        case .dirty, .saving: "Saving…"
        case .error: "Couldn't save"
        }
    }
    public func edit(_ id: String, title: String? = nil, body: String? = nil, colorIndex: Int? = nil) {
        guard !isBusy(id), let index = notes.firstIndex(where: { $0.id == id }), notes[index].archivedAt == nil else { return }
        var note = notes[index]
        let textChanged = (title != nil && title != note.title) || (body != nil && body != note.body)
        let color = colorIndex.map { min(4, max(0, $0)) }
        let colorChanged = color != nil && color != note.colorIndex
        guard textChanged || colorChanged else { return }
        if let title { note.title = title }
        if let body { note.body = body }
        if let color { note.colorIndex = color }
        note.updatedAt = Date().timeIntervalSince1970
        notes[index] = note
        revision &+= 1
        let now = ContinuousClock.now
        let previous = pending[id]
        pending[id] = Pending(snapshot: note, revision: revision, textChanged: textChanged || previous?.textChanged == true,
                              colorChanged: colorChanged || previous?.colorChanged == true,
                              firstEdit: previous?.firstEdit ?? now, lastEdit: now)
        drafts[id] = NoteDraft(id: id, title: note.title, body: note.body, colorIndex: note.colorIndex, revision: revision)
        saveStates[id] = .dirty
        schedule(id)
    }
    public func setColor(_ id: String, colorIndex: Int) { edit(id, colorIndex: colorIndex) }
    public func retry(_ id: String) async throws { try await flush(id) }

    public func flush(_ id: String? = nil) async throws {
        // Concurrent callers await the same write rather than spin or enqueue stale snapshots.
        repeat {
            let ids = id.map { [$0] } ?? Array(Set(pending.keys).union(writes.keys))
            for id in ids {
                timers.removeValue(forKey: id)?.cancel()
                while pending[id] != nil || writes[id] != nil { try await saveOnce(id) }
            }
        } while id == nil && (!pending.isEmpty || !writes.isEmpty)
    }
    private func schedule(_ id: String) {
        guard timers[id] == nil else { return }
        timers[id] = Task { [weak self] in
            guard let self else { return }
            while let draft = self.pending[id] {
                let deadline = min(draft.lastEdit.advanced(by: self.debounce), draft.firstEdit.advanced(by: self.maxInterval))
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                guard !Task.isCancelled else { return }
                guard let latest = self.pending[id] else { self.timers[id] = nil; return }
                if ContinuousClock.now < min(latest.lastEdit.advanced(by: self.debounce), latest.firstEdit.advanced(by: self.maxInterval)) { continue }
                do { try await self.saveOnce(id) }
                catch { self.timers[id] = nil; return }
                guard !Task.isCancelled else { return }
                self.timers[id] = nil
                if self.pending[id] != nil { self.schedule(id) }
                return
            }
            self.timers[id] = nil
        }
    }
    private func saveOnce(_ id: String) async throws {
        if let existing = writes[id] { try await existing.value; return }
        guard let draft = pending[id] else { return }
        let repository = repository
        let override = writeOverride
        saveStates[id] = .saving
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let override { try await override(draft.snapshot, draft.textChanged, draft.colorChanged) }
                else {
                    if draft.textChanged { try await repository.updateText(id: id, title: draft.snapshot.title, body: draft.snapshot.body, updatedAt: draft.snapshot.updatedAt) }
                    if draft.colorChanged { try await repository.updateColor(id: id, colorIndex: draft.snapshot.colorIndex, updatedAt: draft.snapshot.updatedAt) }
                }
                if self.pending[id]?.revision == draft.revision {
                    self.pending[id] = nil; self.drafts[id] = nil; self.saveStates[id] = .clean
                } else {
                    self.pending[id]?.firstEdit = .now
                    self.saveStates[id] = .dirty
                }
                self.writes[id] = nil
            } catch {
                self.writes[id] = nil
                self.saveStates[id] = .error(error.localizedDescription)
                throw error
            }
        }
        writes[id] = task
        try await task.value
    }

    public func setPinned(_ id: String, pinned: Bool) async throws {
        guard !isBusy(id) else { throw StoreError.busy }
        busyIDs.insert(id); defer { finishOperation(id) }
        try await flush(id)
        guard note(id: id)?.pinned != pinned else { return }
        try await repository.setPinned(id: id, pinned: pinned)
        if let index = notes.firstIndex(where: { $0.id == id }) { notes[index].pinned = pinned }
    }
    public func complete(_ id: String) async throws {
        guard !isBusy(id) else { throw StoreError.busy }
        busyIDs.insert(id); defer { finishOperation(id) }
        try await flush(id)
        guard let note = note(id: id), note.archivedAt == nil else { return }
        let body = ChecklistEngine.completeAll(text: note.body)
        let now = Date().timeIntervalSince1970
        try await repository.complete(id: id, body: body, updatedAt: now)
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].body = body; notes[index].archivedAt = now; notes[index].doneAt = now
            notes[index].pinned = false; notes[index].updatedAt = now
        }
    }
    public func restore(_ id: String) async throws {
        guard !isBusy(id) else { throw StoreError.busy }
        busyIDs.insert(id); defer { finishOperation(id) }
        try await repository.restore(id: id)
        if let restored = try await repository.loadAllNotes().first(where: { $0.id == id }),
           let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index] = restored
        }
    }
    public func reorder(ids: [String]) async throws {
        try await repository.reorder(ids: ids)
        for (order, id) in ids.enumerated() {
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index].sortIndex = Double(order)
                pending[id]?.snapshot.sortIndex = Double(order)
            }
        }
    }
    public func reorder(_ ids: [String]) async throws { try await reorder(ids: ids) }
    public func drain() async throws {
        repeat {
            if !busyIDs.isEmpty { await withCheckedContinuation { idleWaiters.append($0) } }
            try await flush()
        } while !busyIDs.isEmpty
    }
    private func finishOperation(_ id: String) {
        busyIDs.remove(id)
        if busyIDs.isEmpty {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    public func backup(in directory: URL) async throws -> URL { try await drain(); return try await repository.backup(in: directory) }
}

private enum StoreError: LocalizedError {
    case busy
    var errorDescription: String? { "This note is finishing another operation. Please try again." }
}
