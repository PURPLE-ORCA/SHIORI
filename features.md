# HoldMyNotes: Complete Reverse-Engineered Feature Specification

This document breaks down the complete feature set, interaction models, UI/UX behaviors, and system architecture reverse-engineered from the application video recording (`HoleMyNotes.gif`) and the native macOS application bundle (`HoldMyNotes.app`).

---

## 1. Architectural Overview & Core UX Concept

**HoldMyNotes** is a minimalist, native macOS desktop productivity application designed around three foundational states:
1. **The Edge Pill / Dock**: When resting, notes collapse into an unobtrusive vertical stripe/dock resting flush against the edge of the screen (right, left, or bottom). Each note is represented by a sliver in its distinct pastel color.
2. **The Fanned Deck**: Moving the mouse to the screen edge smoothly fans out a stack of cards into view. Hovering over any card elevates it forward with realistic elevation shadows so you can read its content without opening it.
3. **The Sticky Note / Editor Window**: Clicking a card expands it in place into a full-featured sticky note editor. Notes can either be closed back into the edge deck or pinned anywhere on the desktop as persistent floating windows.

```
┌────────────────────────────────────────────────────────────┐
│ macOS Desktop                                              │
│                                                            │
│   ┌─────────────────────┐                                █ │ <- Edge Pill (Dashes/Dots)
│   │ Pinned Sticky Note  │                                █ │
│   │ (Floating Window)   │         Hover Edge            ┌┴┐│
│   │                     │    ──────────────────►        │ ││ <- Fanned Deck
│   │ • - [x] Update Readme│                              │C││    Cards Stack
│   │ • - [ ] Test support│                               │A││
│   │ [Palette] [Complete]│                               │R││
│   └─────────────────────┘                               │D││
│                                                         └┬┘│
└────────────────────────────────────────────────────────────┘
```

---

## 2. Edge Dock & Deck Interaction System

### 2.1 The Edge Dock / Rest State
- **Screen Edge Placement**: Defaults to the right edge of the primary display; configurable to Left or Bottom screen edges.
- **Dock Visual Styles (`DockStyle`)**:
  - **Coloured Dashes / Stripes (Default)**: A slim vertical pill composed of colored segments matching the exact color palette of the active notes.
  - **Small Pile of Cards**: Miniature overlapping card representations hugging the screen border.
  - **Dots**: Minimalist dot indicators along the screen edge.
- **Deck Anchor (`_deckAnchor`, `GripDots`)**:
  - Vertical anchor handle with tactile grip dots.
  - Allows dragging the entire deck up and down along the screen edge to position it at the user's preferred height.
  - Position is persisted in preferences (`deckAnchor` offset).

### 2.2 Hover Activation & Fanning (`DeckActivation`, `DeckMover`)
- **Hover Detection**: Moving the mouse cursor into the trigger zone at the screen edge engages the deck.
- **Activation Delay (`_deckOpenDelay`)**: Configurable delay (prevents accidental opens when sweeping past the edge).
- **Fanning Animation**:
  - Cards smoothly stagger-slide out from behind the screen bezel into an overlapping vertical cascade.
  - Uses fluid spring-physics animation with configurable speed ("How briskly the deck moves").
- **Card Preview & Shadow Elevation (`DeckCardShadow`, `DeckCardSlot`)**:
  - Hovering a specific card in the stack lifts that card forward along the Z-axis.
  - Displays rich dynamic drop shadows while slightly dimming or pushing back adjacent cards.
  - Note title, timestamp, and content snippet are immediately readable without clicking.
- **Card Reordering (`DragReorder`)**:
  - Dragging a card vertically within the fanned deck reorders its position in the stack.
  - Updates the `sortIndex` in the database in real time.

### 2.3 Creation Trigger (`BurstCreateCoordinator`, `CycleNoteButton`)
- **Add Button (`+`)**: Positioned at the deck extremity (with hover highlight `_plusHovered`).
- **One-Click Instant Create**: Clicking `+` immediately generates a new blank card with an expansion animation that places the caret right into the title field.

---

## 3. Note Card & Editor Window (`EditorView`, `StickyNoteWindow`)

When clicked, a card expands from the deck into an active desktop note card.

