# GlanceBar

The usage of every Claude account managed by `cswap` (claude-swap), at a glance in the macOS 26 menu bar on Apple Silicon:

- **The glance:** one menu bar item with a column per account: its alias (or slot number), a 5-hour bar, a 7-day bar with a pace tick, and the two reset countdowns as tiny text. A dot under the label marks the active account. Bars turn amber at 70 % and red at 90 %.
- **Dollars only where there's money:** a small pie after the countdowns when a subscription is spending extra usage; a `$` bar against the cap (with days left) for spend-capped accounts such as Enterprise; an outlined `$` pill for API-key accounts with no data.
- **Problems:** a broken account shows hatched bars and a red `!`; if cswap itself is missing or failing, a single `cswap` column does.
- **Right-click / ⌃-click** opens GlanceBar's own menu (Launch at Login, Automatic Updates, Check for Updates…, Quit).

GlanceBar is **read-only**: it never switches, adds or removes accounts and never talks to Anthropic. Its only external command is `cswap list --json`; cswap remains the place for account actions. It is a menu bar agent app with no Dock icon, built for a minimal footprint: it does nothing while the Mac sleeps, the displays are off or the screen is locked, and at most refreshes when cswap would actually fetch new data. It is for personal use only: self-signed, not sandboxed, not notarized.

Requirements: Swift 6.3 Command Line Tools (Xcode only for the tests) and the macOS 26 SDK; `cswap` installed (`uv tool install claude-swap`), found at `~/.local/bin/cswap`, `/opt/homebrew/bin/cswap` or `/usr/local/bin/cswap`.

## One-time setup (per Mac)

1. **Create the signing identity.** Run this in **Terminal.app**, not through Claude Code:
   ```sh
   ./scripts/make-cert.sh
   ```
   It creates the self-signed "GlanceBar Local Signing" code-signing identity in your login keychain. It asks for your login keychain password (hidden input) and shows a system dialog to trust the certificate. The updater only installs downloads signed with this same identity. The script is safe to re-run: it exits if the identity already exists. Check the result with:
   ```sh
   security find-identity -v -p codesigning
   ```
2. **Install cswap** and add your accounts (`cswap add`). Optionally give them short aliases (`cswap alias 2 gm`) to get compact labels; GlanceBar picks changes up by itself.

## Build, install and run

