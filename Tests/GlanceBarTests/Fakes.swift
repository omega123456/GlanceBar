import AppKit
import ServiceManagement
import Testing
@testable import GlanceBar

/// Every test that swaps the global seams (`Env`, `Feed`, `StatusItem`, …) is nested in this suite, so none run concurrently.
@Suite(.serialized) struct Desktop {}

/// Own notification center (system workspace events never arrive), switchable accessibility display options.
final class FakeWorkspace: NSWorkspace {
    let center = NotificationCenter()
    var contrast = false, solid = false, still = false

    override var notificationCenter: NotificationCenter { center }
    override var accessibilityDisplayShouldIncreaseContrast: Bool { contrast }
    override var accessibilityDisplayShouldReduceTransparency: Bool { solid }
    override var accessibilityDisplayShouldReduceMotion: Bool { still }
}

/// The hover panel's window, never ordered onto a real screen: ordering in and out only flips `shown`.
final class OffscreenPanel: GlancePanel {
    var shown = false
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

/// The `Env` one-shot scheduler, fired by hand: `Harness.advance` moves the fake clock and fires what's due, in order.
final class FakeScheduler {
    final class Item: Cancellable {
        let at: Date
        let tolerance: TimeInterval
        let fire: () -> Void
        var cancelled = false
        init(_ at: Date, _ tolerance: TimeInterval, _ fire: @escaping () -> Void) {
            self.at = at
            self.tolerance = tolerance
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    var items: [Item] = []
    var pending: [Item] { items.filter { !$0.cancelled }.sorted { $0.at < $1.at } }
}

/// Test data in `cswap list --json` (schema v1) and `usage.json` (schema v2) shapes; `example.com` addresses only (NFR-7).
/// The GlanceBar equivalents of the artifact's datasets (Data & State → Test fixtures).
enum Fixture {
    /// 2026-10-04 14:26:00 UTC, the artifact's "Sun 4 Oct 14:26".
    static let now = Date(timeIntervalSince1970: 1_791_123_960)
    static let h: TimeInterval = 3600, d: TimeInterval = 86400

    /// `now + seconds` in cswap's `Z` form without fractional seconds.
    static func z(_ seconds: TimeInterval) -> String { now.addingTimeInterval(seconds).formatted(.iso8601) }

    /// `now + seconds` in cswap's `+00:00` form with microseconds.
    static func micro(_ seconds: TimeInterval) -> String {
        let s = z(seconds)
        return String(s.dropLast()) + ".265379+00:00"
    }

    static func email(_ n: Int) -> String { "person-\(n)@example.com" }

    /// One account row. Windows are (pct, seconds to reset or nil); the 7d window may carry expectedPct.
    static func account(_ n: Int, _ alias: String? = nil, active: Bool = false, status: String = "ok",
                        h5: (Double, TimeInterval?)? = (0, nil), d7: (Double, TimeInterval?, Double?)? = nil,
                        spend: (used: Double, limit: Double, pct: Double)? = nil, scoped: [(String, Double, TimeInterval)] = [],
                        usage: Bool = true, lastGood: Bool = false, age: Double = 180, stamp: (TimeInterval) -> String = z) -> [String: Any] {
        var u: [String: Any] = [:]
        if let h5 {
            var w: [String: Any] = ["pct": h5.0]
            if let r = h5.1 { w["resetsAt"] = stamp(r) }
            u["fiveHour"] = w
        }
        if let d7 {
            var w: [String: Any] = ["pct": d7.0, "countdown": "ignored", "aheadOfPace": true]
            if let r = d7.1 { w["resetsAt"] = stamp(r) }
            if let e = d7.2 { w["expectedPct"] = e }
            u["sevenDay"] = w
        }
        if let spend { u["spend"] = ["used": spend.used, "limit": spend.limit, "pct": spend.pct, "currency": "USD"] }
        if !scoped.isEmpty { u["scoped"] = scoped.map { ["name": $0.0, "pct": $0.1, "resetsAt": stamp($0.2)] } }
        var row: [String: Any] = ["number": n, "email": email(n), "organizationName": "", "active": active, "usageStatus": status,
                                  "usage": NSNull(), "disabled": false]
        if let alias { row["alias"] = alias }
        if usage {
            row["usage"] = u
            row["usageAgeSeconds"] = age
        } else if lastGood {
            row["lastGoodUsage"] = u
            row["lastGoodAgeSeconds"] = age
        }
        return row
    }