### 3.1 Card Dimensions & Styling
- **Default Dimensions**: Approximately `340px - 400px` width by `360px - 430px` height.
- **Geometry**: Rounded corners (14px–16px corner radius) with subtle border contrast and macOS-style soft drop shadows.
- **Typography & Font Choices (`BodyFont`)**:
  - Bundled custom fonts:
    - **Nunito** (Modern, clean, legible rounded sans-serif)
    - **Virgil** (Excalidraw-style architectural, organic handwriting)
    - **Caveat** (Natural cursive pen handwriting)
    - **Comic Neue** (Playful casual print)
    - **Cascadia Code** & **Inconsolata** (Monospace coding style)
    - **Helvetica / System Font**

### 3.2 Header Bar
- **Date & Timestamp**: Displays human-readable relative/absolute date (e.g. `Mon 21 Sep 11:15`).
- **Note Title (`title`)**:
  - Clean inline editable text input.
  - Defaults to "Untitled note" for new notes.
  - Enter or Tab shifts focus directly into the body text editor.
- **Window Management Controls**:
  - **Pin Icon / Desktop Pin (`pinned`)**: Toggles between resting in the edge deck or staying pinned persistently on the desktop.
  - **Close Dot (`CloseDot`)**: Returns the card to the deck (saves automatically).

### 3.3 Body Editor (`ChecklistTextView`, `PlainTextEditor`)
- **Zero-Friction Auto-Save**: No "Save" button. All keystrokes, title edits, color changes, and checklist state changes are written immediately to local SQLite storage with debounced disk commits.
- **Plain / Markdown Text Engine**:
  - Markdown-aware plain text editing with formatted inline spans.
  - Automatic newline continuation and list bullet indentation.

### 3.4 Interactive Checklist System
- **Syntax Trigger**: Typing `- ` (dash space) or `* ` at the beginning of a line instantly creates an interactive checklist item (`insertChecklistItem`).
- **Checkbox UI**:
  - Custom circular checklist bullet to the left of the item text.
  - **Interactive Toggling**: Clicking the circular bullet toggles the item between active and completed states.
  - **Completed State Styling**:
    - Fills the circular checkbox with an accent color / check symbol.
    - Applies animated strikethrough line decoration through the task text.
    - Mutes/dims the text color slightly to visually emphasize remaining tasks.
- **Keyboard Navigation**: Pressing Enter on a checklist item automatically creates a new checklist item on the subsequent line. Pressing Enter twice on an empty item cancels the checklist mode.

---

## 4. Color Palette & Theming System

The application uses 5 signature pastel colors designed for high contrast and calming desktop aesthetics:

| Color Index | Name | Hex Code | Visual Character |
| :---: | :---: | :---: | :--- |
| **0** | **Amber / Yellow** | `#FED866` | Warm classic sticky note yellow (default for new notes) |
| **1** | **Coral / Peach** | `#FE9D7C` | Warm reddish-orange pastel for urgent or high-priority items |
| **2** | **Mint / Sage** | `#A8E5CF` | Calming green pastel for personal or finished tasks |
| **3** | **Sky Blue / Lilac** | `#A9D6FE` | Cool soft blue pastel for technical work or reference items |
| **4** | **Lavender / Purple**| `#D7C6FE` | Distinct purple pastel for creative or long-term ideas |

### Live Color Switching Interaction:
- Located along the bottom footer of the active note editor as circular color swatches (`Swatch`, `ColorWell`).
- Clicking any color circle triggers an instant, fluid background repaint of the entire card window.
- The corresponding stripe in the edge dock automatically reflects the new color immediately.
- Keyboard shortcut `Next colour` allows cycling colors rapidly without using the mouse.

---

## 5. Bottom Toolbar & Action Bar (`FormattingRow`, `FormatBarView`)

The footer of an open note card contains a unified, compact control strip:

```
┌──────────────────────────────────────────────────────────────────┐
│ [●][●][●][●][●]   [Aa]         │  [✓ Complete]     [✕ Close]     │
│  Color Swatches    Format Bar  │   Archive Action   Return to Deck│
└──────────────────────────────────────────────────────────────────┘
```

