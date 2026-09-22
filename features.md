# HoldMyNotes: Complete Reverse-Engineered Feature Specification

This document breaks down the complete feature set, interaction models, UI/UX behaviors, and system architecture reverse-engineered from the application video recording (`HoleMyNotes.gif`) and the native macOS application bundle (`HoldMyNotes.app`).

SHIORI status: `✔︎ done` marks implemented functionality. Parentheses narrow the claim where SHIORI differs from this reference. Unmarked items are not claimed as complete. This is a historical reference, not the current product roadmap. SHIORI uses edge tabs, not a separate dock or deck browser. All Notes, archive UI, manual backup UI, import/export and sync are out of scope. “Done” means implemented, not necessarily manually verified on every macOS configuration.

---

## 1. Architectural Overview & Core UX Concept

**HoldMyNotes** is a minimalist, native macOS desktop productivity application designed around three foundational states:
1. **The Edge Pill / Dock**: When resting, notes collapse into an unobtrusive vertical stripe/dock resting flush against the edge of the screen (right, left, or bottom). Each note is represented by a sliver in its distinct pastel color. — ✔︎ done (right/left edges only)
2. **The Fanned Deck**: Moving the mouse to the screen edge smoothly fans out a stack of cards into view. Hovering over any card elevates it forward with realistic elevation shadows so you can read its content without opening it. — ✔︎ done (compact tabs with hover previews)
3. **The Sticky Note / Editor Window**: Clicking a card expands it in place into a full-featured sticky note editor. Notes can either be closed back into the edge deck or pinned anywhere on the desktop as persistent floating windows. — ✔︎ done (native Markdown editor with plain-text storage; opens and closes without animation)

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
- **Screen Edge Placement**: Defaults to the right edge of the primary display; configurable to Left or Bottom screen edges. — ✔︎ done (right/left; no bottom placement)
- **Dock Visual Styles (`DockStyle`)**:
  - **Coloured Dashes / Stripes (Default)**: Thin colored note stripes attached directly to the screen edge. — ✔︎ done (no separate pill or dock)
  - **Small Pile of Cards**: Miniature overlapping card representations hugging the screen border.
  - **Dots**: Minimalist dot indicators along the screen edge.
- **Deck Anchor (`_deckAnchor`, `GripDots`)**:
  - Vertical anchor handle with tactile grip dots. — ✔︎ done
  - Allows dragging the entire deck up and down along the screen edge to position it at the user's preferred height. — ✔︎ done
  - Position is persisted in preferences (`deckAnchor` offset). — ✔︎ done (normalized anchor)

### 2.2 Hover Activation & Fanning (`DeckActivation`, `DeckMover`)
- **Hover Detection**: Moving the mouse cursor into the trigger zone at the screen edge engages the deck. — ✔︎ done
- **Activation Delay (`_deckOpenDelay`)**: Configurable delay (prevents accidental opens when sweeping past the edge). — ✔︎ done
- **Fanning Animation**:
  - Cards smoothly stagger-slide out from behind the screen bezel into an overlapping vertical cascade. — ✔︎ done
  - Uses fluid spring-physics animation with configurable speed ("How briskly the deck moves").
- **Card Preview & Shadow Elevation (`DeckCardShadow`, `DeckCardSlot`)**:
  - Hovering a specific card in the stack lifts that card forward along the Z-axis. — ✔︎ done
  - Displays rich dynamic drop shadows while slightly dimming or pushing back adjacent cards.
  - Note title, timestamp, and content snippet are immediately readable without clicking. — ✔︎ done
- **Card Reordering (`DragReorder`)**:
  - Dragging a card vertically within the fanned deck reorders its position in the stack. — ✔︎ done
  - Updates the `sortIndex` in the database in real time. — ✔︎ done (saved transactionally on drop, not every movement)

### 2.3 Creation Trigger (`BurstCreateCoordinator`, `CycleNoteButton`)
- **Add Button (`+`)**: Positioned at the deck extremity (with hover highlight `_plusHovered`). — ✔︎ done (including animated entrance/exit)
- **One-Click Instant Create**: Clicking `+` immediately generates a new blank card with an expansion animation that places the caret right into the title field. — ✔︎ done (creation and title focus; no create-from-button morph)

---

## 3. Note Card & Editor Window (`EditorView`, `StickyNoteWindow`)

When clicked, a card expands from the deck into an active desktop note card.

### 3.1 Card Dimensions & Styling
- **Default Dimensions**: Approximately `340px - 400px` width by `360px - 430px` height. — ✔︎ done (editor: 360 × 400 pt; previews are smaller)
- **Geometry**: Rounded corners (14px–16px corner radius) with subtle border contrast and macOS-style soft drop shadows. — ✔︎ done
- **Typography & Font Choices (`BodyFont`)**:
  - Bundled custom fonts:
    - **Nunito** (Modern, clean, legible rounded sans-serif)
    - **Virgil** (Excalidraw-style architectural, organic handwriting)
    - **Caveat** (Natural cursive pen handwriting)
    - **Comic Neue** (Playful casual print)
    - **Cascadia Code** & **Inconsolata** (Monospace coding style)
    - **Architects Daughter / Indie Flower / Kalam / System** — ✔︎ done (one global note-body preference, Architects Daughter default; 14–24 pt; other UI keeps system fonts)