    static func list(_ accounts: [[String: Any]], schema: Int = 1) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "activeAccountNumber": 2, "accounts": accounts])
    }

    static let yoursNowRows = [
        account(2, "gm", active: true, d7: (58, 18 * h + 34 * 60, 89)),
        account(3, "hm", d7: (17, 4 * d + 9 * h, 37.5)),
    ]
    static let yoursNow = list(yoursNowRows)
    static let midSession = list([
        account(2, "gm", active: true, h5: (38, 3 * h + 12 * 60), d7: (58, 18 * h + 34 * 60, 89)),
        yoursNowRows[1],
    ])
    static let withDollars = list([
        account(2, "gm", active: true, h5: (100, h + 5 * 60), d7: (81, 18 * h + 34 * 60, 89), spend: (18.40, 50, 36.8)),
        account(3, "hm", d7: (17, 4 * d + 9 * h, 37.5), spend: (0, 50, 0)),
        account(7, "ap", h5: nil, spend: (12.40, 50, 24.8)),
        account(8, "ci", status: "api_key", usage: false),
    ])
    static let fiveAccounts = list(yoursNowRows + [
        account(4, "w1", h5: (74, h + 52 * 60), d7: (92, 2 * d + 4 * h, 69), scoped: [("Fable", 100, 2 * d + 4 * h)]),
        account(5, "w2", status: "relogin_required", usage: false),
        account(6, "w3", h5: (12, 4 * h + 10 * 60), d7: (44, 6 * d + h, 14)),
    ])
    /// The owner's shape: slot 1 spend-capped (no alias, active), slots 2 and 3 subscriptions; both timestamp forms.
    static let ownerShape = list([
        account(1, active: true, h5: nil, spend: (7.34, 1500, 0.4893)),
        account(2, h5: (25, 4 * h + 28 * 60), d7: (61, 18 * h + 8 * 60, 89), stamp: micro),
        account(3, d7: (17, 4 * d + 9 * h, 37.5)),
    ])
    static let transient = list([
        account(2, "gm", active: true, status: "unavailable", h5: (40, 2 * h), d7: (58, 18 * h, 89), usage: false, lastGood: true, age: 5400),
        account(3, "hm", status: "token_expired", d7: (17, 4 * d, 37.5), usage: false, lastGood: true, age: 600),
        account(4, "w1", status: "token_expired", usage: false),
    ])
    static let envelope = try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                                                                       "error": ["type": "ClaudeSwitchError", "message": "No accounts file"]])
    static let schema2 = list(yoursNowRows, schema: 2)
    /// Subscriptions missing a window: the panel still shows both rows (R-17).
    static let noFiveHour = list([account(2, "gm", active: true, h5: nil, d7: (58, 18 * h + 34 * 60, 89))])
    static let noSevenDay = list([account(2, "gm", active: true, h5: (38, 3 * h + 12 * 60))])
    static let zero = list([])

    /// A `usage.json` (schema v2) keyed by slot number; each row gets the fixture's email.
    static func usageFile(_ rows: [Int: [String: Any]]) -> Data {
        var accounts: [String: Any] = [:]
        for (n, r) in rows { accounts[String(n)] = r.merging(["email": email(n)]) { a, _ in a } }
        return try! JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "accounts": accounts])
    }

    static func epoch(_ seconds: TimeInterval) -> Double { now.timeIntervalSince1970 + seconds }
}

