import Foundation
import Testing
@testable import GlanceBar

/// Trigger and run-count behaviour (R-1–R-7) with a fake cswap, scheduler, clock, file reader and watchers.
extension Desktop {
    @MainActor @Suite struct FeedTests {
        let h = Harness()
        let feed = Feed()

        /// Rows for the yoursNow accounts (slots 2 and 3), fetched `ago` seconds before now, next poll in `next`.
        func rows(fetched ago: TimeInterval = 10, next: TimeInterval = 300) -> [Int: [String: Any]] {
            [2: ["fetchedAt": Fixture.epoch(-ago), "nextPollAt": Fixture.epoch(next), "claimUntil": 0, "authDeadStrikes": 0],
             3: ["fetchedAt": Fixture.epoch(-ago), "nextPollAt": Fixture.epoch(next + 200), "claimUntil": 0, "authDeadStrikes": 0]]
        }

        /// Launch run, finished with the yoursNow accounts and `usage.json` as given.
        func launched(_ usage: [Int: [String: Any]]? = nil) {
            h.writeUsage(usage ?? rows())
            h.write("sequence.json", Data("{}".utf8))
            feed.start()
            h.finish()
        }

        @Test func oneRunAtLaunch() {
            var changes = 0
            feed.onChange = { changes += 1 }
            launched()
            #expect(h.runs == 1)
            #expect(h.launches[0].args == ["list", "--json"])
            #expect(h.launches[0].env["CLAUDE_CONFIG_DIR"] == nil && h.launches[0].env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
            #expect(h.launches[0].env["HOME"] == h.dir.path)
            #expect(feed.snapshot?.accounts.map(\.number) == [2, 3])
            #expect(feed.failure == nil && changes == 1)
            #expect(h.watchOpens == [".claude-swap-backup", "cache"])
            #expect(h.log.contains("run: trigger launch") && h.log.contains("run: launch done in 0 ms, exit 0, 2 accounts"))
        }

        @Test func claimOnlyChangeDoesNotRun() {
            launched()
            var claim = rows()
            claim[2]?["claimUntil"] = Fixture.epoch(30)
            h.writeUsage(claim)
            h.event()
            h.event() // debounced: one check
            h.advance(1)
            #expect(h.runs == 1)
            #expect(h.log.contains("watch: usage.json skipped (claim-only change)"))
            h.event(cache: false) // nothing changed since
            h.advance(1)
            #expect(h.runs == 1)
            #expect(h.log.contains("watch: event skipped (files unchanged)"))
        }

        @Test func newerFetchFromAnotherSurfaceRunsOnce() {
            launched()
            h.advance(30)
            h.writeUsage(rows(fetched: 0))
            h.event()
            h.advance(0.5)
            h.event()
            #expect(h.runs == 1)
            h.advance(0.5)
            #expect(h.runs == 2)
            #expect(h.log.contains("run: trigger usage.json has a newer fetch"))
            h.finish()
            h.event() // the run's own read of usage.json is the baseline now
            h.advance(1)
            #expect(h.runs == 2)
        }

        @Test func ownFetchDoesNotRunTwice() {
            launched()
            h.advance(200)
            feed.trigger("test")
            // cswap fetches during GlanceBar's own run: claim, then result, both before it exits.
            var claim = rows()
            claim[2]?["claimUntil"] = Fixture.epoch(30)
            h.writeUsage(claim)
            h.event()
            h.advance(1) // debounce fires while the run is in flight: decided after it
            h.writeUsage(rows(fetched: 0))
            h.event()
            #expect(h.runs == 2)
            h.finish()
            h.advance(1) // the result's event arrives after the run
            #expect(h.runs == 2)
            #expect(!h.log.contains("newer fetch"))
        }

