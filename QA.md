# SHIORI desktop QA

Manual QA was run on 2026-09-22 against the final frozen debug artifact:

- App: `build/Build/Products/Debug/SHIORI.app`
- macOS: 26.6.2 (25G83), Apple silicon
- Xcode: 26.4 (17E192), Swift 6.3, deployment target macOS 14
- GRDB: 7.8.0, revision `18497b68fdbb3a09528d260a0a0e1e7e61c8c53d`
- Automated command: `xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution -destination 'platform=macOS' test`
- Automated result: exit 0, 21 tests, 0 failures (`build/Logs/Test/Test-SHIORI-2026.09.22_00-05-11-+0000.xcresult`)

The stable manual run used `open --env` with:

- Data: `/tmp/shiori-qa-final-isolated`
- Defaults suite: `app.shiori.qa.final`

The isolated database began with three seeded notes. It ended with five notes,
two pinned, and the expected active order after the reorder check. The latest
explicit backup reopened successfully and contained five notes and two pinned
rows.

## Manual acceptance

| Check | Result | Evidence |
| --- | --- | --- |
| A. Launch | Pass | The actual `.app` launched with a menu-bar item, no conventional main window, and a small right-edge dock. |
| B. Foreground focus | Partial | The dock is a non-key panel and remained available while another app was active. A true pointer-only hover while typing in another app was not completed; the available CUA surface did not provide a pointer-move action. |
| C. Deck preview | Pass via menu; hover unverified | `Show/Hide Deck` revealed the overlapping pastel card cascade, timestamps, previews, pin indicators, and `+` action. Pointer hover lift/focus was not separately verified. |
| D. Create/edit | Pass | Menu `New Note` created a UUID-backed note, focused the title, Return moved focus into the body, and title/body/color changes persisted. Native macOS `paste` was used for Unicode text. |
| E. Close/reopen | Pass | Closing returned the editor to the deck; reopening showed the saved title, multilingual body, checklist markers, and Sky blue color. |
| F. Pinning | Pass | Two notes were independently pinned. Their DB rows had `pinned=1`; distinct window frames were present in the isolated defaults suite. |
| G. Quit/relaunch | Pass | The isolated instance quit normally with no remaining SHIORI process. Relaunching the same app with `SHIORI_DATA_DIR=/tmp/shiori-qa-final-isolated` and `SHIORI_DEFAULTS_SUITE=app.shiori.qa.final` restored the latest QA Note and Second QA text, their saved order (`QA Note` first, `Second QA` fifth), and their distinct saved frames (`{{1430, 684}, {360, 400}}` and `{{1122, 510}, {360, 400}}`). Both rows were `pinned=1` before the final normal quit, which also completed cleanly. |
| H. Complete/archive/restore | Pass | Completing archived `QA Note`, set both `doneAt` and `archivedAt`, checked unfinished non-fenced tasks, left the fenced task unchanged, and removed the editor. Restore returned it to Active, cleared archive/done state, kept checked markers, and left it unpinned. |
| I. Reorder | Pass | Dragging `Second QA` moved it to the bottom; SQLite order became `QA Note`, `A little room to think`, `Today`, `Quelques idées`, `Second QA`. |
| J. Backup | Pass | `Back Up Now` created a new snapshot. Reopening the latest snapshot with SQLite returned five notes and two pinned rows. |
| K. Spaces/full-screen | Partial | Settings showed across-Spaces on and full-screen overlay off by default. The full-screen toggle changed and restored successfully. Actual Spaces/full-screen behavior was not manually verified. |
| L. Stress/multi-monitor | Unverified | No 100-note or multi-monitor/sleep-wake run was completed. |

## Additional observations

- Search `cafe` matched the seeded `café` text, confirming case/diacritic-insensitive matching in All Notes.
- The native checklist checkbox toggled the first task at its rendered hit area. Command-Z restored the original Markdown marker.
- The body preserved French accents, Arabic text, Unicode punctuation, and fenced-code content.
- The explicit isolated backup directory retained the earlier automatic snapshot and the manual snapshot; no failed snapshot was observed.
- A first CUA rebinding occurred while the binary was being replaced during an earlier build. That launch used the default environment and created demo/QA rows under `~/Library/Application Support/app.shiori.desktop`. Those files were preserved and never reset. All subsequent QA used the verified `open --env` isolated launch above.
