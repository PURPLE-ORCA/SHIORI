# SHIORI development rules

## Do not make test windows look like broken startup

The repeated temporary note opening/closing reported on September 22, 2026 came from app-hosted XCTest cases manipulating real desktop windows before relaunch. One recurrence explicitly passed `SHIORI_RUN_WINDOW_TESTS=1`; two new window tests also lacked the guard. A normal relaunch was observed with stable edge panels. Do not assume every future flicker has this cause: inspect running processes and the actual test command first.

- Never enable `SHIORI_RUN_WINDOW_TESTS=1` unless the user explicitly requests desktop-interactive tests for the current task. Ordinary requests to run tests, build, or relaunch do not authorize visible desktop tests.
- Use `SHIORI_RUN_WINDOW_TESTS=0` explicitly for routine verification. Report skipped tests accurately; do not claim the full interactive suite passed.
- Every test that orders windows on screen, restores pinned notes, opens editors/search, or exercises controllers that display panels must start with the existing `XCTSkipUnless` environment guard, before constructing those controllers. Audit new tests for this requirement.
- Keep test databases and preferences isolated from real SHIORI data.
- Wait for testing to finish before launching the real app. Do not run desktop tests alongside the user's app.
- Relaunch only the normal built app at `build/Build/Products/Debug/SHIORI.app`, after a graceful quit has completed. Confirm its process path and that only one normal SHIORI process is running. Do not launch a test-host build from temporary DerivedData.
- Do not delete user data, preferences, or arbitrary build folders to treat flicker without identifying its cause.

Routine verification:

```sh
xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath /tmp/shiori-font-build SHIORI_RUN_WINDOW_TESTS=0 test
xcodebuild -project SHIORI.xcodeproj -scheme SHIORI -configuration Debug -derivedDataPath build build
```
