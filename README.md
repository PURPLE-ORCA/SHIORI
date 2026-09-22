# SHIORI

A native macOS screen-edge sticky-note application. SwiftUI composes the surfaces; AppKit owns lifecycle, tracking, focus, and independent floating windows. The body is a native NSTextView. No web runtime or permissions are needed for the basic workflow.

## Build and run

Requires macOS 14+, Xcode with Swift 6 support, and Xcode command-line tools. Development environment: Xcode 26.4 (17E192), Swift 6.3, Apple silicon. GRDB is pinned to [**7.8.0**](https://github.com/groue/GRDB.swift/releases/tag/v7.8.0), whose package requires Swift 6.0 and supports macOS 10.15+. Its resolved revision is recorded in the Xcode workspace's `Package.resolved`.

The generated Xcode project and shared SHIORI scheme are included. Open `SHIORI.xcodeproj` and Run, or:

```sh
xcodebuild -resolvePackageDependencies -project SHIORI.xcodeproj -scheme SHIORI
xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/SHIORI.app
xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath build test
```

Local Debug builds use ad-hoc signing (`CODE_SIGN_IDENTITY=-`), with no development team or paid developer account. This is a local application, not a notarized distribution. The application has no Dock icon or launch-time main window; use its menu-bar note icon or the small screen-edge pill.

To regenerate the project after adding/removing source files, install XcodeGen (`brew install xcodegen`) and run `xcodegen generate`. Configuration lives in `project.yml`; generation was performed with XcodeGen 2.46.0.

## Use

Hover at the right screen edge to open the note deck. Click a card to edit, or the plus to create a note. Drag the deck grip to move it vertically. The menu bar provides New Note, deck visibility, floating-note visibility, Settings, backup, data-folder access, and Quit.

A note can be pinned to stay open independently. Closing it unpins and returns it to the deck. Only one unpinned editor is open at a time. Complete checks unfinished tasks and archives the note. Archived data remains saved; the All Notes browsing and restore interface has been removed.

Use the note header to move a window. The five circles select the note color. Type `- ` or `* ` at a line start to begin a checklist; Return continues it and Return on an empty task exits. Checkboxes operate on the actual stored Markdown. Native editing supports standard copy/paste and undo/redo. Cmd+N creates a note, Cmd+W closes the current window, and Cmd+Z / Cmd+Shift+Z undo/redo while editing.

## Data and backups

Bundle identifier: `app.shiori.desktop`.

- Database: `~/Library/Application Support/app.shiori.desktop/notes.sqlite`
- Snapshots: `~/Library/Application Support/app.shiori.desktop/Backups/`
- Preferences: UserDefaults domain `app.shiori.desktop` (edge, normalized anchor, hover delays, Spaces/full-screen preferences, first-launch flag, per-note window geometry and display identity).

SQLite is the only durable notes store. UUIDs are stored as strings. Timestamps are Unix epoch seconds (`REAL`, UTC absolute instants). The first explicit migration creates the constrained note table and query indexes; migrations never erase existing data. Body content is ordinary, unencrypted Markdown text.

Autosave coalesces typing for about 300 ms, with a two-second maximum interval. Explicit lifecycle flushes run before closing/switching editors, pin transitions, completion, backup, and normal termination. A failed save retains the draft and presents retry; a failed termination flush keeps the app running. Successfully committed changes survive relaunch. A forced kill or power failure can lose edits that have not yet committed.

Backups use SQLite's backup API through GRDB, reopen and validate the snapshot, and retain the latest seven successful snapshots. An automatic snapshot is attempted after load at most once per day; Back Up Now first flushes pending edits.

### Restore a snapshot

1. Quit SHIORI normally. If saving fails, resolve or preserve the unsaved draft before proceeding.
2. In Finder, open the data folder and copy the entire folder somewhere safe.
3. Choose a successful `.sqlite` snapshot from `Backups`. Copy it into the data folder as `notes.sqlite`, replacing the current database only after preserving the original.
4. With SHIORI still closed, move any old `notes.sqlite-wal`, `notes.sqlite-shm`, and `notes.sqlite-journal` files aside with the original database, if present. Do not attach old sidecars to the restored snapshot.
5. Relaunch SHIORI. Preferences/window positions are separate from database backups and are not rolled back.

Never replace database files while SHIORI is running. No in-app restore wizard or note export workflow is included.

## Architecture

- `AppCoordinator`: application/menu lifecycle, launch recovery, backup commands, termination deferral.
- `StickyWindowManager`: one native editor per UUID, transient/pinned ownership, debounced geometry.
- `EdgeDockController`: bounded non-key dock/deck panels, tracking, hover state, ordering interaction.
- `NotesStore` / autosave: immediate observable drafts, revision-aware coalescing and explicit flushes.
- `NoteRepository`: one GRDB DatabaseQueue, migrations, field-specific commands, transactions, snapshots.
- `ChecklistEngine` / `NativeEditor`: UTF-16 Markdown transformations and native text-layout checkbox interaction.
- `SettingsStore`: typed preferences, palette, and pure frame clamping.

The dock retains one display while it exists, and falls back when it disappears. Restored note frames are clamped into the current usable display arrangement. Hover never deliberately activates the application or makes a panel key. Editors activate only after an explicit open action; restored pinned windows do not.

## Validation

Automated tests use temporary databases and isolated preferences. Desktop QA uses `SHIORI_DATA_DIR` and `SHIORI_DEFAULTS_SUITE` environment overrides; these are test isolation hooks, not a second notes storage mode. See `QA.md` for the recorded build/test results and actual manual coverage. The available runtime is macOS 26.6.2 on Apple silicon; macOS 14 and Intel runtime behavior are unverified, although the project compiles with a macOS 14 deployment target. Spaces, full-screen overlays, multiple physical displays, sleep/wake, and performance are only claimed where recorded there.

## Deferred

Cloud/iCloud synchronization, Obsidian, Markdown mirroring, import/export, encryption/Touch ID/passwords, rich Markdown toolbars, custom fonts, additional dock styles/bottom edge, global shortcuts, permanent deletion/trash/undo toasts, launch-at-login, updating/notarization/App Store, accounts, telemetry, AI, attachments, and collaboration.