        @Test func sequenceChangeRunsOnce() {
            launched()
            h.write("sequence.json", Data(#"{"activeAccountNumber":3}"#.utf8))
            h.event(cache: false)
            h.advance(1)
            #expect(h.runs == 2)
            #expect(h.log.contains("run: trigger sequence.json changed"))
            h.finish()
            h.advance(1)
            #expect(h.runs == 2)
        }

        @Test func sequenceChangeDuringARunFollowsUp() {
            launched()
            feed.trigger("test")
            h.write("sequence.json", Data(#"{"alias":"x"}"#.utf8))
            h.event(cache: false)
            h.advance(1)
            #expect(h.runs == 2)
            h.finish()
            #expect(h.runs == 3) // the run read sequence.json before it changed
        }

        @Test func pollFireWithNothingDueReArms() throws {
            launched()
            #expect(h.armed == [310]) // earliest due (slot 2 at +300) + 10 s
            // Another surface fetched meanwhile: slot 2 is due later now.
            h.advance(100)
            var later = rows(fetched: 0, next: 400)
            later[3]?["nextPollAt"] = Fixture.epoch(900)
            h.writeUsage(later)
            h.advance(210)
            #expect(h.runs == 1)
            #expect(h.log.contains("poll: skipped (nothing due)"))
            #expect(h.armed.count == 1) // re-armed: slot 2 due at +400 (from the launch), + 10 s
            #expect(abs(try #require(h.armed.first) - 100) < 0.001)
        }

        @Test func pollFireWhenDueRunsOnce() {
            launched()
            h.advance(309)
            #expect(h.runs == 1)
            h.advance(1)
            #expect(h.runs == 2)
            #expect(h.log.contains("run: trigger poll"))
            #expect(h.launches[1].at.timeIntervalSince(h.launches[0].at) == 310)
        }

        @Test func pollFallbackWithoutUsageFile() {
            h.write("sequence.json", Data("{}".utf8))
            feed.start()
            h.finish()
            #expect(h.armed == [180])
            #expect(h.log.contains("(fallback)"))
            h.advance(180)
            #expect(h.runs == 2) // an unusable usage.json counts as due
        }

        /// A failed launch run with `usage.json` present (no snapshot, so no row is due): the poll retries cswap at
        /// the 180 s fallback pace, never in a 1 s loop.
        @Test func failedLaunchIsRetriedEvery180Seconds() {
            h.writeUsage(rows())
            feed.start()
            h.finish(Fixture.envelope, status: 1)
            #expect(feed.failure == .failed("No accounts file") && feed.snapshot == nil)
            for _ in 0..<600 {
                h.advance(1)
                if !h.running.isEmpty { h.finish(Fixture.envelope, status: 1) }
            }
            let times = h.launches.map { $0.at.timeIntervalSince(Fixture.now) }
            #expect(times == [0, 180, 360, 540])
            #expect(h.log.components(separatedBy: "run: trigger poll").count - 1 <= 4)
            #expect(!h.log.contains("poll: skipped"))
            #expect(h.armed.allSatisfy { $0 >= 59 })
        }

        /// Every account relogin_required: nothing is ever due, so each poll fire re-arms 180 s later, never 1 s.
        @Test func allReloginSnapshotNeverLoopsEverySecond() {
            let dead = Fixture.list([Fixture.account(2, status: "relogin_required", usage: false),
                                     Fixture.account(3, status: "relogin_required", usage: false)])
            h.writeUsage(rows(fetched: 1000, next: -500))
            feed.start()
            h.finish(dead)
            #expect(h.armed == [180])
            for _ in 0..<600 { h.advance(1) }
            #expect(h.armed == [120]) // the fire at 540 s re-armed for 720 s
            #expect(h.runs == 1)
            #expect(h.log.components(separatedBy: "poll: skipped (nothing due)").count - 1 == 3)
            #expect(h.log.components(separatedBy: "poll: armed in 180 s").count - 1 == 4)
            #expect(!h.log.contains("poll: armed in 1 s"))
        }

        /// A past nextPollAt with a live backoff, a 60 s urgent plan inside the 180 s window, a dead-token row and a
        /// row for a removed slot: over an hour, no two poll runs are less than 60 s apart and none comes early.
        @Test func neverBackToBackRuns() {
            let usage: [Int: [String: Any]] = [
                2: ["fetchedAt": Fixture.epoch(-10), "nextPollAt": Fixture.epoch(50)],                               // urgent plan
                3: ["fetchedAt": Fixture.epoch(-900), "nextPollAt": Fixture.epoch(-100), "backoffUntil": Fixture.epoch(400)],
                5: ["fetchedAt": Fixture.epoch(-900), "nextPollAt": Fixture.epoch(-100), "authDeadStrikes": 2],       // dead token
                9: ["fetchedAt": Fixture.epoch(-900), "nextPollAt": Fixture.epoch(-100)],                             // removed slot
            ]
            launched(usage)
            for _ in 0..<3600 {
                h.advance(1)
                if !h.running.isEmpty { h.finish() } // cswap fetched nothing: usage.json unchanged
            }
            let times = h.launches.map { $0.at.timeIntervalSince(Fixture.now) }
            #expect(times.count > 3)
            #expect(times[1] >= 170 + 10) // slot 2 is not fetchable before fetchedAt + 180 s
            #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 60 })
        }

        @Test func triggersDuringARunFoldIntoOneFollowUp() {
            launched()
            feed.trigger("one")
            feed.trigger("two")
            feed.resetPassed(Fixture.now.addingTimeInterval(-1))
            h.write("sequence.json", Data("[]".utf8))
            h.event(cache: false)
            h.advance(1)
            #expect(h.runs == 2)
            h.finish()
            #expect(h.runs == 3)
            #expect(h.log.contains("run: trigger follow-up"))
            h.finish()
            #expect(h.runs == 3)
        }

        @Test func notVisibleMeansNoRunsTimersOrWatchers() {
            launched()
            h.event()
            #expect(!h.armed.isEmpty && !h.watchers.isEmpty)
            feed.pause()
            feed.pause()
            #expect(h.armed.isEmpty) // poll and debounce cancelled
            #expect(h.watchers.isEmpty) // suspended
            feed.trigger("poll")
            feed.panelOpened()
            feed.resetPassed(Fixture.now.addingTimeInterval(5))
            h.advance(3600)
            #expect(h.runs == 1)
            #expect(h.log.contains("run: poll skipped (not visible)"))
            #expect(h.log.contains("folded into the resume run"))
        }

        @Test func aRunInFlightFinishesWhilePaused() {
            launched()
            feed.trigger("test")
            feed.trigger("again")
            feed.pause()
            h.finish(Fixture.midSession)
            #expect(feed.snapshot?.accounts[0].usage?.fiveHour?.pct == 38) // applied
            #expect(h.runs == 2 && h.armed.isEmpty) // no follow-up, no poll
        }

        @Test func returnRunsOnceAfterFiveSeconds() {
            launched()
            feed.pause()
            h.advance(7200)
            // Changes while not visible: re-baselined on return without acting.
            h.write("sequence.json", Data("[1]".utf8))
            h.writeUsage(rows(fetched: 0))
            var resumed = 0
            feed.onResume = { resumed += 1 }
            feed.resume()
            feed.resume()
            #expect(h.watchers.count == 2)
            h.event()
            h.event(cache: false)
            feed.panelOpened() // folded into the resume run
            feed.resetPassed(Fixture.now.addingTimeInterval(100))
            h.advance(4.9)
            #expect(h.runs == 1)
            h.advance(0.1)
            #expect(h.runs == 2 && resumed == 1)
            #expect(h.log.contains("run: trigger resume"))
            h.finish()
            h.advance(2)
            #expect(h.runs == 2) // the events were about changes already in the baseline
        }

        /// A trigger queued during a run that finishes while paused is covered by the resume run: one run after
        /// resume, no follow-up (R-6).
        @Test func queuedFollowUpIsDroppedByPause() {
            launched()
            feed.trigger("test")
            h.write("sequence.json", Data("[2]".utf8))
            h.event(cache: false)
            h.advance(1) // the debounce fires during the run: a recheck is queued
            feed.trigger("again") // and a follow-up
            feed.pause()
            h.finish()
            feed.resume()
            h.advance(5)
            #expect(h.runs == 3)
            h.finish()
            h.advance(2)
            #expect(h.runs == 3)
            #expect(!h.log.contains("run: trigger follow-up") && !h.log.contains("sequence.json changed"))
        }

        @Test func panelOpenedThrottle() {
            launched()
            h.advance(10)
            feed.panelOpened()
            #expect(h.runs == 1)
            #expect(h.log.contains("panel opened skipped"))
            h.advance(21)
            feed.panelOpened()
            #expect(h.runs == 2)
            feed.panelOpened() // in flight: nothing
            h.finish()
            #expect(h.runs == 2)
        }

        @Test func resetPassedRunsOncePerInstant() {
            launched()
            let instant = Fixture.now.addingTimeInterval(100)
            h.advance(100)
            feed.resetPassed(instant)
            #expect(h.runs == 2)
            h.finish()
            feed.resetPassed(instant)
            #expect(h.runs == 2)
        }

        @Test func timeoutKeepsLastGoodData() {
            launched()
            feed.trigger("test")
            h.advance(19.9)
            #expect(h.killed == 0)
            h.advance(0.1)
            #expect(h.killed == 1)
            #expect(feed.failure == .timedOut)
            #expect(feed.snapshot?.accounts.count == 2)
            #expect(!Usage.columns(feed.snapshot, failure: feed.failure, now: h.now).contains { $0.label == "cswap" })
            h.finish(Fixture.zero) // the killed process's late result is ignored
            #expect(feed.snapshot?.accounts.count == 2)
            feed.trigger("next")
            h.finish()
            #expect(feed.failure == nil)
        }

        @Test func missingCswapIsAnAppWideError() {
            h.installed = false
            feed.start()
            #expect(h.runs == 0)
            #expect(feed.failure == .notFound)
            let columns = Usage.columns(feed.snapshot, failure: feed.failure, now: h.now)
            #expect(columns.map(\.label) == ["cswap"])
            #expect(columns[0].kind == .error(Problem(error: "cswap not found", fix: "Install claude-swap: uv tool install claude-swap")))
            #expect(h.armed == [180])
            h.installed = true // installed later: picked up at the next run, no relaunch
            h.advance(180)
            #expect(h.runs == 1)
        }

        @Test func failedRuns() {
            launched()
            feed.trigger("envelope")
            h.finish(Fixture.envelope, status: 1)
            #expect(feed.failure == .failed("No accounts file"))
            feed.trigger("crash")
            h.finish(Data("Traceback".utf8), status: 3)
            #expect(feed.failure == .failed("exit code 3"))
            feed.trigger("schema")
            h.finish(Fixture.schema2)
            #expect(feed.failure == .unsupported)
            #expect(feed.snapshot?.accounts.count == 2) // last good data kept throughout
            h.launchError = CocoaError(.executableNotLoadable)
            feed.trigger("unlaunchable")
            #expect(feed.failure.map { if case .failed = $0 { true } else { false } } == true)
            h.launchError = nil
            feed.trigger("zero")
            h.finish(Fixture.zero)
            #expect(feed.failure == nil)
            #expect(Usage.columns(feed.snapshot, failure: feed.failure, now: h.now)[0].kind == .error(Usage.problem(failure: nil)))
        }

        @Test func deletedDirectoryIsReopenedAtTheNextRun() {
            launched()
            #expect(h.watchOpens.count == 2)
            h.event(cache: false, gone: true) // cswap purge
            #expect(h.watchers.count == 1)
            #expect(h.log.contains("deleted or renamed, re-opened at the next run"))
            h.advance(1)
            feed.trigger("test")
            h.finish()
            #expect(h.watchers.count == 2)
            #expect(h.watchOpens == [".claude-swap-backup", "cache", ".claude-swap-backup"])
        }

        @Test func missingDirectoryIsWatchedOnceItExists() {
            h.dirs = []
            launched()
            #expect(h.watchers.isEmpty)
            h.dirs = [h.root.path, h.cache.path] // cswap installed later
            feed.trigger("test")
            h.finish()
            #expect(h.watchers.count == 2)
        }

        // MARK: Production seams on real temporary files and processes (never cswap, never ~/.claude-swap-backup)

        @Test func realFileStampsAndWatcher() async throws {
            let folder = h.dir.appendingPathComponent("watched")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("usage.json")
            #expect(Feed.fileStamp(file) == nil)
            try Data("a".utf8).write(to: file, options: .atomic)
            let first = try #require(Feed.fileStamp(file))
            try Data("b".utf8).write(to: file, options: .atomic)
            #expect(Feed.fileStamp(file) != first) // atomic rename: new inode
            #expect(Feed.watchDirectory(h.dir.appendingPathComponent("missing"), { _ in }) == nil)
            var events: [Bool] = []
            let close = try #require(Feed.watchDirectory(folder) { events.append($0) })
            try Data("c".utf8).write(to: file, options: .atomic)
            for _ in 0..<100 where events.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(events.first == false)
            try FileManager.default.moveItem(at: folder, to: h.dir.appendingPathComponent("renamed"))
            for _ in 0..<100 where !events.contains(true) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(events.contains(true))
            close()
        }

        @Test func realProcessRunner() async throws {
            var result: (Int32, Data)?
            _ = try Feed.runProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf \"$HOME\"; exit 3"], ["HOME": "/nowhere"]) { result = ($0, $1) }
            for _ in 0..<200 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(result?.0 == 3)
            #expect(result.map { String(decoding: $0.1, as: UTF8.self) } == "/nowhere")
            result = nil
            let kill = try Feed.runProcess(URL(fileURLWithPath: "/bin/sleep"), ["30"], [:]) { result = ($0, $1) }
            kill()
            for _ in 0..<200 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(result?.0 == 15) // SIGTERM
            #expect(Usage.locate(home: "/nowhere", isExecutable: { _ in false }) == nil)
        }
    }
}