### 3.2 Header Bar
- **Date & Timestamp**: Removed from the editor by product decision; timestamps remain in hover previews.
- **Note Title (`title`)**:
  - Clean inline editable text input. — ✔︎ done
  - Defaults to "Untitled note" for new notes. — ✔︎ done
  - Enter or Tab shifts focus directly into the body text editor. — ✔︎ done
- **Window Management Controls**:
  - **Pin Icon / Desktop Pin (`pinned`)**: Toggles between resting in the edge deck or staying pinned persistently on the desktop. — ✔︎ done
  - **Close Dot (`CloseDot`)**: Returns the card to the deck (saves automatically). — ✔︎ done (close icon; closes without animation)

### 3.3 Body Editor (`ChecklistTextView`, `PlainTextEditor`)
- **Zero-Friction Auto-Save**: No "Save" button. All keystrokes, title edits, color changes, and checklist state changes are written immediately to local SQLite storage with debounced disk commits. — ✔︎ done (debounced persistence, not an immediate disk write per keystroke)
- **Plain / Markdown Text Engine**:
  - Markdown-aware plain text editing with formatted inline spans. — ✔︎ done (native NSTextView rendering; plain Markdown persistence)
  - Automatic newline continuation and list bullet indentation. — ✔︎ done (bullets, numbered lists and checklists; Tab/Shift+Tab indentation, empty-item Return exits or outdents, Backspace removes the marker)
  - Native undo/redo and Unicode-aware formatting. — ✔︎ done

### 3.4 Interactive Checklist System
- **Syntax Trigger**: `- [ ] task` / `- [x] task` renders an interactive checklist; the Aa popover can insert one. — ✔︎ done (ordinary `- ` / `* ` bullets remain ordinary lists)
- **Checkbox UI**:
  - Custom circular checklist bullet to the left of the item text.
  - **Interactive Toggling**: Clicking the circular bullet toggles the item between active and completed states. — ✔︎ done (rounded-square checkbox)
  - **Completed State Styling**:
    - Fills the circular checkbox with an accent color / check symbol. — ✔︎ done (checked indicator; rounded-square shape)
    - Applies animated strikethrough line decoration through the task text. — ✔︎ done (static strikethrough; no strike animation)
    - Mutes/dims the text color slightly to visually emphasize remaining tasks. — ✔︎ done
- **Keyboard Navigation**: Pressing Enter on a checklist item automatically creates a new checklist item on the subsequent line. Pressing Enter twice on an empty item cancels the checklist mode. — ✔︎ done (Enter on an empty task exits)

---

## 4. Color Palette & Theming System — ✔︎ done

The application uses 5 signature pastel colors designed for high contrast and calming desktop aesthetics:

| Color Index | Name | Hex Code | Visual Character |
| :---: | :---: | :---: | :--- |
| **0** | **Amber / Yellow** | `#FED866` | Warm classic sticky note yellow (default for new notes) |
| **1** | **Coral / Peach** | `#FE9D7C` | Warm reddish-orange pastel for urgent or high-priority items |
| **2** | **Mint / Sage** | `#A8E5CF` | Calming green pastel for personal or finished tasks |
| **3** | **Sky Blue / Lilac** | `#A9D6FE` | Cool soft blue pastel for technical work or reference items |
| **4** | **Lavender / Purple**| `#D7C6FE` | Distinct purple pastel for creative or long-term ideas |

### Live Color Switching Interaction:
- Located along the bottom footer of the active note editor as circular color swatches (`Swatch`, `ColorWell`). — ✔︎ done
- Clicking any color circle triggers an instant, fluid background repaint of the entire card window. — ✔︎ done (immediate color update)
- The corresponding stripe in the edge dock automatically reflects the new color immediately. — ✔︎ done
- Keyboard shortcut `Next colour` allows cycling colors rapidly without using the mouse.

---

## 5. Bottom Toolbar & Action Bar (`FormattingRow`, `FormatBarView`)

The footer of an open note card contains a unified, compact control strip:

```
┌──────────────────────────────────────────────────────────────────┐
│ [●][●][●][●][●]                 [Aa]              [Trash]       │
│  Color Swatches                Formatting         Delete        │
└──────────────────────────────────────────────────────────────────┘
```

1. **Color Swatch Palette**: 5 circular color buttons representing the themes. — ✔︎ done
2. **Typography / Format Bar (`Aa`, `FormatBarController`)**:
   - Toggles a compact formatting popover. — ✔︎ done
   - Global Note Font and Note Font Size in Settings → Typography. — ✔︎ done (Architects Daughter, Indie Flower, Kalam, System; no per-note font switcher)
   - Heading level selectors. — ✔︎ done (H1/H2 toggle on current or selected lines)
   - Bold, Italic, Strikethrough, Inline Code, Link, Bullet List and Checklist insertion. — ✔︎ done (Cmd+B, Cmd+I, Cmd+K; link destination selected inline, no separate prompt)
