# SHIORI

A native macOS menu-bar utility for a handful of notes kept at the screen edge. SwiftUI composes the surfaces; AppKit owns windows, focus and tracking. Notes use a native NSTextView and plain Markdown stored in SQLite.

## Build and test

Requires macOS 14+ and Xcode with Swift 6.2 or later. The development environment uses Xcode 26.4 / Swift 6.3 on Apple silicon. Swift Package Manager dependencies are pinned in `project.yml` and `Package.resolved`:

- GRDB **7.8.0**
- [KeyboardShortcuts **3.0.1**](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/3.0.1)

```sh
xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath build build
xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath build test
open build/Build/Products/Debug/SHIORI.app
```

The local app is ad-hoc signed; no paid developer account is needed. It is not a notarized distribution. Regenerate the included Xcode project after adding/removing sources with `xcodegen generate`.

## Use

Compact note tabs stay attached to the left or right screen edge. Hover for a preview, click to edit, use plus to create, drag the grip to move the stack, and drag tabs to reorder. There is no dock, library, archive browser or All Notes window.

Pin a note to keep an independent floating window. Closing returns it to the edge tabs. Only one unpinned editor is open at a time. Hide/Show Floating Notes changes session visibility without unpinning or moving notes; edge tabs remain visible. Selecting a hidden pinned note explicitly reveals only that note.

Global shortcuts work while another app is active, without Accessibility, Input Monitoring or Screen Recording permissions. Settings provides recorders, clearing, reset and conflict messages:

| Command | Default |
| --- | --- |
| New Note | Option+N |
| Quick Search | Option+Space |
| Hide / Show Floating Notes | Option+Shift+H |

Quick Search searches current active titles and bodies, including unsaved drafts, with case/diacritic-insensitive Unicode matching. An empty query shows edge order. Up/Down selects, Return opens, Escape dismisses, and Cmd+N creates a note. Existing editor windows are reused.

The editor's **Aa** popover inserts bold, italic, strikethrough, inline code, links, H1/H2, bullets and checklists. Cmd+B, Cmd+I and Cmd+K operate on the current selection. Cmd+K inside a Markdown link selects its destination for editing. Native undo/redo remains available. Typing `- ` or `* ` retains the existing automatic checklist behavior; the Bullet List command inserts ordinary bullets, which Return continues separately from checklists.

**Delete Note** is in the editor's compact actions menu. It flushes the latest draft, soft-deletes the row, closes the window and offers a five-second, non-key Undo toast. Undo preserves content, color, order and pin metadata. Deleted records remain in SQLite and stay absent from normal queries; there is no purge or trash UI.

Settings includes Launch at Login through [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp). It reflects OS registration status and reports failures or required approval. The app does not modify login items during startup or tests.

## Data and safety

Bundle identifier: `app.shiori.desktop`.

- Database: `~/Library/Application Support/app.shiori.desktop/notes.sqlite`
- Automatic snapshots: `~/Library/Application Support/app.shiori.desktop/Backups/`
- Preferences: UserDefaults domain `app.shiori.desktop`

Migration `001_create_notes` creates the original schema. Migration `002_soft_delete` adds nullable `deletedAt REAL`, preserving existing rows and legacy archive metadata. Legacy archive data is not part of the active UI or Quick Search.

Autosave coalesces edits for about 300 ms, with a two-second maximum interval. Revision-aware writes preserve newer drafts. Close, pin, delete and normal termination flush pending text; a failed save retains the draft, and a failed termination flush keeps SHIORI open. Forced termination or power loss can lose uncommitted edits.

Automatic backups use SQLite's backup API, validate the snapshot and retain the latest seven successful snapshots. A snapshot is attempted after load at most once daily. There is no manual backup command, import/export or sync UI.

To recover a snapshot, quit SHIORI normally and preserve a copy of the entire data folder first. Replace `notes.sqlite` with a successful snapshot and move the original `notes.sqlite-wal`, `notes.sqlite-shm` and `notes.sqlite-journal` files aside with the original database. Never replace a running database. Window preferences are separate from snapshots.

## Architecture

- `AppCoordinator`: app/menu lifecycle, normal command routing, shortcut/search coordination and safe termination.
- `StickyWindowManager`: one editor per UUID, pinned/transient visibility, geometry and Delete/Undo coordination.
- `EdgeDockController`: existing edge-tab drawing, hit testing, hover previews, ordering and retained display identity. The historical class name does not denote a separate dock UI.
- `NotesStore`: immediate observable drafts, revision-aware autosave, live search and serialized lifecycle operations.
- `NoteRepository`: GRDB queue, additive migrations, field-specific writes and internal backups.
- `NativeEditor`, `ChecklistEngine`, `MarkdownFormattingEngine`: native editing with UTF-16 transformations and plain Markdown persistence.
- `GlobalShortcutCoordinator`, `QuickSearchController`, `DeleteUndoCoordinator`, `LaunchAtLoginService`: focused adapters for the new utility commands.
- `SettingsStore`: preferences and frame clamping.

Screen changes and wake refresh existing panels, recover window geometry and retain the edge anchor. Display fallback is persisted; dragging to another display deliberately changes the retained display. Spaces/full-screen settings continue to govern note windows and edge tabs. Hover never activates SHIORI; explicit editing and search do.

## Validation

Tests use temporary databases, isolated preference suites and unique shortcut names that are removed afterward. Shortcut tests do not register global hotkeys. Login tests use fake OS operations and never alter login items. Runtime QA can use `SHIORI_DATA_DIR` and `SHIORI_DEFAULTS_SUITE` overrides; shortcut names also use the supplied suite namespace.

See `QA.md` for exact current evidence and the separately labeled historical QA record. Interactive acceptance testing for this milestone is left to the user.