1. **Color Swatch Palette**: 5 circular color buttons representing the themes.
2. **Typography / Format Bar (`Aa`, `FormatBarController`)**:
   - Toggles a popover/flyout tray (`TrayMenu`, `TrayToggle`).
   - Font switcher (Caveat, Virgil, Nunito, Cascadia Code, etc.).
   - Heading level selectors (H1, H2, body text).
   - Format toggles: Bold, Italic, Strikethrough, Checklist item insertion, Link prompt.
3. **Divider Line**: Subtle vertical divider separating editing tools from window actions.
4. **"Complete" Button (`doneAt`, `archivedAt`)**:
   - Branded action pill button with checkmark icon.
   - Marks all tasks as done, archives the note, and smoothly animates it out of the active deck into the archive.
5. **"Close" Button**: Dismisses the editor and smoothly folds the note back into its respective slot in the edge deck.

---

## 6. Desktop Pinning & Multi-Window Behavior (`StickyWindowManager`)

- **Independent Floating Windows**: Any card can be pinned onto the desktop (`_lockNotes`, `StickyNoteWindow`).
- **Freeform Dragging (`WindowDragArea`, `DragView`)**:
  - Grab anywhere on the note header to drag it across multi-monitor setups.
  - Window frame coordinates (`{origin, size}`) are persisted per-note UUID in app preferences (e.g. `stickyFrame-<UUID>`).
- **Z-Order Layering**: Pinned notes remain visible on the desktop.
- **Show Over Full-Screen Apps (`FullScreenSpace`, `toggleFullScreen`)**:
  - Accessory mode (`LSUIElement: true`) allows windows to float over native full-screen applications, Mission Control spaces, and IDEs.

---

## 7. Search, Archive & Undo System (`ArchiveModel`, `AllNotesModel`)

### 7.1 Full-Text Search Engine (`note_fts`)
- Powered by SQLite **FTS5** with tokenization:
  ```sql
  CREATE VIRTUAL TABLE note_fts USING fts5(
      title, body, tag, noteId UNINDEXED,
      tokenize='unicode61 remove_diacritics 2'
  );
  ```
- **Instant Search**: Type in the search field to filter notes across titles, body text, and tags simultaneously with diacritics removal and prefix matching.

### 7.2 Archive Management
- **Archiving Workflow**: Notes completed with the "Complete" button leave the active deck but remain fully preserved in `notes.sqlite` (`archivedAt` timestamp).
- **Archive Window (`ArchiveView`, `ArchiveWindowBridge`)**:
  - Dedicated searchable view listing all completed and archived notes.
  - Live side-by-side note preview.
  - **One-Click Restore**: Clicking restore immediately clears `archivedAt` and re-inserts the note back into the deck stack with fresh `sortIndex`.

### 7.3 Delete & Undo Toast (`DeleteToastView`, `toastUndo`)
- Deleting a note displays an unobtrusive floating bottom toast notification (`DeleteToastView`) with a 5-second countdown and an interactive **"Undo"** action.

---

## 8. Sync, Vault Export & Integrations

### 8.1 Obsidian / Markdown Vault Export (`VaultExport`)
- **Automated Mirroring**: Can point to a local directory (such as an Obsidian vault or iCloud folder).
- Every note is written out as a standalone `.md` markdown file with title, frontmatter, and checklists.
- One-way export ensures notes are always open, future-proof, and accessible in external text editors.
- Additional bulk export options: Single combined markdown document (`Hold My Notes.md`), JSON backup (`Hold My Notes.json`), and Apple Stickies format (`Hold My Notes.stickies`).

### 8.2 Cloud Sync (`CloudSync`)
- Seamless synchronization across multiple Macs using iCloud Drive or a synchronized folder.
- File-level reconciliation with conflict resolution and sync heartbeat monitoring.

### 8.3 Global Keyboard Shortcuts (`HotKeyCenter`, `HotKeyMap`)
- **New Note Shortcut**: Global hotkey (e.g. `⌥N` / Option+N) to instantly spawn a new note from within any app.
- **Toggle Deck Shortcut**: Global hotkey to fan open / retract the edge deck.
- **All Notes / Archive**: Shortcut (e.g. `⌥L` / Option+L) to open the search and archive window.
- **Hide / Show All Notes**: Quick boss-key shortcut to toggle all floating sticky notes off/on the screen.