Production GlanceBar is installed from the release DMG into `/Applications/GlanceBar.app` and updates itself (see [Releases and updates](#releases-and-updates)). A local build is a separate development copy, **GlanceBar Dev**, so testing never touches production:

```sh
./scripts/build-app.sh
```

The script does the following:
1. Builds in debug mode. Debug builds compile in the dev-only behaviour: no update checks, a "DEV" label at the left of the menu bar item, a version row in the menu, and the event log in its own `GlanceBar Dev` folder.
2. Assembles `.build/GlanceBar Dev.app` with bundle ID `local.glancebar.dev` and executable `GlanceBarDev`, and signs it with "GlanceBar Local Signing". Settings and Launch at Login are kept separately from production, because they belong to the bundle ID.
3. Quits any running GlanceBar, production included, because two copies would both run cswap.
4. Installs the app to `~/Applications/GlanceBar Dev.app` and removes the build copy, so only one bundle with ID `local.glancebar.dev` exists.
5. Launches the app.

Any extra arguments are passed on to the app, for example `./scripts/build-app.sh --log-events`. `BUNDLE_ONLY=1 ./scripts/build-app.sh` builds and signs the production bundle `.build/GlanceBar.app` without installing it (the release workflow uses this).

To go back to production:

```sh
pkill -x GlanceBarDev; open /Applications/GlanceBar.app
```

Always launch the installed app (with the script, or with `open`), not the binary from a terminal.

To run the self-test of the pure logic (it exits before any UI, and a failure gives a non-zero exit status):

```sh
swift run GlanceBar --self-test
```

The snapshot and behaviour tests need Xcode (its license accepted): `./scripts/test.sh`; with the coverage gate: `./scripts/coverage.sh`.

## Usage

- **Read the bars.** Per account: label, then the 5h bar (top) and 7d bar (bottom), then the 5h countdown (or `idle` when the 5-hour window hasn't started) and the 7d countdown. The tick on the 7d bar is where usage would be if spread evenly over the week: a fill past the tick means you're burning the week faster than time passes. Countdowns read `3h12` (3 h 12 min), `18h`, `4d9h`, `52m`.
- **Spend caps.** An account with a monthly spend cap and no windows shows `$`, a bar against the cap, the amount spent (`$7`) and the days until the cap resets (`28d`).
- **Hover for the details.** Rest the pointer on the item for a moment (300 ms) and a panel drops down under it: per account the label, email and a chip (`active`, `slot N` or `API key`), then the 5h and 7d rows with exact percent, time left and reset clock, extra-usage or spend-cap `$` rows, per-model limits, the week's pace, or what broke and the command that fixes it; the footer says how old the data is. Sweeping across the menu bar doesn't open it. Moving the pointer over a column highlights that account in the menu bar item and in the panel. You can move the pointer into the panel; it closes 400 ms after the pointer leaves the item or the panel, when you click anywhere outside it and the status item, or on a Space change. (Noticing that outside click is the one global mouse monitor GlanceBar uses, and only while the panel is open.) It never takes the keyboard from the app you're using. Opening it refreshes the data if the last refresh is more than 30 s old.
- **Left click** toggles the same panel.
- **Right-click or ⌃-click** for the app menu: **Launch at Login**, **Automatic Updates**, **Check for Updates…**, **Quit GlanceBar**.
- **VoiceOver** reads the whole summary of every account from the menu bar item, and each account block in the panel as one group.
- **Accessibility settings:** with Reduce Motion the panel appears and disappears without the fade; with Reduce Transparency it is solid; with Increase Contrast dim text, tracks and borders are stronger.

GlanceBar refreshes at launch, when cswap's account list changes (switch, alias, add, remove), when another cswap surface (`cswap watch`, `cswap menubar`) fetched new usage, when cswap would next agree to fetch an account (never more often than once a minute), when a shown reset time passes, and once 5 s after the Mac wakes or unlocks. When a refresh fails, the last good numbers stay.

## Known limitations

- **No Esc** to close the panel (by design).
- **The notch:** with 4 or more accounts the item can be wider than the space left of the notch, and macOS hides it. There is no compact mode.
- **macOS 27 betas 2–4** drop hover events to status items, so the panel won't open on hover there (fixed in beta 5); clicking still works.
- **The active dot** shows the login of the default Claude Code profile (`~/.claude.json`), which is what `cswap list` reports. Sessions started with `cswap run` don't move it. A `/login` inside Claude Code changes the active account without touching cswap's files, so the dot follows at the next refresh.

## Releases and updates

GlanceBar checks GitHub Releases (`omega123456/GlanceBar`, which must be public) at launch and then every hour while the Mac is in use. When a newer version exists, it asks whether to update now. If you accept, it downloads the zip and installs it over the running copy, but only if the download is signed with the same "GlanceBar Local Signing" certificate. Then it relaunches. The menu has **Automatic Updates** and **Check for Updates…**. Dev builds never update.

To publish a release, run this in Terminal.app with a clean working tree:

```sh
./scripts/release.sh
```

It bumps the version in `Info.plist`, writes the release notes to `.github/release-body.md`, runs a release build and the self-test, commits, tags `vX.Y.Z` and pushes. The tag triggers `.github/workflows/release.yml`, which builds on `macos-26`, signs with the same identity and attaches `GlanceBar-X.Y.Z.dmg` (manual install: open it and drag GlanceBar to Applications) and `GlanceBar-X.Y.Z.zip` (used by the updater) to the release. The app is self-signed, so the first launch from a downloaded DMG is blocked by Gatekeeper: allow it once in System Settings → Privacy & Security → **Open Anyway**. A nightly workflow keeps only the newest 5 releases.

One-time repository setup:
1. Create the public repository `omega123456/GlanceBar` and set it as `origin`.
2. In Keychain Access, export "GlanceBar Local Signing" (certificate and private key) as a `.p12`. Then:
   ```sh
   base64 -i GlanceBar.p12 | gh secret set APPLE_CERTIFICATE
   gh secret set APPLE_CERTIFICATE_PASSWORD   # the .p12 export password
   gh secret set KEYCHAIN_PASSWORD            # any random string (temporary CI keychain)
   gh secret set RELEASE_CLEANUP_TOKEN        # token with contents: write, for the cleanup workflow
   ```
   The workflow pins the certificate's SHA-1, so a different certificate fails the release.

## Event log (diagnostics)

Launch with `--log-events` to append millisecond-timestamped plain-text lines to:

```
~/Library/Logs/GlanceBar/events.log        # production
~/Library/Logs/GlanceBar Dev/events.log    # GlanceBar Dev
```

The file is cleared at each launch and removed when the app starts without the flag. It records every cswap run (trigger, duration, exit status, account count), watcher events acted on and skipped, poll timer arms and skips, countdown timer arms (`countdown: armed in N s`), visibility changes, image updates and updater activity. To read it:

```sh
./scripts/build-app.sh --log-events
tail -f ~/Library/Logs/GlanceBar\ Dev/events.log
```

The log is a file rather than the unified log because the Claude Code sandbox blocks `/usr/bin/log`.

## Claude Code sandbox note

SwiftPM only works outside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package`, `./scripts/build-app.sh`, `./scripts/test.sh` and `./scripts/coverage.sh` from the sandbox. The exclusion only applies when the whole command is one of these, so don't pipe or chain them (no `|`, `&&` or `cd … &&`). `make-cert.sh` is interactive, so run it in Terminal.app.
