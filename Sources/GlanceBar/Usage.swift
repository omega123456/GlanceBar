import Foundation

// Pure model and every decision rule (plan: Architecture → Usage.swift). No AppKit, no I/O, no timers: callers pass
// the data, `now` and the calendar, so `SelfTest` covers all of it without UI.

// MARK: - cswap list --json (schema v1), decoded (Data & State → consumed fields)

struct UsageWindow: Equatable {
    var pct: Double
    var resetsAt: Date?        // nil when missing or unparseable (R-7)
    var expectedPct: Double?   // 7d only
}

struct ScopedWindow: Equatable {
    var name: String
    var pct: Double
    var resetsAt: Date?
}

struct Spend: Equatable {
    var used: Double
    var limit: Double
    var pct: Double            // already a percent (0–100), as cswap reports it
    var currency: String
    var resetsAt: Date?
}

struct UsageData: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var spend: Spend?
    var scoped: [ScopedWindow] = []
}

struct Account: Equatable {
    var number: Int
    var email: String
    var alias: String?
    var active: Bool
    var status: String
    var usage: UsageData?
    var usageAge: Double?
    var lastGood: UsageData?
    var lastGoodAge: Double?
}

/// One successful run's data, stamped with when GlanceBar received it (ages advance from there).
struct Snapshot: Equatable {
    var accounts: [Account]
    var receivedAt: Date
}

/// A failed run (R-7). A zero-account snapshot is a success that shows "No accounts yet" (R-12).
enum Failure: Error, Equatable {
    case notFound
    case failed(String)
    case timedOut
    case unsupported
}

// MARK: - Display model (R-8–R-12, R-17)

enum Level: Equatable { case ok, warn, crit }

/// A bar: raw fill fraction (width), displayed percent (text, level, maxed) and the 7d pace position.
struct Meter: Equatable {
    var fraction: Double
    var shown: Int
    var pace: Double? = nil
    var level: Level { Usage.level(shown) }
    var maxed: Bool { shown >= 100 }
}

/// A 5h, 7d or per-model row. `target` is the countdown instant while the row counts down (nil when idle or no reset).
struct WindowRow: Equatable {
    var name: String
    var meter: Meter
    var compact: String        // image text: "3h12", "idle", "18h", "0m"
    var long: String           // panel time left: "3h 12m", "2d 4h", "0m", "idle, starts with your next message"
    var clock: String?         // panel clock: 5h time, 7d month day time; nil for per-model rows and idle
    var target: Date?
    var percent = true         // false: the panel draws no percent text (a missing 7d window, R-17)
}

/// Extra usage on a subscription, or a spend-capped account (R-9).
struct SpendRow: Equatable {
    var symbol: String         // "$" (USD) or the currency's symbol
    var meter: Meter
    var spent: Bool            // used > 0: the extra-usage pie is drawn
    var whole: String          // image top text, whole units rounded half-up: "$7"
    var daysLeft: String       // image bottom text: "28d", "9h", "52m", "0m"
    var used: String           // panel: "$7.34"
    var limit: String          // panel: "$1,500"
    var detail: String         // panel: "28d left" (spend cap) or the reset clock "Nov 1 00:00" (extra usage)
    var spoken: String         // R-14: "7 dollars 34 of 1500 dollars"
    var target: Date           // spend.resetsAt, else the 1st of next month at local midnight
}

struct Problem: Equatable {
    var error: String
    var fix: String
}

/// R-17 pace line: "Week: N pts ahead of pace" (warn) / "Week: N pts under pace" (dim).
struct Pace: Equatable {
    var points: Int
    var ahead: Bool
    var text: String { "Week: \(points) pts \(ahead ? "ahead of" : "under") pace" }
}

struct Column: Equatable {
    enum Kind: Equatable {
        case subscription(fiveHour: WindowRow?, sevenDay: WindowRow?, extra: SpendRow?, scoped: [WindowRow], pace: Pace?)
        case spendCap(SpendRow)
        case apiKey(symbol: String)
        case error(Problem)
    }

    var number: Int
    var label: String          // alias, else the slot number; "cswap" for the app-wide error (R-12)
    var email: String
    var active: Bool
    var chip: String           // "active", "slot N", "API key" (R-17)
    var kind: Kind
    var measuredAt: Date?      // when the displayed measurement was taken (footer age, R-17)
    var speech: String         // accessibility phrase (R-14)
}