### 8.4 Security & Privacy (`_lockNotes`)
- Optional biometric protection: "Hide note contents until you authenticate".
- Integrates with Touch ID and macOS system authentication to reveal note text.

---

## 9. SQLite Database Schema Reference

```sql
-- Core Note Storage
CREATE TABLE IF NOT EXISTS "note" (
    "id" TEXT PRIMARY KEY NOT NULL,              -- UUID string
    "title" TEXT NOT NULL DEFAULT '',            -- Note title
    "bodyEnc" BLOB NOT NULL DEFAULT X'',         -- Encrypted or plain note payload
    "colorIndex" INTEGER NOT NULL DEFAULT 0,     -- 0: Amber, 1: Coral, 2: Mint, 3: Lilac, 4: Blue
    "pinned" BOOLEAN NOT NULL DEFAULT 0,         -- 0: In deck, 1: Floating on desktop
    "createdAt" DOUBLE NOT NULL,                 -- Unix epoch timestamp
    "updatedAt" DOUBLE NOT NULL,                 -- Unix epoch timestamp
    "deletedAt" DOUBLE,                          -- Soft delete timestamp
    "sortIndex" DOUBLE NOT NULL DEFAULT 0,       -- Ordering position in deck stack
    "archivedAt" DOUBLE,                         -- Archive timestamp (NULL if active)
    "tag" TEXT NOT NULL DEFAULT '',              -- Optional categorization tag
    "doneAt" DOUBLE,                             -- Completion timestamp
    "fontName" TEXT NOT NULL DEFAULT ''          -- Font override (e.g. Virgil, Caveat)
);

-- Indexes for 60fps performance
CREATE INDEX "idx_note_updatedAt" ON "note"("updatedAt");
CREATE INDEX "idx_note_pinned" ON "note"("pinned");
CREATE INDEX "idx_note_deletedAt" ON "note"("deletedAt");
CREATE INDEX "idx_note_sortIndex" ON "note"("sortIndex");
CREATE INDEX "idx_note_archivedAt" ON "note"("archivedAt");
CREATE INDEX "idx_note_doneAt" ON "note"("doneAt");

-- Full-Text Search Virtual Table
CREATE VIRTUAL TABLE note_fts USING fts5(
    title, 
    body, 
    tag, 
    noteId UNINDEXED,
    tokenize='unicode61 remove_diacritics 2'
);
```

---

## 10. Summary of Video Walkthrough Demonstration

In purpleorca's recording (`HoleMyNotes.gif`), the interactions occur in this exact sequence:
1. **0:00 – 0:05 | Rest State & Hover Fan**:
   The desktop starts clean with only the colored pill visible at the right edge. As the pointer reaches the edge, the deck fluidly fans open into a vertical stack showing existing notes (`PERSO TODO`, `DHADX TODOs`, `ASFAR-SAHRAOUI TODAYS TODOs`). Hovering individual cards lifts them forward with 3D shadow elevation.
2. **0:06 – 0:18 | Note Creation & Content Editing**:
   The user clicks the `+` button at the edge. A yellow card expands in place. The user types the title `new card tasks`, tabs down into the note body, and writes `New cardnew`.
3. **0:19 – 0:26 | Color Swatching & Window Manipulation**:
   The user clicks through the bottom color swatches: first Coral (peach-red `#FE9D7C`), then Mint (green `#A8E5CF`), then Sky Blue (`#A9D6FE`). The card background reacts instantly with zero lag. The user pins and moves the note on screen.
4. **0:27 – 0:35 | Deck Retraction & Multi-Screen Persistence**:
   The editor closes back into the deck. The user moves across spaces/apps, showing how the edge deck stays anchored and reachable across all spaces.
5. **0:36 – 0:41 | Interactive Checklist Completion**:
   The user opens `ASFAR-SAHRAOUI TODAYS TODOs`. The note contains checklist items `- Update root README` and `- Test Support role`. The user clicks the round bullet next to `Update root README`: it instantly checks off and strikes through the task text in real time.