/// Installs fresh fakes behind every seam. One per test. Nothing reaches the real cswap, `~/.claude-swap-backup`,
/// the login item, defaults or the network, and no test waits for a timer in real time.
@MainActor
final class Harness {
    let ws = FakeWorkspace()
    let distributed = NotificationCenter()
    let center = NotificationCenter()
    let scheduler = FakeScheduler()
    var now = Fixture.now
    var defaults: UserDefaults
    var terminations = 0
    var locked = false, displaysAsleep = false

    // cswap
    var installed = true
    var launches: [(exe: URL, args: [String], env: [String: String], at: Date)] = []
    var running: [(Int32, Data) -> Void] = []
    var killed = 0
    var launchError: Error?

    // cswap's files: path → contents and identity; directories that exist; open watchers.
    var files: [String: (data: Data, stamp: Feed.Stamp)] = [:]
    var dirs: Set<String>
    var watchers: [String: (Bool) -> Void] = [:]
    var watchOpens: [String] = []
    private var inode: UInt64 = 1000

    var popUps: [NSMenu] = []
    /// Every panel fade (R-20): the window's frame and alpha before it, and the end state it animates to.
    var animations: [(startFrame: CGRect, startAlpha: CGFloat, endFrame: CGRect, endAlpha: CGFloat)] = []
    /// The system appearance the right-click menu gets (System Settings → Appearance).
    var systemAppearance = NSAppearance(named: .aqua)!
    /// The outside-click monitor's handler while one is installed, and how many were installed in total.
    var clickMonitor: (() -> Void)?
    var monitorInstalls = 0
    /// The status item's window and its screen's visible frame (R-19): a 1728 × 1117 display with a 24 pt menu bar.
    var itemFrame = CGRect(x: 1400, y: 1093, width: 120, height: 24)
    var visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1093)
    var loginStatus = SMAppService.Status.notRegistered
    var loginCalls: [String] = []
    var loginError: Error?
    var notices: [String] = []
    var asks: [String] = []
    var relaunches: [URL] = []
    let dir: URL

    var root: URL { dir.appendingPathComponent(".claude-swap-backup") }
    var cache: URL { root.appendingPathComponent("cache") }

    init() {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("GlanceBarTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "local.glancebar.tests")!
        defaults.removePersistentDomain(forName: "local.glancebar.tests")
        dirs = []
        dirs = [root.path, cache.path]

        Env.workspace = ws
        Env.distributed = distributed
        Env.center = center
        Env.defaults = defaults
        Env.terminate = { [unowned self] in terminations += 1 }
        Env.now = { [unowned self] in now }
        Env.schedule = { [unowned self] at, tolerance, fire in
            let item = FakeScheduler.Item(at, tolerance, fire)
            scheduler.items.append(item)
            return item
        }
        Env.isSessionLocked = { [unowned self] in locked }
        Env.displaysAsleep = { [unowned self] in displaysAsleep }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_GB")
        Usage.calendar = utc

        Feed.home = dir
        Feed.locate = { [unowned self] in installed ? URL(fileURLWithPath: "/fake/bin/cswap") : nil }
        Feed.launch = { [unowned self] exe, args, env, done in
            if let launchError { throw launchError }
            launches.append((exe, args, env, now))
            running.append(done)
            return { [unowned self] in killed += 1 }
        }
        Feed.read = { [unowned self] in files[$0.path]?.data }
        Feed.stamp = { [unowned self] in files[$0.path]?.stamp }
        Feed.watch = { [unowned self] dir, event in
            guard dirs.contains(dir.path) else { return nil }
            watchers[dir.path] = event
            watchOpens.append(dir.lastPathComponent)
            return { [unowned self] in watchers[dir.path] = nil }
        }

        StatusItem.showsStatusItem = false
        StatusItem.popUp = { [unowned self] menu, _ in popUps.append(menu) }
        StatusItem.systemAppearance = { [unowned self] in systemAppearance }
        StatusItem.monitorClicks = { [unowned self] handler in
            monitorInstalls += 1
            clickMonitor = handler
            return { [unowned self] in clickMonitor = nil }
        }
        StatusItem.panelClass = OffscreenPanel.self
        StatusItem.anchor = { [unowned self] _ in (itemFrame, visibleFrame) }
        StatusItem.animate = { [unowned self] window, frame, alpha in // recorded, then the fade's end state at once
            animations.append((window.frame, window.alphaValue, frame, alpha))
            window.setFrame(frame, display: false)
            window.alphaValue = alpha
        }
        Style.appearanceOverride = nil
        LaunchAtLogin.service = .init(
            status: { [unowned self] in loginStatus },
            register: { [unowned self] in
                loginCalls.append("register")
                if let loginError { throw loginError }
                loginStatus = .requiresApproval
            },
            unregister: { [unowned self] in loginCalls.append("unregister"); loginStatus = .notRegistered },
            openSettings: { [unowned self] in loginCalls.append("settings") })
        Updater.resume() // clears a pause left by an earlier test
        Updater.isInstallable = false
        Updater.current = "1.0.0"
        Updater.bundleURL = dir.appendingPathComponent("GlanceBar.app")
        Updater.notice = { [unowned self] header, _ in notices.append(header) }
        Updater.ask = { [unowned self] version, _ in asks.append(version) }
        Updater.verify = { _ in }
        Updater.relaunch = { [unowned self] in relaunches.append($0) }
        EventLog.url = dir.appendingPathComponent("events.log")
        EventLog.enable()
    }

    var log: String { (try? String(contentsOf: EventLog.url, encoding: .utf8)) ?? "" }

    /// Moves the fake clock by `seconds`, firing every armed one-shot that comes due, in order.
    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = scheduler.pending.first, next.at <= end {
            now = max(now, next.at)
            next.cancelled = true
            next.fire()
        }
        now = end
    }

    /// Pending one-shots, as seconds from now.
    var armed: [TimeInterval] { scheduler.pending.map { $0.at.timeIntervalSince(now) } }

    /// Completes the oldest running cswap process.
    func finish(_ output: Data = Fixture.yoursNow, status: Int32 = 0) {
        running.removeFirst()(status, output)
    }

    /// Writes a file under `~/.claude-swap-backup` atomically (new inode and mtime), as cswap does.
    func write(_ relative: String, _ data: Data) {
        inode += 1
        let t = now.timeIntervalSince1970
        files[root.appendingPathComponent(relative).path] = (data, Feed.Stamp(inode: inode, seconds: Int(t), nanoseconds: Int((t - t.rounded(.down)) * 1e9)))
    }

    func writeUsage(_ rows: [Int: [String: Any]]) { write("cache/usage.json", Fixture.usageFile(rows)) }

    /// A directory event from the watcher on `~/.claude-swap-backup` (`cache: false`) or its `cache/` folder.
    func event(cache: Bool = true, gone: Bool = false) {
        watchers[(cache ? self.cache : root).path]?(gone)
    }

    var runs: Int { launches.count }

    /// A mouse-down in another app (outside the panel and the status item), as the global monitor sees it.
    func clickOutside() { clickMonitor?() }
}

/// A right/left mouse-up for click routing.
@MainActor
func mouseUp(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// A tracking-area event: mouse-moved at `x` in the status button's coordinates, or entered/exited.
@MainActor
func pointer(_ type: NSEvent.EventType = .mouseMoved, x: CGFloat = 0) -> NSEvent {
    if type == .mouseMoved {
        return NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: x, y: 5), modifierFlags: [], timestamp: 0, windowNumber: 0,
                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }
    return NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                  eventNumber: 0, trackingNumber: 0, userData: nil)!
}

/// Lets main-queue deliveries of real asynchronous work (URLSession, processes) run. Never used for timers: those go
/// through the fake scheduler.
func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }
