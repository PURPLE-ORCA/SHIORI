import XCTest
@testable import SHIORI

private actor WriteProbe {
    private var bodies: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?
    private let gateFirst: Bool
    init(gateFirst: Bool = false) { self.gateFirst = gateFirst }
    func record(_ body: String) async {
        bodies.append(body)
        let count = bodies.count
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        if gateFirst && count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
    }
    func waitFor(_ count: Int) async {
        if bodies.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() { releaseFirst?.resume(); releaseFirst = nil }
    func recorded() -> [String] { bodies }
}

@MainActor
final class AutosaveTests: XCTestCase {
    private func database() async throws -> (URL, NoteRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-autosave-\(UUID().uuidString)")
        return (root, try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite")))
    }
    func testCoalescingAndMaximumInterval() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = WriteProbe()
        let store = NotesStore(repository: repository, debounce: .seconds(60), maxInterval: .milliseconds(40), writeOverride: { note, _, _ in
            await probe.record(note.body)
            try await repository.updateText(id: note.id, title: note.title, body: note.body)
        })
        let note = try await store.create()
        store.edit(note.id, body: "one")
        store.edit(note.id, body: "two")
        store.edit(note.id, body: "three")
        await probe.waitFor(1)
        try await store.flush()
        let bodies = await probe.recorded()
        XCTAssertEqual(bodies, ["three"])
        XCTAssertNil(store.drafts[note.id])
    }
    func testOlderSaveCannotClearNewerTextOrColorAndConcurrentFlushWaits() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = WriteProbe(gateFirst: true)
        let store = NotesStore(repository: repository, debounce: .seconds(60), writeOverride: { note, text, color in
            await probe.record(note.body)
            if text { try await repository.updateText(id: note.id, title: note.title, body: note.body) }
            if color { try await repository.updateColor(id: note.id, colorIndex: note.colorIndex) }
        })
        let note = try await store.create()
        store.edit(note.id, body: "old")
        let firstFlush = Task { try await store.flush(note.id) }
        await probe.waitFor(1)
        store.edit(note.id, body: "new 😀 café العربية", colorIndex: 3)
        XCTAssertNotNil(store.drafts[note.id])
        let secondFlush = Task { try await store.flush(note.id) }
        await probe.release()
        try await firstFlush.value
        try await secondFlush.value
        let saved = try await repository.loadAllNotes().first
        XCTAssertEqual(saved?.body, "new 😀 café العربية")
        XCTAssertEqual(saved?.colorIndex, 3)
        XCTAssertNil(store.drafts[note.id])
        XCTAssertEqual(store.saveStatus(note.id), "Saved")
    }
    func testCompleteWaitsForTextThenAtomicallyArchivesAndRestoreKeepsMarkers() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = WriteProbe(gateFirst: true)
        let store = NotesStore(repository: repository, debounce: .seconds(60), writeOverride: { note, text, color in
            await probe.record(note.body)
            if text { try await repository.updateText(id: note.id, title: note.title, body: note.body) }
            if color { try await repository.updateColor(id: note.id, colorIndex: note.colorIndex) }
        })
        let note = try await store.create()
        try await store.setPinned(note.id, pinned: true)
        store.edit(note.id, body: "- [ ] old")
        let flush = Task { try await store.flush(note.id) }
        await probe.waitFor(1)
        store.edit(note.id, body: "- [ ] latest\n```\n- [ ] code\n```", colorIndex: 2)
        let complete = Task { try await store.complete(note.id) }
        await Task.yield()
        XCTAssertTrue(store.isBusy(note.id))
        let drain = Task { try await store.drain() }
        await probe.release()
        try await flush.value
        try await drain.value
        XCTAssertTrue(store.active.isEmpty)
        try await complete.value
        let archived = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(archived.body, "- [x] latest\n```\n- [ ] code\n```")
        XCTAssertNotNil(archived.doneAt)
        XCTAssertNotNil(archived.archivedAt)
        XCTAssertFalse(archived.pinned)
        do {
            try await repository.updateText(id: note.id, title: "stale", body: "late save")
            XCTFail("Archived notes must reject delayed text writes")
        } catch { XCTAssertEqual(error as? NoteRepositoryError, .noteUnavailable) }
        let durable = try await repository.loadArchivedNotes().first
        XCTAssertEqual(durable?.body, archived.body)
        XCTAssertEqual(durable?.colorIndex, 2)
        try await store.restore(note.id)
        XCTAssertEqual(store.active.first?.body, archived.body)
        XCTAssertNil(store.active.first?.doneAt)
        XCTAssertNil(store.active.first?.archivedAt)
    }
    func testFailedDraftCanRetryWithoutLosingContent() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = RetryGate()
        let store = NotesStore(repository: repository, debounce: .seconds(60), writeOverride: { note, _, _ in
            try await attempts.check()
            try await repository.updateText(id: note.id, title: note.title, body: note.body)
        })
        let note = try await store.create()
        store.edit(note.id, body: "Still here")
        do { try await store.flush(); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(store.drafts[note.id]?.body, "Still here")
        XCTAssertTrue(store.hasError(note.id))
        try await store.retry(note.id)
        XCTAssertNil(store.drafts[note.id])
        XCTAssertFalse(store.hasError(note.id))
        let saved = try await repository.loadAllNotes().first
        XCTAssertEqual(saved?.body, "Still here")
    }
    func testHundredNotesAndLongUnicodeDraftRemainReachableAfterReopen() async throws {
        let (root, repository) = try await database()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<100 { _ = try await repository.create(note: Note(title: "Note \(index)", pinned: index < 4)) }
        let store = NotesStore(repository: repository, debounce: .seconds(60))
        try await store.load()
        let first = try XCTUnwrap(store.active.first)
        let body = String(repeating: "English · Français café · العربية 😀\n", count: 1500)
        store.edit(first.id, body: body)
        try await store.flush()
        let order = store.active.map(\.id).reversed()
        try await store.reorder(ids: Array(order))
        let reopened = try await NoteRepository.open(at: root.appendingPathComponent("notes.sqlite"))
        let saved = try await reopened.loadActiveNotes()
        XCTAssertEqual(saved.count, 100)
        XCTAssertEqual(saved.map(\.id), Array(order))
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.body, body)
        XCTAssertEqual(saved.filter(\.pinned).count, 4)
    }
}

private actor RetryGate {
    private var failed = false
    enum Failure: Error { case unavailable }
    func check() throws {
        if !failed { failed = true; throw Failure.unavailable }
    }
}
