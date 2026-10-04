import Foundation

/// `--self-test` (R-25): checks of the pure logic in `Usage` with explicit failure counting (not `assert`, which is
/// compiled out of release builds). Returns false if any check failed.
enum SelfTest {
    private static var total = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failures.append(name) }
    }

    static func run() -> Bool {
        total = 0
        failures = []
        let groups: [(String, () -> Void)] = [
            ("decoding", decoding), ("usage source", usageSource), ("column kinds", columnKinds), ("levels", levels),
            ("time forms", timeForms), ("next label change", nextChange), ("poll schedule", schedule),
            ("real-change filter", realChange), ("throttle", throttle), ("visibility", visibility),
            ("accessibility", accessibility), ("labels", labels), ("pace", pace), ("error copy", errorCopy),
            ("cswap process", process), ("updater", updateVersions),
        ]
        for (name, group) in groups {
            let before = total
            group()
            print("\(name): \(total - before) checks")
        }
        for f in failures { print("FAIL: \(f)") }
        print("self-test: \(total - failures.count)/\(total) checks passed")
        return failures.isEmpty
    }

    // MARK: Fixtures

    /// 2026-10-04 14:26:00 UTC, the artifact's "Sun 4 Oct 14:26".
    private static let now = Date(timeIntervalSince1970: 1_791_123_960)
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    private static func iso(_ seconds: TimeInterval) -> String {
        now.addingTimeInterval(seconds).formatted(.iso8601)
    }

    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private static func list(_ accounts: [[String: Any]]) -> Data {
        json(["schemaVersion": 1, "activeAccountNumber": 2, "accounts": accounts, "futureField": true])
    }

    private static func snapshot(_ accounts: [[String: Any]]) -> Snapshot? {
        if case .success(let s) = Usage.decode(list(accounts), at: now) { return s }
        return nil
    }

    private static func cols(_ accounts: [[String: Any]], at t: Date = now) -> [Column] {
        Usage.columns(snapshot(accounts), failure: nil, now: t, calendar: utc)
    }

    private static func sub(_ n: Int, _ alias: String? = nil, h5: Double = 0, h5r: TimeInterval? = nil, d7: Double = 50,
                            d7r: TimeInterval? = 86400, expected: Double? = nil, status: String = "ok") -> [String: Any] {
        var fiveHour: [String: Any] = ["pct": h5]
        if let h5r { fiveHour["resetsAt"] = iso(h5r) }
        var sevenDay: [String: Any] = ["pct": d7]
        if let d7r { sevenDay["resetsAt"] = iso(d7r) }
        if let expected { sevenDay["expectedPct"] = expected }
        var a: [String: Any] = ["number": n, "email": "person-\(n)@example.com", "active": false, "usageStatus": status,
                                "usage": ["fiveHour": fiveHour, "sevenDay": sevenDay], "usageAgeSeconds": 60]
        if let alias { a["alias"] = alias }
        return a
    }

    private static func kind(_ c: Column?) -> String {
        switch c?.kind {
        case .subscription: "subscription"
        case .spendCap: "spend"
        case .apiKey: "apiKey"
        case .error: "error"
        case nil: "none"
        }
    }

    // MARK: Decoding (R-7, R-11, NFR-7)

    private static func decoding() {
        let micro = Usage.date("2026-10-04T18:20:00.265379+00:00")
        check("timestamp with microseconds and +00:00", micro.map { abs($0.timeIntervalSince1970 - 1_791_138_000.265379) < 0.001 } == true)
        check("timestamp with Z and no fraction", Usage.date("2026-10-04T13:51:46Z")?.timeIntervalSince1970 == 1_791_121_906)
        check("timestamp with an offset", Usage.date("2026-10-04T15:51:46+02:00")?.timeIntervalSince1970 == 1_791_121_906)
        check("unparseable timestamp is nil", Usage.date("soon") == nil && Usage.date(42) == nil)

        let envelope = Usage.decode(json(["schemaVersion": 1, "error": ["type": "ClaudeSwitchError", "message": "boom"]]), at: now)
        check("error envelope is a failed run with its message", envelope == .failure(.failed("boom")))
        check("schemaVersion 2 is unsupported", Usage.decode(json(["schemaVersion": 2, "accounts": []]), at: now) == .failure(.unsupported))
        check("missing schemaVersion is unsupported", Usage.decode(json(["accounts": []]), at: now) == .failure(.unsupported))
        check("not JSON is a failed run", Usage.decode(Data("Traceback".utf8), at: now) == .failure(.failed(Usage.unreadable)))
        check("accounts not a list is a failed run", Usage.decode(json(["schemaVersion": 1, "accounts": 3]), at: now) == .failure(.failed(Usage.unreadable)))
        check("account without a number is a failed run",
              Usage.decode(list([["email": "a@example.com"]]), at: now) == .failure(.failed(Usage.unreadable)))
        check("zero accounts decode", snapshot([])?.accounts.isEmpty == true)

        let minimal = snapshot([["number": 4, "extra": ["x": 1]]])?.accounts.first
        check("missing optionals tolerated", minimal?.email == "" && minimal?.alias == nil && minimal?.active == false
              && minimal?.status == "unavailable" && minimal?.usage == nil)
        var bad = sub(2, h5: 30, h5r: 3600)
        bad["usage"] = ["fiveHour": ["pct": 30, "resetsAt": "tomorrow"], "sevenDay": ["pct": 40]]
        let row = snapshot([bad])?.accounts.first?.usage
        check("unparseable resetsAt → window without reset", row?.fiveHour == UsageWindow(pct: 30, resetsAt: nil, expectedPct: nil))
        check("unparseable resetsAt → 5h idle", cols([bad]).first.map { if case let .subscription(f, _, _, _, _) = $0.kind { f?.compact == "idle" } else { false } } == true)
        check("empty alias is no alias", snapshot([["number": 1, "alias": ""]])?.accounts.first?.alias == nil)
        let spend = snapshot([["number": 1, "usage": ["spend": ["used": 7.34, "limit": 1500, "pct": 0.4893, "currency": "USD"]]]])?
            .accounts.first?.usage?.spend
        check("spend decodes, pct as a percent", spend == Spend(used: 7.34, limit: 1500, pct: 0.4893, currency: "USD", resetsAt: nil))
        let scoped = snapshot([["number": 1, "usage": ["scoped": [["name": "Fable", "pct": 100, "resetsAt": iso(3600)], ["pct": 3]]]]])?
            .accounts.first?.usage?.scoped
        check("scoped rows decode, nameless ones dropped", scoped?.count == 1 && scoped?.first?.name == "Fable")
    }

    // MARK: Usage source (R-9)

    private static func usageSource() {
        let lastGood: [String: Any] = ["sevenDay": ["pct": 40, "resetsAt": iso(7200)]]
        func account(_ status: String, last: Bool) -> Account {
            var r: [String: Any] = ["number": 1, "usageStatus": status, "usage": NSNull()]
            if last { r["lastGoodUsage"] = lastGood; r["lastGoodAgeSeconds"] = 5400 }
            return snapshot([r])!.accounts[0]
        }
        for status in ["ok", "unavailable", "token_expired"] {
            check("\(status): last good usage is the source", Usage.source(account(status, last: true))?.sevenDay?.pct == 40)
        }
        for status in ["relogin_required", "keychain_unavailable", "foreign_credential", "no_credentials", "api_key", "weird"] {
            check("\(status): last good usage ignored", Usage.source(account(status, last: true)) == nil)
        }
        check("usage wins over last good", Usage.source(snapshot([sub(1, d7: 12)])!.accounts[0])?.sevenDay?.pct == 12)
        let c = Usage.columns(snapshot([["number": 1, "usageStatus": "unavailable", "lastGoodUsage": lastGood, "lastGoodAgeSeconds": 5400]]),
                              failure: nil, now: now, calendar: utc)[0]
        check("transient with last good draws bars", kind(c) == "subscription")
        check("last good age is the measurement age", c.measuredAt == now.addingTimeInterval(-5400))
        check("token_expired without last good is an error", kind(cols([["number": 1, "usageStatus": "token_expired"]]).first) == "error")
    }

    // MARK: Column kinds (R-9, R-12)

    private static func columnKinds() {
        check("windows → subscription", kind(cols([sub(1)]).first) == "subscription")
        let cap = cols([["number": 1, "usageStatus": "ok",
                         "usage": ["spend": ["used": 7.34, "limit": 1500, "pct": 0.4893, "currency": "USD"]]]]).first
        check("spend without windows → spend cap", kind(cap) == "spend")
        check("api_key without spend → pill", kind(cols([["number": 8, "usageStatus": "api_key", "usage": NSNull()]]).first) == "apiKey")
        for status in ["relogin_required", "keychain_unavailable", "foreign_credential", "no_credentials", "something_new"] {
            check("\(status) → error", kind(cols([["number": 1, "usageStatus": status]]).first) == "error")
        }
        check("relogin_required with usage is still an error", kind(cols([sub(1, status: "relogin_required")]).first) == "error")
        check("ok with no usage at all → error", kind(cols([["number": 1, "usageStatus": "ok", "usage": NSNull()]]).first) == "error")
        check("ok with empty usage → error", kind(cols([["number": 1, "usageStatus": "ok", "usage": [:]]]).first) == "error")

        if case let .subscription(f, s, extra, _, _) = cols([["number": 1, "usageStatus": "ok",
                                                               "usage": ["sevenDay": ["pct": 10, "resetsAt": iso(3600)],
                                                                         "spend": ["used": 18.4, "limit": 50, "pct": 36.8, "currency": "USD"]]]])[0].kind {
            check("missing 5h window is empty", f == nil && s?.compact == "1h")
            check("extra usage: spent, rounded 37 %", extra?.spent == true && extra?.meter.shown == 37 && extra?.used == "$18.40" && extra?.limit == "$50")
        } else { check("subscription with spend", false) }
        if case let .subscription(_, _, extra, _, _) = cols([["number": 1, "usageStatus": "ok",
                                                              "usage": ["sevenDay": ["pct": 10], "spend": ["used": 0, "limit": 50, "pct": 0, "currency": "USD"]]]])[0].kind {
            check("extra usage at $0: no pie", extra?.spent == false && extra?.used == "$0.00")
        } else { check("subscription with $0 spend", false) }

        check("before the first result: no columns", Usage.columns(nil, failure: nil, now: now).isEmpty)
        for (failure, error) in [(Failure.notFound, "cswap not found"), (.timedOut, "cswap timed out"),
                                 (.unsupported, "Unsupported cswap version"), (.failed("exit code 2"), "cswap failed")] {
            let c = Usage.columns(nil, failure: failure, now: now)
            check("app-wide error: \(error)", c.count == 1 && c[0].label == "cswap" && c[0].kind == .error(Usage.problem(failure: failure))
                  && Usage.problem(failure: failure).error == error)
        }
        let zero = Usage.columns(snapshot([]), failure: nil, now: now)
        check("zero accounts → No accounts yet", zero.first?.kind == .error(Problem(error: "No accounts yet", fix: "Run cswap add in a terminal")))
        let kept = Usage.columns(snapshot([sub(1)]), failure: .timedOut, now: now)
        check("a failure keeps the last good data", kind(kept.first) == "subscription")
        check("a failure after zero accounts shows the failure", Usage.columns(snapshot([]), failure: .timedOut, now: now).first?.kind
              == .error(Usage.problem(failure: .timedOut)))
    }

    // MARK: Levels and rounding (R-10)

    private static func levels() {
        check("89.6 → 90 crit", Usage.shown(89.6) == 90 && Usage.level(Usage.shown(89.6)) == .crit)
        check("89.4 → 89 warn", Usage.shown(89.4) == 89 && Usage.level(89) == .warn)
        check("69.5 → 70 warn (half-up)", Usage.shown(69.5) == 70 && Usage.level(70) == .warn)
        check("69.4 → 69 ok", Usage.level(Usage.shown(69.4)) == .ok)
        check("maxed at 100", Usage.meter(99.5).maxed && !Usage.meter(99.4).maxed)
        let cap = Usage.meter(0.4893)
        check("0.4893 spend → 0 % ok with a non-zero fill", cap.shown == 0 && cap.level == .ok && cap.fraction > 0)
        check("0.4893 spend → minimum-width fill (bar height)", Usage.fillWidth(cap.fraction, width: 16, height: 3.5) == 3.5)
        check("fill width follows the fraction above the minimum", Usage.fillWidth(0.5, width: 22, height: 3.5) == 11)
        check("no fill at 0", Usage.fillWidth(0, width: 22, height: 3.5) == 0)
        check("fill is clamped", Usage.meter(130).fraction == 1 && Usage.meter(-3).fraction == 0)
        check("pace position", Usage.meter(58, pace: 89).pace == 0.89)
        check("money: $7 half-up", Usage.money(7.5, "USD", digits: 0) == "$8" && Usage.money(7.34, "USD", digits: 0) == "$7")
        check("money: $1,500 and $7.34", Usage.money(1500, "USD", digits: 0) == "$1,500" && Usage.money(7.34, "USD") == "$7.34")
        check("currency symbols", Usage.symbol("USD") == "$" && Usage.symbol("EUR") == "€")
        check("spoken money", Usage.spoken(7.34, "USD") == "7 dollars 34" && Usage.spoken(1500, "USD") == "1500 dollars"
              && Usage.spoken(4.2, "EUR") == "4.20 EUR")
    }

    // MARK: Time forms (R-11)

    private static func timeForms() {
        func t(_ seconds: TimeInterval, _ form: Form) -> String { Usage.text(now.addingTimeInterval(seconds), form, now: now, calendar: utc) }
        let h = 3600.0, d = 86400.0
        check("5h 1d3h", t(d + 3 * h + 59, .image5h) == "1d3h")
        check("5h 3h12", t(3 * h + 12 * 60 + 30, .image5h) == "3h12")
        check("5h 1h05", t(h + 5 * 60, .image5h) == "1h05")
        check("5h 52m", t(52 * 60 + 59, .image5h) == "52m")
        check("5h after reset → idle", t(-1, .image5h) == "idle" && t(0, .image5h) == "idle")
        check("7d 4d9h", t(4 * d + 9 * h + 1, .image7d) == "4d9h")
        check("7d 18h", t(18 * h + 34 * 60, .image7d) == "18h")
        check("7d 52m", t(52 * 60, .image7d) == "52m")
        check("7d after reset → 0m", t(-60, .image7d) == "0m")
        check("panel 2d 4h", t(2 * d + 4 * h + 30 * 60, .long) == "2d 4h")
        check("panel 18h 34m", t(18 * h + 34 * 60, .long) == "18h 34m")
        check("panel 1h 5m", t(h + 5 * 60, .long) == "1h 5m")
        check("panel 52m", t(52 * 60, .long) == "52m")
        check("panel after reset → 0m", t(-5, .long) == "0m")
        let nov1 = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01 00:00 UTC
        check("calendar days Oct 4 → Nov 1 = 28", Usage.calendarDays(from: now, to: nov1, calendar: utc) == 28)
        check("days left 28d", Usage.text(nov1, .imageDays, now: now, calendar: utc) == "28d")
        check("days left in the panel", Usage.text(nov1, .longDays, now: now, calendar: utc) == "28d left")
        check("days left under a day: 9h", t(9 * h + 30 * 60, .imageDays) == "9h" && t(9 * h, .longDays) == "9h left")
        check("days left under an hour: 52m", t(52 * 60 + 1, .imageDays) == "52m")
        check("days left after reset", t(-1, .imageDays) == "0m" && t(-1, .longDays) == "0m left")
        check("1 day + 1 h away across two midnights → 2d", t(d + h * 9.6, .imageDays) == "2d") // 14:26 + 33.6 h = Oct 6
        let spend = Spend(used: 1, limit: 2, pct: 50, currency: "USD", resetsAt: nil)
        check("spend reset falls back to the 1st of next month", Usage.spendReset(spend, now: now, calendar: utc) == nov1)
        var given = spend
        given.resetsAt = nov1.addingTimeInterval(3600)
        check("spend reset from cswap", Usage.spendReset(given, now: now, calendar: utc) == nov1.addingTimeInterval(3600))
        check("footer: just now", Usage.footer(measuredAt: now.addingTimeInterval(-59), now: now) == "Updated just now")
        check("footer: 3m ago", Usage.footer(measuredAt: now.addingTimeInterval(-3 * 60 - 59), now: now) == "Updated 3m ago")
        check("footer: 2h ago", Usage.footer(measuredAt: now.addingTimeInterval(-2 * h - 100), now: now) == "Updated 2h ago")
        check("footer: future measurement is just now", Usage.footer(measuredAt: now.addingTimeInterval(30), now: now) == "Updated just now")
        let clock5h = Usage.clock(now.addingTimeInterval(4 * h + 53 * 60), withDay: false, calendar: utc)
        check("5h clock is the time only", clock5h == "19:19")
        let clock7d = Usage.clock(now.addingTimeInterval(18 * h + 34 * 60), withDay: true, calendar: utc)
        check("7d clock: locale date, a space, locale time; no connector", clock7d == "5 Oct 09:00")
        var us = utc
        us.locale = Locale(identifier: "en_US")
        let clockUS = Usage.clock(now.addingTimeInterval(18 * h + 34 * 60), withDay: true, calendar: us)
        check("7d clock in en_US: month first, 12 h", clockUS.replacingOccurrences(of: "\u{202F}", with: " ") == "Oct 5 9:00 AM")
        check("5h clock in en_US: time only", Usage.clock(now.addingTimeInterval(4 * h + 53 * 60), withDay: false, calendar: us)
              .replacingOccurrences(of: "\u{202F}", with: " ") == "7:19 PM")

        // After the 5h reset passes: idle at 0 % until new data; 7d keeps its percent and shows 0m.
        let later = now.addingTimeInterval(2 * h)
        if case let .subscription(f, s, _, _, _) = cols([sub(1, h5: 40, h5r: h, d7: 61, d7r: h)], at: later)[0].kind {
            check("5h after reset: idle at 0 %", f?.meter.shown == 0 && f?.compact == "idle" && f?.long == Usage.fiveHourIdle && f?.target == nil)
            check("7d after reset: keeps 61 %, 0m", s?.meter.shown == 61 && s?.compact == "0m" && s?.long == "0m")
        } else { check("after-reset columns", false) }
        if case let .subscription(f, _, _, _, _) = cols([sub(1, h5: 0.4, h5r: h)])[0].kind {
            check("5h at displayed 0 % is idle", f?.compact == "idle")
        } else { check("idle column", false) }
    }

    // MARK: Next label change (R-13)

    private static func nextChange() {
        func next(_ seconds: TimeInterval, _ form: Form, at t: Date = now) -> TimeInterval? {
            Usage.nextChange([Countdown(target: now.addingTimeInterval(seconds), form: form)], now: t, calendar: utc)?.timeIntervalSince(t)
        }
        func near(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { a.map { abs($0 - b) < 0.01 } == true }
        check("minute form: next minute boundary", near(next(52 * 60 + 30, .image5h), 30))
        check("exact boundary: changes right after", near(next(52 * 60, .image5h), 0))
        check("7d hour form: next hour boundary", near(next(18 * 3600 + 34 * 60, .image7d), 34 * 60))
        check("7d below an hour: minutes", near(next(30 * 60 + 10, .image7d), 10))
        check("5h day form: hour steps", near(next(86400 + 3 * 3600 + 120, .image5h), 120))
        check("last minute: at the reset", near(next(45, .long), 45))
        check("passed: nothing", next(-1, .image7d) == nil)
        check("days form: next midnight", near(next(28 * 86400, .imageDays), 9 * 3600 + 34 * 60)) // 14:26 → 24:00
        check("days form: switch to hours", near(next(86400 + 600, .imageDays), 600))
        let target = now.addingTimeInterval(3 * 3600 + 12 * 60 + 30)
        if let n = Usage.nextChange([Countdown(target: target, form: .image5h)], now: now) {
            check("text differs at the next change", Usage.text(target, .image5h, now: n) != Usage.text(target, .image5h, now: now))
            check("text unchanged just before", Usage.text(target, .image5h, now: n.addingTimeInterval(-0.01)) == Usage.text(target, .image5h, now: now))
        } else { check("next change exists", false) }
        let born = now.addingTimeInterval(-90)
        check("age: next minute", Usage.nextChange([], ages: [born], now: now) == now.addingTimeInterval(30))
        check("age under a minute: at 60 s", Usage.nextChange([], ages: [now], now: now) == now.addingTimeInterval(60))
        check("age over an hour: hourly", Usage.nextChange([], ages: [now.addingTimeInterval(-3700)], now: now) == now.addingTimeInterval(3500))
        check("earliest of several", near(Usage.nextChange([Countdown(target: now.addingTimeInterval(7200 + 5), form: .image7d),
                                                           Countdown(target: now.addingTimeInterval(65), form: .image5h)],
                                                          now: now).map { $0.timeIntervalSince(now) }, 5))
        check("nothing visible: nil", Usage.nextChange([], now: now) == nil)
        let image = Usage.imageCountdowns(cols([sub(1, h5: 30, h5r: 600, d7: 10, d7r: 7200),
                                                ["number": 2, "usageStatus": "api_key"]]))
        check("image countdowns: 5h and 7d", image.map(\.form) == [.image5h, .image7d])
        let panelCols = cols([sub(1, h5: 30, h5r: 600, d7: 10, d7r: 7200),
                              ["number": 2, "usageStatus": "ok", "usage": ["sevenDay": ["pct": 5, "resetsAt": iso(900)],
                                                                          "scoped": [["name": "Fable", "pct": 100, "resetsAt": iso(1200)]],
                                                                          "spend": ["used": 1, "limit": 50, "pct": 2, "currency": "USD"]]],
                              ["number": 3, "usageStatus": "ok", "usage": ["spend": ["used": 1, "limit": 50, "pct": 2, "currency": "USD"]]],
                              ["number": 4, "usageStatus": "relogin_required"]])
        let panel = Usage.panelCountdowns(panelCols)
        check("panel countdowns: 5h, 7d, per-model long forms; spend cap days left; no extra-usage clock",
              panel.map(\.form) == [.long, .long, .long, .long, .longDays]
              && panel.prefix(4).map { $0.target.timeIntervalSince(now) } == [600, 7200, 900, 1200])
        check("panel countdowns skip idle 5h", Usage.panelCountdowns(cols([sub(1, d7r: 7200)])).count == 1)
        check("footer measurement: the oldest shown", Usage.oldestMeasurement(Usage.columns(snapshot([sub(1), {
            var r = sub(2); r["usageAgeSeconds"] = 600; return r }()]), failure: nil, now: now, calendar: utc)) == now.addingTimeInterval(-600))
        check("footer measurement: none for errors", Usage.oldestMeasurement(Usage.columns(nil, failure: .notFound, now: now)) == nil)
        check("reset instants passed since the last render", Usage.passedResets([now, now.addingTimeInterval(10), now.addingTimeInterval(-10)],
                                                                                 from: now.addingTimeInterval(-5), to: now.addingTimeInterval(10))
              == [now, now.addingTimeInterval(10)])
        check("first render reports no resets", Usage.passedResets([now], from: nil, to: now).isEmpty)
    }

    // MARK: Poll schedule (R-4)

    private static func schedule() {
        let t = now.timeIntervalSince1970
        let snap = snapshot([sub(1), sub(2), sub(3, status: "relogin_required"), ["number": 4, "email": "k@example.com", "usageStatus": "api_key"]])
        func row(_ n: Int, _ fetched: Double?, next: Double? = nil, backoff: Double? = nil, claim: Double? = nil, dead: Int = 0) -> PollRow {
            PollRow(email: "person-\(n)@example.com", fetchedAt: fetched, nextPollAt: next, backoffUntil: backoff, claimUntil: claim, authDeadStrikes: dead)
        }
        func due(_ r: PollRow) -> TimeInterval { Usage.due(r, now: now).timeIntervalSince1970 - t }
        check("due: nextPollAt", due(row(1, t - 200, next: t + 300)) == 300)
        check("due: fresh row waits for the 180 s TTL", due(row(1, t - 20, next: t + 40)) == 160) // 60 s urgent plan inside 180 s
        check("due: backoff wins over a past nextPollAt", due(row(1, t - 900, next: t - 100, backoff: t + 500)) == 500)
        check("due: claim wins", due(row(1, t - 900, next: t + 10, claim: t + 90)) == 90)
        check("due: no plan → fetchedAt + 180", due(row(1, t - 100)) == 80)
        check("due: never fetched → now", due(row(1, nil)) == 0)

        let rows: [Int: PollRow] = [1: row(1, t, next: t + 400), 2: row(2, t, next: t + 300),
                                    3: row(3, t, next: t + 30), 4: PollRow(email: "k@example.com", nextPollAt: t + 30),
                                    9: row(9, nil), 5: row(5, t - 1000, next: t - 5, dead: 1)]
        check("dues skip relogin, api_key, unknown slot, dead token", Usage.dues(rows, snapshot: snap, now: now).map { $0.timeIntervalSince1970 - t }.sorted() == [300, 400])
        var mismatched = rows
        mismatched[2]?.email = "someone-else@example.com"
        check("dues skip a slot whose email changed", Usage.dues(mismatched, snapshot: snap, now: now).count == 1)
        check("no snapshot: nothing due", Usage.dues(rows, snapshot: nil, now: now).isEmpty)
        check("poll fires at earliest due + 10 s", Usage.pollFire(rows, snapshot: snap, lastRun: now, now: now) == now.addingTimeInterval(310))
        check("60 s floor", Usage.pollFire([1: row(1, t - 175)], snapshot: snap, lastRun: now, now: now) == now.addingTimeInterval(60))
        check("nothing in the future → last run + 180 s", Usage.pollFire([1: row(1, t - 1000)], snapshot: snap, lastRun: now, now: now) == now.addingTimeInterval(180))
        check("unusable usage.json → last run + 180 s", Usage.pollFire(nil, snapshot: snap, lastRun: now, now: now) == now.addingTimeInterval(180))
        check("fallback never in the past", Usage.pollFire(nil, snapshot: snap, lastRun: now, now: now.addingTimeInterval(500)) > now.addingTimeInterval(500))
        let skippedOnly: [Int: PollRow] = [3: row(3, t - 1000), 4: PollRow(email: "k@example.com", fetchedAt: t - 1000)]
        let late = now.addingTimeInterval(500) // a poll fire after the fallback window, nothing due: 180 s more, never 1 s
        check("re-arm after the fallback window waits 180 s", Usage.pollFire(skippedOnly, snapshot: snap, lastRun: now, now: late) == late.addingTimeInterval(180))
        check("re-arm with no snapshot waits 180 s", Usage.pollFire(rows, snapshot: nil, lastRun: now, now: late) == late.addingTimeInterval(180))
        check("anything due: past due row", Usage.anythingDue([1: row(1, t - 1000)], snapshot: snap, failed: false, now: now))
        check("anything due: nothing yet", !Usage.anythingDue(rows, snapshot: snap, failed: false, now: now))
        check("anything due: only skipped accounts → nothing", !Usage.anythingDue(skippedOnly, snapshot: snap, failed: false, now: late))
        check("anything due: unusable file counts as due", Usage.anythingDue(nil, snapshot: snap, failed: false, now: now))
        check("anything due: no snapshot counts as due", Usage.anythingDue(rows, snapshot: nil, failed: false, now: now))
        check("anything due: a failed last run counts as due", Usage.anythingDue(rows, snapshot: snap, failed: true, now: now))

        let v2: [String: Any] = ["schemaVersion": 2, "accounts": ["1": ["email": "person-1@example.com", "fetchedAt": t, "nextPollAt": t + 300,
                                                                       "backoffUntil": NSNull(), "claimUntil": 0, "authDeadStrikes": 2, "lastGood": [:]],
                                                                 "x": [:], "2": "nope"]]
        check("usage.json v2 rows", Usage.pollRows(json(v2)) == [1: PollRow(email: "person-1@example.com", fetchedAt: t, nextPollAt: t + 300,
                                                                          backoffUntil: nil, claimUntil: 0, authDeadStrikes: 2)])
        check("usage.json other schema → fallback", Usage.pollRows(json(["schemaVersion": 3, "accounts": [:]])) == nil)
        check("usage.json missing or unreadable → fallback", Usage.pollRows(nil) == nil && Usage.pollRows(Data("{".utf8)) == nil)
    }

    // MARK: Real-change filter (R-3.4)

    private static func realChange() {
        let base: [Int: PollRow] = [1: PollRow(email: "a@example.com", fetchedAt: 100), 2: PollRow(email: "b@example.com", fetchedAt: 200)]
        var claim = base
        claim[1]?.claimUntil = 400
        check("claim-only write is no change", !Usage.hasNewerFetch(claim, than: base))
        var newer = base
        newer[2]?.fetchedAt = 260
        check("newer fetchedAt is a change", Usage.hasNewerFetch(newer, than: base))
        check("same content is no change", !Usage.hasNewerFetch(base, than: base))
        check("new slot with a fetch is a change", Usage.hasNewerFetch([3: PollRow(email: "c@example.com", fetchedAt: 1)], than: base))
        check("slot with another email is a change", Usage.hasNewerFetch([1: PollRow(email: "z@example.com", fetchedAt: 50)], than: base))
        check("never-fetched row is no change", !Usage.hasNewerFetch([3: PollRow(email: "c@example.com")], than: base))
        check("no baseline: any fetch is a change", Usage.hasNewerFetch(base, than: nil))
        check("unreadable file is no change", !Usage.hasNewerFetch(nil, than: base))
    }

    // MARK: Throttle (R-3.6)

    private static func throttle() {
        check("panel open refreshes after 30 s", Usage.refreshOnOpen(lastRun: now.addingTimeInterval(-31), now: now))
        check("panel open within 30 s: no refresh", !Usage.refreshOnOpen(lastRun: now.addingTimeInterval(-30), now: now))
        check("panel open before any run refreshes", Usage.refreshOnOpen(lastRun: nil, now: now))
    }

    // MARK: Visibility (R-6)

    private static func visibility() {
        check("visible when all hold", Usage.isVisible(awake: true, displaysAwake: true, sessionActive: true, unlocked: true))
        check("asleep", !Usage.isVisible(awake: false, displaysAwake: true, sessionActive: true, unlocked: true))
        check("displays asleep (DarkWake)", !Usage.isVisible(awake: true, displaysAwake: false, sessionActive: true, unlocked: true))
        check("session resigned", !Usage.isVisible(awake: true, displaysAwake: true, sessionActive: false, unlocked: true))
        check("locked", !Usage.isVisible(awake: true, displaysAwake: true, sessionActive: true, unlocked: false))
        check("launch: visible", Usage.visibleAtLaunch(locked: false, displaysAsleep: false))
        check("launch: locked", !Usage.visibleAtLaunch(locked: true, displaysAsleep: false))
        check("launch: displays asleep", !Usage.visibleAtLaunch(locked: false, displaysAsleep: true))
    }

    // MARK: Accessibility (R-14)

    private static func accessibility() {
        var two = sub(2, h5: 25, h5r: 4 * 3600 + 28 * 60, d7: 61, d7r: 18 * 3600 + 8 * 60)
        two["active"] = true
        let one: [String: Any] = ["number": 1, "usageStatus": "ok",
                                  "usage": ["spend": ["used": 7.34, "limit": 1500, "pct": 0.4893, "currency": "USD"]]]
        let summary = Usage.summary(cols([two, one, ["number": 8, "alias": "ci", "usageStatus": "api_key"],
                                          ["number": 5, "alias": "w2", "usageStatus": "relogin_required"], sub(3, d7r: nil)]))
        check("summary reads every account", summary == "2: 5 hour 25 percent, resets in 4h 28m; 7 day 61 percent, resets in 18h 8m. "
              + "1: spend 7 dollars 34 of 1500 dollars, resets in 28 days. ci: API key (no quota). w2: Re-login needed. "
              + "3: 5 hour 0 percent, idle; 7 day 50 percent.")
        check("summary of an app-wide error", Usage.summary(Usage.columns(nil, failure: .notFound, now: now)) == "cswap: cswap not found.")
        check("summary before data", Usage.summary([]) == "GlanceBar")
        var extra = sub(4, h5: 10, h5r: 600)
        extra["usage"] = ["fiveHour": ["pct": 10, "resetsAt": iso(600)], "spend": ["used": 18.4, "limit": 50, "pct": 36.8, "currency": "USD"]]
        check("extra usage is read", cols([extra])[0].speech == "4: 5 hour 10 percent, resets in 10m; extra usage 18 dollars 40 of 50 dollars")
        let soon: [String: Any] = ["number": 1, "usageStatus": "ok",
                                   "usage": ["spend": ["used": 1, "limit": 10, "pct": 10, "currency": "USD", "resetsAt": iso(9 * 3600)]]]
        check("spend reset under a day", cols([soon])[0].speech == "1: spend 1 dollars of 10 dollars, resets in 9h 0m")
    }

    // MARK: Labels and chips (R-8, R-17)

    private static func labels() {
        var a = sub(2, "gm")
        a["active"] = true
        let c = cols([a, sub(3), ["number": 8, "alias": "ci", "usageStatus": "api_key"]])
        check("alias label", c[0].label == "gm")
        check("slot number when no alias", c[1].label == "3")
        check("active chip and flag", c[0].chip == "active" && c[0].active && !c[1].active)
        check("slot chip", c[1].chip == "slot 3")
        check("API key chip", c[2].chip == "API key")
        check("email carried", c[1].email == "person-3@example.com")
        check("order kept", c.map(\.number) == [2, 3, 8])
    }

    // MARK: Pace (R-17)

    private static func pace() {
        func line(_ d7: Double, _ expected: Double?) -> Pace? {
            if case let .subscription(_, _, _, _, p) = cols([sub(1, d7: d7, expected: expected)])[0].kind { return p }
            return nil
        }
        check("under pace", line(58, 89)?.text == "Week: 31 pts under pace" && line(58, 89)?.ahead == false)
        check("ahead of pace", line(92, 69)?.text == "Week: 23 pts ahead of pace" && line(92, 69)?.ahead == true)
        check("on pace reads 0 pts under", line(40, 40)?.text == "Week: 0 pts under pace")
        check("same rounded, expected lower: 0 pts under", line(58, 57.6)?.text == "Week: 0 pts under pace" && line(58, 57.6)?.ahead == false)
        check("same rounded, expected higher: 0 pts under", line(57.6, 57.9)?.text == "Week: 0 pts under pace")
        check("ahead by one rounded point", line(58.4, 56.6)?.text == "Week: 1 pts ahead of pace" && line(58.4, 56.6)?.ahead == true)
        check("difference rounded, not expectedPct", line(17, 37.5)?.text == "Week: 20 pts under pace" && line(17, 37.5)?.ahead == false)
        check("+0.5 rounds up to ahead", line(58, 57.5)?.text == "Week: 1 pts ahead of pace" && line(58, 57.5)?.ahead == true)
        check("-0.5 rounds up to 0 under", line(58, 58.5)?.text == "Week: 0 pts under pace")
        check("no expectedPct: no pace line", line(50, nil) == nil)
        // The panel always shows both windows (R-17).
        let rows = cols([sub(1, d7: 58, expected: 89)])
        if case let .subscription(f, d, _, _, _) = rows[0].kind {
            check("both present: unchanged", Usage.panelWindows(fiveHour: f, sevenDay: d) == [f!, d!])
        }
        let none = Usage.panelWindows(fiveHour: nil, sevenDay: nil)
        check("missing 5h reads idle", none[0].name == "5h" && none[0].meter.shown == 0 && none[0].long == Usage.fiveHourIdle
              && none[0].percent && none[0].target == nil)
        check("missing 7d: empty, no percent, time or pace", none[1].name == "7d" && none[1].meter.fraction == 0
              && none[1].meter.pace == nil && !none[1].percent && none[1].long.isEmpty && none[1].clock == nil)
        check("pace tick from expectedPct", { if case let .subscription(_, s, _, _, _) = cols([sub(1, d7: 58, expected: 89)])[0].kind { s?.meter.pace == 0.89 } else { false } }())
    }

    // MARK: Error copy

    private static func errorCopy() {
        check("token expired", Usage.problem(status: "token_expired") == Problem(error: "Token expired", fix: "refresh deferred this pass; retries automatically"))
        check("re-login", Usage.problem(status: "relogin_required") == Problem(error: "Re-login needed", fix: "refresh token dead; log in with Claude Code, then run: cswap add"))
        check("keychain", Usage.problem(status: "keychain_unavailable") == Problem(error: "Keychain unavailable", fix: "locked or in use; try again"))
        check("foreign credential", Usage.problem(status: "foreign_credential") == Problem(error: "Live credential belongs to another account", fix: "a switch repairs it"))
        check("no credentials", Usage.problem(status: "no_credentials") == Problem(error: "No credentials", fix: "log in with Claude Code, then run: cswap add"))
        for status in ["unavailable", "ok", "brand_new"] {
            check("\(status) → usage unavailable", Usage.problem(status: status) == Problem(error: "Usage unavailable", fix: "cswap will retry at its next poll"))
        }
        check("cswap not found", Usage.problem(failure: .notFound) == Problem(error: "cswap not found", fix: "Install claude-swap: uv tool install claude-swap"))
        check("cswap failed", Usage.problem(failure: .failed("exit code 1")) == Problem(error: "cswap failed", fix: "exit code 1"))
        check("timeout", Usage.problem(failure: .timedOut) == Problem(error: "cswap timed out", fix: "It will be retried at the next refresh"))
        check("unsupported", Usage.problem(failure: .unsupported) == Problem(error: "Unsupported cswap version", fix: "Update GlanceBar or cswap"))
        check("no accounts", Usage.problem(failure: nil) == Problem(error: "No accounts yet", fix: "Run cswap add in a terminal"))
        let api = cols([["number": 8, "usageStatus": "api_key"]])[0]
        check("API key accounts are not errors", api.kind == .apiKey(symbol: "$") && api.speech.hasSuffix("API key (no quota)"))
    }

    // MARK: cswap process (R-1, R-2)

    private static func process() {
        let home = "/Users/x"
        check("lookup order", Usage.cswapCandidates(home: home) == ["/Users/x/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"])
        check("first executable wins", Usage.locate(home: home) { $0 != "/Users/x/.local/bin/cswap" } == "/opt/homebrew/bin/cswap")
        check("none found", Usage.locate(home: home) { _ in false } == nil)
        let env = Usage.environment(home: home, lang: "en_GB.UTF-8")
        check("fixed environment, no CLAUDE_CONFIG_DIR", env == ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_GB.UTF-8"])
        check("LANG only when the app has one", Usage.environment(home: home, lang: nil)["LANG"] == nil)
    }

    // MARK: Updater

    private static func updateVersions() {
        check("update: 1.0.10 is newer than 1.0.9", Updater.isNewer("1.0.10", than: "1.0.9"))
        check("update: v-prefixed tag is newer", Updater.isNewer("v1.1.0", than: "1.0.0"))
        check("update: 1.0 equals 1.0.0", !Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("1.0.0", than: "1.0"))
        check("update: older is not newer", !Updater.isNewer("1.9.9", than: "2.0.0"))
    }
}
