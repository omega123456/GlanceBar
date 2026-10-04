# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

GlanceBar shows the usage of every Claude account managed by `cswap` (claude-swap, `~/.local/bin/cswap`) in the macOS 26 menu bar on Apple Silicon: one status item with a column per account (alias, 5h bar, 7d bar with a pace tick, reset countdowns; `$` columns for spend caps and API keys; hatched red `!` for broken accounts). Resting the pointer on it for 300 ms, or a left click, opens the hover panel with the details (a non-activating panel that never takes the keyboard); right-click / ⌃-click opens GlanceBar's own app menu. It is **read-only**: its only external command is `cswap list --json`; it never switches accounts and never talks to Anthropic. It is an `LSUIElement` menu bar agent (`local.glancebar`) for personal use: self-signed, not sandboxed, not notarized. It is a single SwiftPM executable target that uses system frameworks only (never SwiftUI), built with the Swift 6.3 Command Line Tools. The only dependency is swift-snapshot-testing, used by the test target alone; tests run with Xcode's toolchain via `scripts/test.sh`. `Package.swift` pins Swift language mode v5.

## Commands

```sh
swift build                                 # debug build (compile check)
swift run GlanceBar --self-test             # pure-logic checks; exits before any UI, non-zero on failure
./scripts/test.sh                           # snapshot + behaviour tests + SelfTest (Tests/GlanceBarTests), offscreen; extra args go to swift test (--filter …)
./scripts/coverage.sh                       # test.sh with LLVM line coverage of Sources/GlanceBar; fails below COVERAGE_MIN (default 90); COVERAGE_HTML=1 → .build/xcode/coverage/index.html
./scripts/build-app.sh                      # debug "GlanceBar Dev" build → sign → quit running copies (prod too) → install to ~/Applications → launch
./scripts/build-app.sh --log-events         # extra args are passed to the app
BUNDLE_ONLY=1 ./scripts/build-app.sh        # signed production bundle .build/GlanceBar.app, not installed (CI)
tail -f ~/Library/Logs/GlanceBar\ Dev/events.log
pkill -x GlanceBarDev; open /Applications/GlanceBar.app   # back to production
./scripts/release.sh                        # (owner runs it) bump Info.plist version, verify, commit, tag vX.Y.Z, push → .github/workflows/release.yml
```

- **Sandbox:** SwiftPM fails inside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package`, `./scripts/build-app.sh`, `./scripts/test.sh` and `./scripts/coverage.sh`, but only when the command is exactly one of these. Don't pipe, chain or prefix them (`|`, `&&`, `cd … &&`). `BUNDLE_ONLY=1 ./scripts/build-app.sh` is not exempt (the env prefix): inside the sandbox it reports the signing identity as missing, so run it with the sandbox disabled. The sandbox also blocks cswap's lock file, so `cswap list --json` fails inside it (GlanceBar itself is not sandboxed).
- **App icon:** `scripts/make-icon.swift` draws `Resources/AppIcon.icns` (committed; plan → App icon, Concept A). Build it inside the sandbox, run it with the sandbox disabled (`iconutil` silently fails inside it):
  ```sh
  swiftc -module-cache-path "$TMPDIR/mc" scripts/make-icon.swift -o "$TMPDIR/make-icon"
  "$TMPDIR/make-icon"     # sandbox disabled; pass the sandbox's TMPDIR if it differs
  ```
- **Two suites.** `--self-test` covers the pure logic and needs only the CLT. To add a logic check, add a `check(...)` in `Sources/GlanceBar/SelfTest.swift`. It counts failures explicitly, because `assert` is compiled out of release builds. `Tests/GlanceBarTests/SelfTests.swift` also runs it under `swift test`, so coverage counts it. `SelfTest.swift` itself is excluded from the coverage total.
- **Tests** (`Tests/GlanceBarTests`, Swift Testing + swift-snapshot-testing) never touch the real desktop, the real cswap, real files under `~/.claude-swap-backup`, the login item, real defaults or the network, and never wait for a timer in real time.
  - **Toolchain:** the library imports XCTest, which only Xcode ships. So `scripts/test.sh` runs `swift test` with `DEVELOPER_DIR` set to Xcode and its own `.build/xcode` scratch path. `xcode-select` stays on the CLT (6.3) for app builds. Xcode's license must be accepted (sudo), so the owner runs that.
  - **Seams (DD-11):** everything outside the app goes through a replaceable static: `Env` (workspace, distributed and default notification centres, defaults, terminate, the clock `now`, which also stamps EventLog lines, the one-shot scheduler `schedule`, the launch-time lock and display-sleep queries) in `App.swift`; `Feed.home/locate/launch/watch/read/stamp`; `StatusItem.showsStatusItem/popUp/panelClass/anchor/animate/systemAppearance/monitorClicks` (panel window class; the item's window frame and its screen's visible frame; the panel's 120 ms frame + alpha animation, applied at once in tests; the system appearance the right-click menu gets; the outside-click global monitor, faked as `h.clickMonitor`/`h.clickOutside()`); `Style.appearanceOverride`; `Usage.calendar`; `LaunchAtLogin.service`; `EventLog.url`; and the `Updater` closures and `session`. Production never changes them. New code that reaches the system (a new AppKit global, a process, a file, a timer) adds a seam and fakes it in `Harness` (`Fakes.swift`), which installs fresh fakes for every test.
  - **Time:** every timer and delay goes through `Env.at`/`Env.after` (one-shot, tolerance 10 % of the wait capped at 5 s, common run-loop modes). The only exception is the production hourly update check. Tests move the fake clock with `h.advance(seconds)`, which fires due one-shots in order; `h.armed` lists the pending ones.
  - **Harness:** a fake cswap (`h.launches`, `h.finish(output, status:)`, `h.installed`, `h.killed`), an in-memory `~/.claude-swap-backup` (`h.write`, `h.writeUsage` give each write a new inode + mtime like cswap's atomic renames; `h.event(cache:gone:)` delivers a directory event; `h.dirs` says which directories exist), a UTC/en_GB calendar, fake workspace (Increase Contrast / Reduce Transparency / Reduce Motion: `h.ws.contrast/solid/still`), its own notification centres, a `local.glancebar.tests` defaults suite, a captured right-click menu (`h.popUps`), an `OffscreenPanel` that is never ordered onto a real screen (ordering only flips `shown`), a fixed item/screen geometry for placement (`h.itemFrame`, `h.visibleFrame`) and a temp `events.log`. Fixtures (`Fixture.yoursNow`, `midSession`, `withDollars`, `fiveAccounts`, `ownerShape`, `transient`, `envelope`, `schema2`, `zero`) mirror the artifact's datasets with `example.com` addresses only (NFR-7) — never put the owner's real emails anywhere. Assert on behaviour through `h.log` (EventLog lines), `h.runs`, `h.armed` and the feed's state.
  - **Pitfalls:** never `performClick` (its tracking loop can end the run loop Swift Testing drains on, which exits the run silently with status 0); call `StatusItem.handle(_:)` with a synthetic event, or send the menu item's action. Hover is driven the same way: send `pointer(.mouseEntered/.mouseExited)` or `pointer(x:)` (mouse-moved, button coordinates) to `item.itemTracker` / `item.panelTracker` (the tracking areas' owners), then `h.advance` past the 300 ms open / 400 ms close delays; the fade's order-out is an `Env.after(0.12)` one-shot. Don't let a test's feed hold its StatusItem strongly (`feed.onChange = { [weak item] in item?.update() }`): a leaked item outlives its Harness and later reaches the dead fakes. `NSMenu` only draws while tracking on a real display, so the menu is snapshotted as a text outline. Real-process and real-watcher tests use `/bin/sh`, `/bin/sleep` and temp folders, never cswap.
  - **Snapshots:** `SnapshotTests` renders the status image (`StatusImage.<case>.png`) by drawing `Glance.image()` (the production drawing-handler path) into a 2x bitmap over a fixed menu-bar backdrop, compared at `precision: 0.99, perceptualPrecision: 0.98`. The appearance is pinned through `Style.appearanceOverride`. The hover panel is `Panel.<case>.png`: `PanelView.show` (the production views, the box only: the native window shadow isn't part of the view) drawn with `cacheDisplay` at 2x over a flat wallpaper colour (the menu-material blur doesn't render offscreen, so the panel tint shows over the backdrop). The matrix:
    - both: every fixture and app-wide error (yoursNow, midSession, withDollars, fiveAccounts, ownerShape, transient, cswapMissing, envelope, schema2, timeout, zeroAccounts) in dark and light;
    - status image: dark Increase Contrast for the six account fixtures and cswapMissing, light Increase Contrast for yoursNow and fiveAccounts, the open-panel highlight with a hot column for withDollars, fiveAccounts (also light) and ownerShape, and yoursNow without the DEV label;
    - panel: dark Increase Contrast for yoursNow, withDollars and fiveAccounts, light Increase Contrast for fiveAccounts, Reduce Transparency for yoursNow (also light) and fiveAccounts, hovered blocks for fiveAccounts (error block, also light; first block) and ownerShape, and the missing-window accounts (noFiveHour, noSevenDay) in dark only.
    The right-click menu is `Menu.<case>.txt`. To add a state, add a `Case` and its setup. System fonts are inherent, so references are tied to the macOS version.
  - **Re-recording:** the first run of a new case records its PNG and reports a failure. Delete a PNG to re-record it, then always check the new image by eye against the offline artifact before committing.
  - **Coverage:** `scripts/coverage.sh` gates on 90 % lines of all `Sources/GlanceBar`. What stays uncovered is the real system call inside each seam, the CFUserNotification prompt and `main()`.
  - **CI:** tests aren't run there yet; the references were recorded on the owner's Mac and may differ on the `macos-26` runner.
- **Dev vs production (R-26):** production is `/Applications/GlanceBar.app` (`local.glancebar`, from the DMG, self-updating). `build-app.sh` builds **GlanceBar Dev**: a debug build with bundle ID `local.glancebar.dev` and executable `GlanceBarDev`, so UserDefaults and the login item are separate. `#if DEBUG` gates the dev behaviour: no updater, its own log folder (`GlanceBar Dev`), the "DEV" label drawn at the image's left edge and the disabled version row in the menu.
- **Never run the binary directly** (`.build/.../GlanceBar`) for real use; launch the installed app with the script or `open ~/Applications/GlanceBar\ Dev.app`.
- `scripts/make-cert.sh` is interactive (keychain password, trust dialog). The owner runs it in Terminal.app, not you. It creates the "GlanceBar Local Signing" identity (DD-13), which the updater checks every download against.
- `--log-events` writes to a file because the sandbox blocks `/usr/bin/log`. The log holds account counts and trigger names, no emails.