3. **Divider Line**: Subtle vertical divider separating editing tools from window actions.
4. **"Complete / Archive" Action**: Removed from the active UI; historical database fields remain for compatibility.
5. **Delete Icon**: Simple trash button using soft Delete + Undo. — ✔︎ done
6. **Compact Editor Chrome**: Date and Saved/Saving labels removed; reduced vertical padding. — ✔︎ done (save failures retain a retry control)
7. **Close Control**: Located in the header; returns the note to its edge tab. — ✔︎ done (instant close; no animation)

---

## 6. Desktop Pinning & Multi-Window Behavior (`StickyWindowManager`)

- **Independent Floating Windows**: Any card can be pinned onto the desktop (`_lockNotes`, `StickyNoteWindow`). — ✔︎ done
- **Freeform Dragging (`WindowDragArea`, `DragView`)**:
  - Grab anywhere on the note header to drag it across multi-monitor setups. — ✔︎ done (top-margin and footer drag areas)
  - Window frame coordinates (`{origin, size}`) are persisted per-note UUID in app preferences (e.g. `stickyFrame-<UUID>`). — ✔︎ done
- **Z-Order Layering**: Pinned notes remain visible on the desktop. — ✔︎ done
- **Show Over Full-Screen Apps (`FullScreenSpace`, `toggleFullScreen`)**:
  - Settings use public AppKit collection behavior for Show Across Spaces and Show Over Full-Screen Apps. — ✔︎ done (actual Space/full-screen switching still needs manual QA)
- **Multiple Displays**: Edge tabs on every connected monitor; opening a note on another monitor reuses and moves its existing editor. — ✔︎ done (automated checks passed on two connected displays)
- **Display / Wake Recovery**: Reconcile panels after display changes and wake; clamp stranded windows without moving valid frames. — ✔︎ done (physical disconnect/reconnect and sleep/wake remain unverified)
- **Hide / Show Floating Notes**: Menu command and global shortcut hide pinned windows without changing pin state or saved geometry; edge tabs remain visible. — ✔︎ done

---

## 7. Quick Search, Delete & Undo

### 7.1 Transient Quick Search — ✔︎ done
- Small keyboard-focused panel invoked from the menu or global shortcut.
- In-memory title/body matching includes current unsaved drafts; case-, diacritic-insensitive and Unicode-safe.
- Only active, non-deleted notes; empty query follows edge order.
- Up/Down selects, Return opens, Escape dismisses, Cmd+N creates.
- Reuses existing editors and reveals only the selected hidden pinned note.
- No FTS, tags, search history or All Notes window.

### 7.2 Archive Management — out of scope
- Archive browsing, search, restore UI and Complete / Archive actions are absent.
- Legacy archive rows and fields remain intact for migration compatibility.

### 7.3 Delete & Undo Toast — ✔︎ done
- Flush the latest draft before transactionally setting nullable `deletedAt`.
- Remove the note from tabs/search and close its editor; retain the database row and content.
- Show a non-key Undo toast on the relevant screen for approximately five seconds.
- Undo restores content, color, sort order and pin metadata.
- No Trash window, permanent-delete UI or automatic purge.

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

### 8.3 Global Keyboard Shortcuts — ✔︎ done
- **New Note**: Option+N by default.
- **Quick Search**: Option+Space by default.
- **Hide / Show Floating Notes**: Option+Shift+H by default.
- Native Settings recorders support replacing, clearing and resetting shortcuts, with conflict reporting and immediate updates.
- KeyboardShortcuts 3.0.1; no Accessibility, Input Monitoring or Screen Recording permission required.
- No Toggle Dock or All Notes / Archive shortcut.

### 8.4 Security & Privacy (`_lockNotes`)
- Optional biometric protection: "Hide note contents until you authenticate".
- Integrates with Touch ID and macOS system authentication to reveal note text.

### 8.5 Launch at Login — ✔︎ done
- Settings uses ServiceManagement / SMAppService and reflects actual OS registration state.
- Registration errors and required approval are reported; tests use fake OS operations.
- A real login-cycle test remains unverified.

### 8.6 Internal Reliability — ✔︎ done
- Revision-aware autosave, draft flushing and safe quit/relaunch.
- Automatic validated SQLite backups; no manual backup UI.
- Menu and Settings omit obsolete dock, archive, All Notes and import/export controls.

---

## 9. SQLite Database Schema Reference

The SQL below describes the original HoldMyNotes reference, not SHIORI’s schema. SHIORI stores plain Markdown in `body`; migration `002_soft_delete` adds nullable `deletedAt` without removing legacy data. — ✔︎ done. SHIORI does not implement the reference FTS, tag, encryption or per-note font fields.

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