// MARK: - usage.json (cswap schema v2): scheduling and change detection only (DD-1, R-4)

struct PollRow: Equatable {
    var email: String?
    var fetchedAt: Double?
    var nextPollAt: Double?
    var backoffUntil: Double?
    var claimUntil: Double?
    var authDeadStrikes = 0
}

/// Which time form a countdown label uses (R-11).
enum Form: Equatable {
    case image5h, image7d, imageDays, long, longDays
}

struct Countdown: Equatable {
    var target: Date
    var form: Form
}

enum Usage {
    /// The calendar for clocks and calendar days (locale, time zone, 12/24 h). Tests pin it.
    static var calendar = Calendar.autoupdatingCurrent

    static let unreadable = "Unreadable output from cswap list --json"
    static let fiveHourIdle = "idle, starts with your next message"
    static let apiKeyLine = "API key (no quota)"   // cswap's wording (deviation 5)

    // MARK: Decoding (R-7, NFR-7)

    private static let isoFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// cswap's timestamps: with or without fractional seconds, `Z` or a `±hh:mm` offset (R-11). Nil if unparseable.
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return (try? isoFormat.parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    private static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any], let pct = number(d["pct"]) else { return nil }
        return UsageWindow(pct: pct, resetsAt: date(d["resetsAt"]), expectedPct: number(d["expectedPct"]))
    }

    private static func usageData(_ any: Any?) -> UsageData? {
        guard let d = any as? [String: Any] else { return nil }
        var spend: Spend?
        if let s = d["spend"] as? [String: Any], let used = number(s["used"]), let limit = number(s["limit"]) {
            spend = Spend(used: used, limit: limit, pct: number(s["pct"]) ?? (limit > 0 ? used / limit * 100 : 0),
                          currency: s["currency"] as? String ?? "USD", resetsAt: date(s["resetsAt"]))
        }
        let scoped = (d["scoped"] as? [[String: Any]] ?? []).compactMap { s -> ScopedWindow? in
            guard let name = s["name"] as? String, let pct = number(s["pct"]) else { return nil }
            return ScopedWindow(name: name, pct: pct, resetsAt: date(s["resetsAt"]))
        }
        return UsageData(fiveHour: window(d["fiveHour"]), sevenDay: window(d["sevenDay"]), spend: spend, scoped: scoped)
    }

    /// Decodes `cswap list --json` output. Missing optionals and unknown fields are tolerated; anything else that
    /// doesn't fit is a failed run, never a crash.
    static func decode(_ data: Data, at now: Date) -> Result<Snapshot, Failure> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.failed(unreadable)) }
        guard number(root["schemaVersion"]) == 1 else { return .failure(.unsupported) }
        if let error = root["error"] as? [String: Any] {
            return .failure(.failed(error["message"] as? String ?? error["type"] as? String ?? "Unknown error"))
        }
        guard let rows = root["accounts"] as? [[String: Any]] else { return .failure(.failed(unreadable)) }
        var accounts: [Account] = []
        for r in rows {
            guard let n = number(r["number"]) else { return .failure(.failed(unreadable)) }
            let alias = (r["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            accounts.append(Account(number: Int(n), email: r["email"] as? String ?? "", alias: alias,
                                    active: r["active"] as? Bool ?? false, status: r["usageStatus"] as? String ?? "unavailable",
                                    usage: usageData(r["usage"]), usageAge: number(r["usageAgeSeconds"]),
                                    lastGood: usageData(r["lastGoodUsage"]), lastGoodAge: number(r["lastGoodAgeSeconds"])))
        }
        return .success(Snapshot(accounts: accounts, receivedAt: now))
    }

    // MARK: Usage source and column kinds (R-9)

    /// Transient statuses keep showing the last good measurement (owner decision, deviation 8).
    static let transient: Set = ["ok", "unavailable", "token_expired"]
    static let errorStatuses: Set = ["relogin_required", "keychain_unavailable", "foreign_credential", "no_credentials"]
    static let knownStatuses = transient.union(errorStatuses).union(["api_key"])

    /// `usage` when present, else `lastGoodUsage` for transient statuses.
    static func source(_ a: Account) -> UsageData? {
        a.usage ?? (transient.contains(a.status) ? a.lastGood : nil)
    }

    // MARK: Levels and rounding (R-10)

    /// Rounded half-up to a whole number.
    static func shown(_ pct: Double) -> Int { Int((pct + 0.5).rounded(.down)) }

    static func level(_ shown: Int) -> Level { shown >= 90 ? .crit : shown >= 70 ? .warn : .ok }

    static func meter(_ pct: Double, pace: Double? = nil) -> Meter {
        Meter(fraction: min(max(pct, 0), 100) / 100, shown: shown(pct), pace: pace.map { min(max($0, 0), 100) / 100 })
    }

    /// A bar's fill width: never narrower than the bar's height while the raw fraction is > 0; 0 when empty (R-10).
    static func fillWidth(_ fraction: Double, width: Double, height: Double) -> Double {
        fraction > 0 ? max(height, width * fraction) : 0
    }

    // MARK: Time forms (R-11)

    /// The label for `target` at `now`, from the floored seconds left. After the reset passes: "idle" (image 5h),
    /// "0m left" (panel spend) or "0m".
    static func text(_ target: Date, _ form: Form, now: Date, calendar: Calendar = calendar) -> String {
        let r = Int(target.timeIntervalSince(now).rounded(.down))
        if r <= 0 { return form == .image5h ? "idle" : form == .longDays ? "0m left" : "0m" }
        let d = r / 86400, h = r % 86400 / 3600, m = r % 3600 / 60
        switch form {
        case .image5h: return d > 0 ? "\(d)d\(h)h" : h > 0 ? "\(h)h" + (m < 10 ? "0\(m)" : "\(m)") : "\(m)m"
        case .image7d: return d > 0 ? "\(d)d\(h)h" : h > 0 ? "\(h)h" : "\(m)m"
        case .long: return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
        case .imageDays, .longDays:
            let s = r >= 86400 ? "\(calendarDays(from: now, to: target, calendar: calendar))d" : h > 0 ? "\(h)h" : "\(m)m"
            return form == .longDays ? s + " left" : s
        }
    }

    /// Calendar-day difference between the two dates' local days (Oct 4 → Nov 1 = 28).
    static func calendarDays(from now: Date, to target: Date, calendar: Calendar = calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
    }

    /// The spend cap's reset: cswap's `resetsAt`, else the 1st of next month at local midnight.
    static func spendReset(_ spend: Spend, now: Date, calendar: Calendar = calendar) -> Date {
        if let r = spend.resetsAt { return r }
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        return calendar.date(byAdding: .month, value: 1, to: month) ?? now
    }

    /// Locale clocks: 5h the time only, 7d and extra usage month and day, a space, then the time ("5 Oct 09:00",
    /// "Oct 5 9:00 AM"). The two parts are formatted separately so no locale connector ("at") lengthens the row.
    static func clock(_ date: Date, withDay: Bool, calendar: Calendar = calendar) -> String {
        func part(_ template: String) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = calendar.locale ?? .autoupdatingCurrent
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        return withDay ? part("MMMd") + " " + part("jmm") : part("jmm")
    }

    /// Footer (R-17): from the oldest displayed measurement.
    static func footer(measuredAt: Date, now: Date) -> String {
        let age = max(now.timeIntervalSince(measuredAt), 0)
        if age < 60 { return "Updated just now" }
        return age < 3600 ? "Updated \(Int(age / 60))m ago" : "Updated \(Int(age / 3600))h ago"
    }

    /// The next instant any of these labels changes text (R-13): countdowns, plus footer ages measured from
    /// `ages`. Nil when nothing will change. Countdown labels change just after a step boundary, ages at it.
    static func nextChange(_ labels: [Countdown], ages: [Date] = [], now: Date, calendar: Calendar = calendar) -> Date? {
        var next: [Date] = []
        for l in labels {
            let r = l.target.timeIntervalSince(now)
            guard r > 0 else { continue } // passed: stays "0m"/"idle" until new data
            if (l.form == .imageDays || l.form == .longDays) && r >= 86400 { // calendar days: midnight, or the switch to hours
                let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
                next.append(min(midnight, l.target.addingTimeInterval(-86400)).addingTimeInterval(0.001))
                continue
            }
            let step: Double = switch l.form {
            case .image7d: r >= 3600 ? 3600 : 60
            case .image5h, .long: r >= 86400 ? 3600 : 60
            case .imageDays, .longDays: r >= 3600 ? 3600 : 60
            }
            next.append(l.target.addingTimeInterval(-(r / step).rounded(.down) * step + 0.001))
        }
        for born in ages {
            let age = max(now.timeIntervalSince(born), 0), step: Double = age < 3600 ? 60 : 3600
            next.append(born.addingTimeInterval(((age / step).rounded(.down) + 1) * step))
        }
        return next.min()
    }

    // MARK: Money

    private static func formatter(_ code: String, digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US") // "$1,500": the artifact's grouping; the symbol follows the currency
        f.numberStyle = .currency
        f.currencyCode = code
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.roundingMode = .halfUp
        return f
    }

    static func money(_ v: Double, _ code: String, digits: Int = 2) -> String {
        formatter(code, digits: digits).string(from: v as NSNumber) ?? "\(v)"
    }

    /// "$" for USD, otherwise the currency's symbol from the system currency formatter (R-9).
    static func symbol(_ code: String) -> String { formatter(code, digits: 0).currencySymbol ?? code }

    /// R-14: "7 dollars 34", "1500 dollars"; other currencies "7.34 EUR".
    static func spoken(_ v: Double, _ code: String) -> String {
        guard code == "USD" else { return String(format: "%.2f %@", v, code) }
        let cents = Int((v * 100).rounded()), whole = cents / 100, rest = cents % 100
        return rest == 0 ? "\(whole) dollars" : "\(whole) dollars \(rest)"
    }

    // MARK: Error copy (Data & State → Error copy)

    static func problem(status: String) -> Problem {
        switch status {
        case "token_expired": Problem(error: "Token expired", fix: "refresh deferred this pass; retries automatically")
        case "relogin_required": Problem(error: "Re-login needed", fix: "refresh token dead; log in with Claude Code, then run: cswap add")
        case "keychain_unavailable": Problem(error: "Keychain unavailable", fix: "locked or in use; try again")
        case "foreign_credential": Problem(error: "Live credential belongs to another account", fix: "a switch repairs it")
        case "no_credentials": Problem(error: "No credentials", fix: "log in with Claude Code, then run: cswap add")
        default: Problem(error: "Usage unavailable", fix: "cswap will retry at its next poll")
        }
    }

    /// App-wide error (R-12); nil `failure` means a successful run with zero accounts.
    static func problem(failure: Failure?) -> Problem {
        switch failure {
        case .notFound: Problem(error: "cswap not found", fix: "Install claude-swap: uv tool install claude-swap")
        case .failed(let message): Problem(error: "cswap failed", fix: message)
        case .timedOut: Problem(error: "cswap timed out", fix: "It will be retried at the next refresh")
        case .unsupported: Problem(error: "Unsupported cswap version", fix: "Update GlanceBar or cswap")
        case nil: Problem(error: "No accounts yet", fix: "Run cswap add in a terminal")
        }
    }

    // MARK: Columns (R-8–R-12, R-14, R-17)

    /// What to show: the accounts of the last good snapshot, else the app-wide error column. Empty before the first result.
    static func columns(_ snapshot: Snapshot?, failure: Failure?, now: Date, calendar: Calendar = calendar) -> [Column] {
        if let s = snapshot, !s.accounts.isEmpty {
            return s.accounts.map { column($0, receivedAt: s.receivedAt, now: now, calendar: calendar) }
        }
        if snapshot == nil && failure == nil { return [] }
        let p = problem(failure: failure)
        return [Column(number: 0, label: "cswap", email: "", active: false, chip: "", kind: .error(p), measuredAt: nil,
                       speech: "cswap: \(p.error)")]
    }

    static func column(_ a: Account, receivedAt: Date, now: Date, calendar: Calendar = calendar) -> Column {
        let label = a.alias ?? String(a.number)
        let src = source(a)
        let age = a.usage != nil ? a.usageAge : src != nil ? a.lastGoodAge : nil
        var c = Column(number: a.number, label: label, email: a.email, active: a.active,
                       chip: a.active ? "active" : a.status == "api_key" ? "API key" : "slot \(a.number)",
                       kind: .error(problem(status: a.status)), measuredAt: age.map { receivedAt.addingTimeInterval(-$0) }, speech: "")
        if errorStatuses.contains(a.status) || !knownStatuses.contains(a.status) {
            // stays an error column
        } else if a.status == "api_key" && src?.spend == nil {
            c.kind = .apiKey(symbol: "$")
        } else if let u = src, u.fiveHour != nil || u.sevenDay != nil {
            c.kind = subscription(u, now: now, calendar: calendar)
        } else if let spend = src?.spend {
            c.kind = .spendCap(spendRow(spend, cap: true, now: now, calendar: calendar))
        }
        if case .error = c.kind { c.measuredAt = nil }
        c.speech = speech(c, now: now, calendar: calendar)
        return c
    }

    private static func subscription(_ u: UsageData, now: Date, calendar: Calendar) -> Column.Kind {
        let fiveHour = u.fiveHour.map { w -> WindowRow in
            let passed = w.resetsAt.map { $0 <= now } ?? false // after the reset: idle at 0 % until new data
            let m = meter(passed ? 0 : w.pct)
            guard let r = w.resetsAt, !passed, m.shown > 0 else {
                return WindowRow(name: "5h", meter: m, compact: "idle", long: fiveHourIdle, clock: nil, target: nil)
            }
            return WindowRow(name: "5h", meter: m, compact: text(r, .image5h, now: now), long: text(r, .long, now: now),
                             clock: clock(r, withDay: false, calendar: calendar), target: r)
        }
        let sevenDay = u.sevenDay.map { w in
            WindowRow(name: "7d", meter: meter(w.pct, pace: w.expectedPct),
                      compact: w.resetsAt.map { text($0, .image7d, now: now) } ?? "",
                      long: w.resetsAt.map { text($0, .long, now: now) } ?? "",
                      clock: w.resetsAt.map { clock($0, withDay: true, calendar: calendar) }, target: w.resetsAt)
        }
        let scoped = u.scoped.map { s in
            WindowRow(name: s.name, meter: meter(s.pct), compact: "", long: s.resetsAt.map { text($0, .long, now: now) } ?? "",
                      clock: nil, target: s.resetsAt)
        }
        let pace = u.sevenDay.flatMap { w in
            w.expectedPct.map { e in // the artifact's `Math.round(d7 - pace*100)`: the shown percent minus the raw
                // expectation, rounded half-up; only > 0 is "ahead", 0 reads "under" (dim)
                let points = shown(Double(shown(w.pct)) - e)
                return Pace(points: abs(points), ahead: points > 0)
            }
        }
        return .subscription(fiveHour: fiveHour, sevenDay: sevenDay,
                             extra: u.spend.map { spendRow($0, cap: false, now: now, calendar: calendar) }, scoped: scoped, pace: pace)
    }

    /// R-17: the panel always shows the 5h and 7d rows, as the artifact does. A missing 5h window reads as idle (the
    /// image's "idle"); a missing 7d window is an empty track with no percent, time or pace (the image's empty line).
    static func panelWindows(fiveHour: WindowRow?, sevenDay: WindowRow?) -> [WindowRow] {
        [fiveHour ?? WindowRow(name: "5h", meter: meter(0), compact: "idle", long: fiveHourIdle, clock: nil, target: nil),
         sevenDay ?? WindowRow(name: "7d", meter: meter(0), compact: "", long: "", clock: nil, target: nil, percent: false)]
    }

    private static func spendRow(_ s: Spend, cap: Bool, now: Date, calendar: Calendar) -> SpendRow {
        let reset = spendReset(s, now: now, calendar: calendar)
        let limitDigits = s.limit == s.limit.rounded() ? 0 : 2
        return SpendRow(symbol: symbol(s.currency), meter: meter(s.pct), spent: s.used > 0,
                        whole: money(s.used, s.currency, digits: 0),
                        daysLeft: text(reset, .imageDays, now: now, calendar: calendar),
                        used: money(s.used, s.currency), limit: money(s.limit, s.currency, digits: limitDigits),
                        detail: cap ? text(reset, .longDays, now: now, calendar: calendar) : clock(reset, withDay: true, calendar: calendar),
                        spoken: "\(spoken(s.used, s.currency)) of \(spoken(s.limit, s.currency))", target: reset)
    }

    // MARK: Accessibility (R-14)

    private static func speech(_ c: Column, now: Date, calendar: Calendar) -> String {
        func window(_ w: WindowRow, _ name: String) -> String {
            let left = w.long == fiveHourIdle ? ", idle" : w.long.isEmpty ? "" : ", resets in \(w.long)"
            return "\(name) \(w.meter.shown) percent\(left)"
        }
        switch c.kind {
        case let .subscription(fiveHour, sevenDay, extra, _, _):
            var parts = [fiveHour.map { window($0, "5 hour") }, sevenDay.map { window($0, "7 day") }].compactMap { $0 }
            if let extra, extra.spent { parts.append("extra usage \(extra.spoken)") }
            return "\(c.label): " + parts.joined(separator: "; ")
        case .spendCap(let s):
            let r = Int(s.target.timeIntervalSince(now))
            let days = calendarDays(from: now, to: s.target, calendar: calendar)
            let left = r >= 86400 ? "\(days) day\(days == 1 ? "" : "s")" : text(s.target, .long, now: now)
            return "\(c.label): spend \(s.spoken), resets in \(left)"
        case .apiKey: return "\(c.label): \(apiKeyLine)"
        case .error(let p): return "\(c.label): \(p.error)"
        }
    }

    /// The status item's label: every column's phrase.
    static func summary(_ columns: [Column]) -> String {
        columns.isEmpty ? "GlanceBar" : columns.map(\.speech).joined(separator: ". ") + "."
    }

    /// The countdown labels the status image shows (R-13); also the reset instants of R-3.7.
    static func imageCountdowns(_ columns: [Column]) -> [Countdown] {
        columns.flatMap { c -> [Countdown] in
            switch c.kind {
            case let .subscription(fiveHour, sevenDay, _, _, _):
                return [fiveHour?.target.map { Countdown(target: $0, form: .image5h) },
                        sevenDay?.target.map { Countdown(target: $0, form: .image7d) }].compactMap { $0 }
            case .spendCap(let s): return [Countdown(target: s.target, form: .imageDays)]
            case .apiKey, .error: return []
            }
        }
    }

    /// The countdown labels the open panel shows (R-21): 5h, 7d and per-model time left, and the spend cap's days
    /// left. Extra-usage rows show a fixed clock, so they never count down.
    static func panelCountdowns(_ columns: [Column]) -> [Countdown] {
        columns.flatMap { c -> [Countdown] in
            switch c.kind {
            case let .subscription(fiveHour, sevenDay, _, scoped, _):
                return ([fiveHour, sevenDay].compactMap { $0 } + scoped).compactMap { r in r.target.map { Countdown(target: $0, form: .long) } }
            case .spendCap(let s): return [Countdown(target: s.target, form: .longDays)]
            case .apiKey, .error: return []
            }
        }
    }

    /// The footer's measurement (R-17): the oldest displayed one. Nil when no column shows a measurement.
    static func oldestMeasurement(_ columns: [Column]) -> Date? { columns.compactMap(\.measuredAt).min() }

    /// R-3.7: reset instants that passed in (from, to]. Nothing on the first render.
    static func passedResets(_ targets: [Date], from: Date?, to: Date) -> [Date] {
        guard let from else { return [] }
        return Array(Set(targets.filter { $0 > from && $0 <= to })).sorted()
    }

    // MARK: Schedule (R-3.4, R-3.6, R-4)

    static let serveTTL: Double = 180     // cswap list never fetches a fresher row
    static let pollSlack: Double = 10
    static let pollFloor: Double = 60     // never two poll runs < 60 s apart (DD-2)
    static let fallback: Double = 180
    static let panelThrottle: Double = 30

    /// `usage.json`'s scheduling fields; nil when missing, unreadable or not schemaVersion 2 (→ 180 s fallback).
    static func pollRows(_ data: Data?) -> [Int: PollRow]? {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              number(root["schemaVersion"]) == 2, let accounts = root["accounts"] as? [String: Any] else { return nil }
        var rows: [Int: PollRow] = [:]
        for (key, value) in accounts {
            guard let n = Int(key), let r = value as? [String: Any] else { continue }
            rows[n] = PollRow(email: r["email"] as? String, fetchedAt: number(r["fetchedAt"]), nextPollAt: number(r["nextPollAt"]),
                              backoffUntil: number(r["backoffUntil"]), claimUntil: number(r["claimUntil"]),
                              authDeadStrikes: Int(number(r["authDeadStrikes"]) ?? 0))
        }
        return rows
    }

    /// When cswap would next agree to fetch the row: the latest of nextPollAt, fetchedAt + 180 s, backoffUntil and
    /// claimUntil; now if it has none of them (never fetched).
    static func due(_ row: PollRow, now: Date) -> Date {
        let t = [row.nextPollAt, row.fetchedAt.map { $0 + serveTTL }, row.backoffUntil, row.claimUntil].compactMap { $0 }.max()
        return t.map { Date(timeIntervalSince1970: $0) } ?? now
    }

    /// Due instants of the rows cswap may fetch: rows of accounts in the snapshot (same slot and email), not
    /// auth-dead, not api_key / no_credentials / relogin_required.
    static func dues(_ rows: [Int: PollRow], snapshot: Snapshot?, now: Date) -> [Date] {
        let skipped: Set = ["api_key", "no_credentials", "relogin_required"]
        return rows.compactMap { n, row in
            guard row.authDeadStrikes < 1,
                  let a = snapshot?.accounts.first(where: { $0.number == n && $0.email == row.email }),
                  !skipped.contains(a.status) else { return nil }
            return due(row, now: now)
        }
    }

    /// The poll timer's instant: earliest future due + 10 s, never before the last run + 60 s; 180 s after the later
    /// of the last run and now when nothing is due in the future or `usage.json` is unusable, so a poll fire that
    /// finds nothing due waits another 180 s.
    static func pollFire(_ rows: [Int: PollRow]?, snapshot: Snapshot?, lastRun: Date, now: Date) -> Date {
        let fallbackAt = max(lastRun, now).addingTimeInterval(fallback)
        guard let rows, let first = dues(rows, snapshot: snapshot, now: now).filter({ $0 > now }).min() else { return fallbackAt }
        return max(first.addingTimeInterval(pollSlack), lastRun.addingTimeInterval(pollFloor))
    }

    /// At a poll fire: is any account fetchable now? An unusable `usage.json`, no snapshot yet or a failed last run
    /// (the app-wide error state) counts as due, so cswap is retried at the fallback pace.
    static func anythingDue(_ rows: [Int: PollRow]?, snapshot: Snapshot?, failed: Bool, now: Date) -> Bool {
        guard let rows, snapshot != nil, !failed else { return true }
        return dues(rows, snapshot: snapshot, now: now).contains { $0 <= now }
    }

    /// R-3.4: does `usage.json` hold a fetch newer than GlanceBar's own last read (per slot number + email)?
    /// Claim-only writes don't change fetchedAt, so they never count.
    static func hasNewerFetch(_ rows: [Int: PollRow]?, than baseline: [Int: PollRow]?) -> Bool {
        (rows ?? [:]).contains { n, row in
            guard let f = row.fetchedAt else { return false }
            guard let old = baseline?[n], old.email == row.email, let seen = old.fetchedAt else { return true }
            return f > seen
        }
    }

    /// R-3.6: the panel opening refreshes only when the last run finished more than 30 s ago.
    static func refreshOnOpen(lastRun: Date?, now: Date) -> Bool {
        lastRun.map { now.timeIntervalSince($0) > panelThrottle } ?? true
    }

    // MARK: Visibility (R-6)

    static func isVisible(awake: Bool, displaysAwake: Bool, sessionActive: Bool, unlocked: Bool) -> Bool {
        awake && displaysAwake && sessionActive && unlocked
    }

    /// At launch: visible unless the session is reported locked or the displays asleep.
    static func visibleAtLaunch(locked: Bool, displaysAsleep: Bool) -> Bool { !locked && !displaysAsleep }

    // MARK: cswap process (R-1, R-2)

    static func cswapCandidates(home: String) -> [String] {
        [home + "/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
    }

    /// First executable candidate wins; re-checked on every run.
    static func locate(home: String, isExecutable: (String) -> Bool) -> String? {
        cswapCandidates(home: home).first(where: isExecutable)
    }

    /// The fixed minimal environment: no CLAUDE_CONFIG_DIR, so "active" is the default profile's login.
    static func environment(home: String, lang: String?) -> [String: String] {
        var env = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        env["LANG"] = lang
        return env
    }
}