## Architecture

All work runs on the main thread and is event-driven, except the cswap process, which runs on a background queue and delivers its output back to the main thread. The data flows one way:

```
 NSWorkspace / distributed notifications        DispatchSource (2 directories)      one-shot timers (Env)
 (sleep, displays, session, lock)                     │ usage.json / sequence.json         │ poll · countdown · debounce · resume · timeout
            │                                         ▼                                     │
            └──────────────►  Visibility gate  ──►  Feed  ◄─────────────────────────────────┘
                              (App.swift)          (Feed.swift)
                                                    │ decides "run?" (pure rules in Usage.swift)
                                                    │ runs `cswap list --json` off-main, single flight, 20 s timeout
                                                    ▼
                                         Snapshot (pure value, Usage.swift)
                                                    │
                                                    ▼
                                      Column model (Usage.columns) ──► Glance value + drawing (Render.swift)
                                                    │
                                                    ▼
            StatusItem.swift: NSStatusItem · appearance KVO · image-on-change · a11y label · countdown timer ·
                              R-3.7 reset triggers · right-click menu · tracking areas (item, panel) · hover delays ·
                              click toggle · GlancePanel + PanelView value (Render.swift) · placement · fade

 AppDelegate: wiring · visibility gate · redraw triggers · LaunchAtLogin · Updater · EventLog
```

Cross-cutting rules that need several files to see:

- **cswap is the only data engine (DD-1):** only `cswap list --json` (schema v1) is run, with the fixed minimal environment (no `CLAUDE_CONFIG_DIR`). Every displayed value comes from it. cswap's private `~/.claude-swap-backup/cache/usage.json` (schema v2) is read only for scheduling and change detection (`email`, `fetchedAt`, `nextPollAt`, `backoffUntil`, `claimUntil`, `authDeadStrikes`) and degrades to a 180 s fallback if its format changes.
- **Event-driven hybrid ingest (DD-2, R-3–R-5):** directory watchers (debounced 1 s, file identity compared first, `fetchedAt` newer than GlanceBar's own last read) plus one poll timer at cswap's own fetch eligibility (+10 s, never < 60 s after the last run). Watcher decisions made while a run is in flight are deferred until after it, so a fetch GlanceBar's own run caused never causes a second run.
- **Visibility gate (DD-3, R-6, NFR-2):** asleep, displays asleep, session resigned or screen locked pauses everything (timers cancelled, watchers closed, no runs); return redraws at once, re-baselines without acting, and does one run 5 s later (with a missed update check).
- **All decision logic lives in `Usage.swift`** as `static func`s and value types (decoding, column kinds, levels, time forms, next label change, poll schedule, real-change filter, throttle, visibility, error copy, accessibility summary, the panel's long-form strings, pace line and footer) so `SelfTest` covers it without UI. **Escalation:** if a rule is missing or wrong, stop and report it to the owner; never put decision rules in view, StatusItem or Feed code. Phase 2 must not modify `Usage.swift` or `Feed.swift`.
- **One timer per purpose, one-shot, tolerant (DD-4, NFR-1):** poll, countdown (next visible label change), debounce, resume delay, run timeout, hover delays (300 ms open, 400 ms close; armed only while hovering), the fade's 120 ms order-out. No repeating timers except the production hourly update check. No polling loops, no AX, no global event monitors, with one scoped exception (owner deviation from NFR-1, ADR `2026-10-04--global-mouse-down-monitor-only-while-the-hover-panel-is-open-closes-it-on-outside-clicks--ba2fbb06.md`): a global left/right/other mouse-down monitor installed only while the hover panel is open (removed on every close path) closes it on a click outside the panel and the status item.
- **Redraw only on change, drawn per appearance (DD-5, R-13):** `Glance` is a pure value of what the image shows (incl. the `Style`); the image is rebuilt and reassigned only when it changes. The image is a non-template drawing-handler image that resolves the colour tokens from the drawing appearance at draw time.
- **Visuals (DD-7, DD-9, DD-14):** literal artifact colour tokens per menu-bar appearance in `Style` (`Render.swift`), Increase Contrast raises dim/track/sep (`dim` is 0.80 / 0.78 alpha, 0.92 with Increase Contrast: owner deviation for the see-through macOS 26 bar); Reduce Transparency makes the panel solid. The open-panel highlight, the hovered column's hot rect and the Dev "DEV" label are drawn into the image (the button's own highlight API is never used), so column extents map 1:1 to button coordinates. The image's text is ~1.4× the artifact's (owner deviation: labels and "DEV" 13 pt, `!` 12.5 pt, countdowns and spend texts 11 pt, the spend `$` 11 pt, the API-key pill's `$` 12 pt in a 28 × 15 pill) with the vertical metrics re-derived in `Glance` (bars at y 4.75 and 13.75, the active dot at y 20.3). The panel's fonts are the artifact's. The right-click menu alone takes the system appearance (`StatusItem.systemAppearance`), not the menu bar's.
- **Click model (DD-10):** the status item never holds a permanent `menu`; right-click/⌃-click pops up the menu built on open; left click toggles the panel (a click while hover has it open closes it); right-click closes the panel first.
- **Hover panel (R-15–R-21, DD-6, DD-8, DD-12):** `GlancePanel` is a borderless, non-activating `NSPanel` (never key or main, level `.popUpMenu`, all Spaces, full-screen auxiliary, ignores cycling). Its content is `PanelView`, rebuilt only when the pure `Panel` value changes (columns, footer, hot block, `Style` from the panel's own appearance); it uses only `Usage` strings and rules (the footer row is hidden when `Usage.oldestMeasurement` is nil). Both tracking areas are `.activeAlways`, enter/exit + mouse-moved, `.inVisibleRect`; the only global monitor is the outside-click one while open (`StatusItem.monitorClicks`). While open, the one countdown timer also covers `Usage.panelCountdowns` and the footer age (R-21); every open calls `Feed.panelOpened()` (30 s throttle). It closes on a Space change, a screen-parameter change, a click outside (normal fade) and pause; the 120 ms fade + 4 pt slide is skipped under Reduce Motion and on those closes. The window is exactly the box and uses the native window shadow (`hasShadow`), which never catches clicks, so a click beside or below the box reaches the app underneath and closes the panel through the outside-click monitor.
- Code comments cite "R-N", "NFR-N" and "DD-N". These refer to `.agent/plans/2026-10-04_glancebar_plan.md`, which holds the full spec, the wireframes, the owner's deviations from the artifact and the reasons behind the constants. The approved design is `.agent/plans/assets/2026-10-04_glancebar_plan-artifact.html`; where the plan's text and the artifact differ, the artifact wins except for the owner's deviations.

## Architectural decisions (binding)

`.agent/adr/` is an append-only decision ledger, governed by `.agent/ADR_POLICY.md`. Never edit or delete an existing ADR. To reverse one, write a new ADR with a `## Relationship to previous decisions` section. The decisions below are recorded there (the plan's Notes list them); read the relevant ADR before you change:
- frameworks, the dependency policy or the test toolchain (AppKit only, no runtime dependencies, test-only swift-snapshot-testing on Xcode's toolchain)
- the data engine and ingest (cswap only via `cswap list --json`, event-driven hybrid ingest, visibility pause)
- the panel technology and motion (native views, the artifact's 120 ms fade overriding FancyMacZones' no-animation rule)
- the signing identity

## Verifying behaviour

Acceptance criteria are tagged **[agent]** (builds, `--self-test`, tests, file contents, `codesign`/`plutil` output, `--log-events` lines read from the log file) or **[owner]** (live UI, menu bar on light and dark displays, sleep/lock, Activity Monitor, `pmset`, VoiceOver, macOS settings).

- The owner keeps using the desktop while agents work. Don't run any cswap command other than `cswap list --json`, and never write under `~/.claude-swap-backup`.
- `open`, `pgrep`, `top`, `screencapture` and `/usr/bin/log` need the sandbox disabled, which auto mode may deny; report such checks as not verified rather than forcing them.
