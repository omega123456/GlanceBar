import Foundation

/// The data feed (R-1–R-7, DD-2): runs `cswap list --json` off the main thread (single flight, 20 s timeout) on the
/// R-3 triggers, watches cswap's two directories, arms the R-4 poll timer and pauses while not visible (R-6).
/// Every decision comes from `Usage`; this class only wires I/O and timers to it.
final class Feed {
    /// A file's modification identity (R-5).
    struct Stamp: Equatable {
        var inode: UInt64
        var seconds: Int
        var nanoseconds: Int
    }

    // MARK: Seams (DD-11)

    static var home = FileManager.default.homeDirectoryForCurrentUser
    /// R-2: the cswap executable, re-checked on every run.
    static var locate: () -> URL? = {
        Usage.locate(home: home.path, isExecutable: FileManager.default.isExecutableFile).map(URL.init(fileURLWithPath:))
    }
    /// Starts the process; `done` is called on the main thread with its exit status and stdout. Returns "terminate".
    static var launch: (_ exe: URL, _ args: [String], _ env: [String: String],
                        _ done: @escaping (_ status: Int32, _ output: Data) -> Void) throws -> () -> Void = runProcess
    /// Opens an event-only watcher on a directory; the handler gets `gone` for delete/rename. Returns "close", or
    /// nil when the directory doesn't exist.
    static var watch: (_ dir: URL, _ event: @escaping (_ gone: Bool) -> Void) -> (() -> Void)? = watchDirectory
    static var read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    static var stamp: (URL) -> Stamp? = fileStamp

    // MARK: State

    /// Called on the main thread after every run's result is applied.
    var onChange: (() -> Void)?
    /// Called when the single +5 s run after a return to visible starts.
    var onResume: (() -> Void)?
    private(set) var snapshot: Snapshot?
    private(set) var failure: Failure?
    /// When the last run finished.
    private(set) var lastRun: Date?
    private(set) var paused = false
    private(set) var inFlight = false
    private var followUp = false, recheck = false
    private var runID = 0
    private var terminate: (() -> Void)?
    private var timeout: Cancellable?, poll: Cancellable?, debounce: Cancellable?, resumeRun: Cancellable?
    private var watchers: [URL: () -> Void] = [:]
    private var sequenceStamp: Stamp?, usageStamp: Stamp?
    /// `usage.json` as GlanceBar last read it (R-3.4 baseline, R-4 rows).
    private var baseline: [Int: PollRow]?
    private var handledResets = Set<Date>()

    private var root: URL { Self.home.appendingPathComponent(".claude-swap-backup") }
    private var cacheDir: URL { root.appendingPathComponent("cache") }
    private var sequenceURL: URL { root.appendingPathComponent("sequence.json") }
    private var usageURL: URL { cacheDir.appendingPathComponent("usage.json") }

    // MARK: Triggers

    /// R-3.1: once at launch (if visible; otherwise the resume run replaces it).
    func start() {
        guard !paused else { return }
        rebaseline()
        openWatchers()
        trigger("launch")
    }

    /// Every run request goes through here: none while not visible; folded into one follow-up during a run (R-1).
    func trigger(_ why: String) {
        guard !paused else { return EventLog.write("run: \(why) skipped (not visible)") }
        if inFlight {
            if !followUp { EventLog.write("run: \(why) during a run, one follow-up queued") }
            followUp = true
            return
        }
        run(why)
    }

    /// R-3.6: the panel opened (Phase 2 calls this). Refreshes only if the last run finished > 30 s ago.
    func panelOpened() {
        guard !paused, !inFlight, resumeRun == nil else { return }
        if Usage.refreshOnOpen(lastRun: lastRun, now: Env.now()) {
            trigger("panel opened")
        } else {
            EventLog.write("run: panel opened skipped (last run < 30 s ago)")
        }
    }

    /// R-3.7: a displayed reset instant passed; at most one run per instant. Folded into the resume run while not visible.
    func resetPassed(_ instant: Date) {
        guard handledResets.insert(instant).inserted else { return }
        if paused || resumeRun != nil { return EventLog.write("run: reset passed, folded into the resume run") }
        trigger("reset passed")
    }

    // MARK: Visibility (R-6)

    /// Cancels the poll, debounce and resume timers and closes the watchers; a run in flight still finishes.
    /// A queued follow-up or recheck is dropped: the single resume run covers it (R-6).
    func pause() {
        guard !paused else { return }
        paused = true
        followUp = false
        recheck = false
        for t in [poll, debounce, resumeRun] { t?.cancel() }
        poll = nil; debounce = nil; resumeRun = nil
        closeWatchers()
        EventLog.write("feed: paused")
    }

    /// Re-reads the files' identities and `fetchedAt` baselines without acting, re-opens the watchers (no queued
    /// events survive) and arms the single run 5 s later, which re-arms everything.
    func resume() {
        guard paused else { return }
        paused = false
        rebaseline()
        openWatchers()
        resumeRun = Env.after(5) { [weak self] in
            guard let self else { return }
            resumeRun = nil
            onResume?()
            trigger("resume")
        }
        EventLog.write("feed: resumed, run in 5 s")
    }

    // MARK: Running (R-1, R-7)

    private func run(_ why: String) {
        poll?.cancel()
        poll = nil
        sequenceStamp = Self.stamp(sequenceURL) // a change during the run is caught by the recheck afterwards
        let start = Env.now()
        guard let exe = Self.locate() else { return finish(why, start: start, .failure(.notFound), exit: nil) }
        inFlight = true
        runID += 1
        let id = runID
        EventLog.write("run: trigger \(why)")
        let env = Usage.environment(home: Self.home.path, lang: ProcessInfo.processInfo.environment["LANG"])
        do {
            terminate = try Self.launch(exe, ["list", "--json"], env) { [weak self] status, output in
                self?.completed(id, why, start, status, output)
            }
        } catch {
            return finish(why, start: start, .failure(.failed("\(error.localizedDescription)")), exit: nil)
        }
        timeout = Env.after(20) { [weak self] in
            guard let self, id == runID, inFlight else { return }
            terminate?()
            finish(why, start: start, .failure(.timedOut), exit: nil)
        }
    }

    private func completed(_ id: Int, _ why: String, _ start: Date, _ status: Int32, _ output: Data) {
        guard id == runID, inFlight else { return } // timed out already
        var result = Usage.decode(output, at: Env.now())
        if status != 0 {
            switch result {
            case .failure(.failed(let m)) where m != Usage.unreadable: break // the error envelope's message
            default: result = .failure(.failed("exit code \(status)"))
            }
        }
        finish(why, start: start, result, exit: status)
    }

    private func finish(_ why: String, start: Date, _ result: Result<Snapshot, Failure>, exit: Int32?) {
        inFlight = false
        timeout?.cancel()
        timeout = nil
        terminate = nil
        let now = Env.now()
        lastRun = now
        let ms = Int(now.timeIntervalSince(start) * 1000)
        switch result {
        case .success(let s):
            snapshot = s
            failure = nil
            EventLog.write("run: \(why) done in \(ms) ms, exit \(exit ?? 0), \(s.accounts.count) accounts")
        case .failure(let f):
            failure = f
            EventLog.write("run: \(why) failed in \(ms) ms: \(f)")
        }
        // The new baseline, read right after the run: a fetch this run caused never triggers a second one (R-3.4).
        usageStamp = Self.stamp(usageURL)
        baseline = Usage.pollRows(Self.read(usageURL))
        openWatchers() // R-5: missing or deleted directories are re-checked at each run
        onChange?()
        guard !paused else { return }
        if followUp {
            followUp = false
            recheck = false
            return run("follow-up")
        }
        if recheck {
            recheck = false
            checkFiles()
        }
        if !inFlight { armPoll(baseline) }
    }

    // MARK: Poll timer (R-4)

    private func armPoll(_ rows: [Int: PollRow]?) {
        guard !paused, let lastRun else { return }
        let now = Env.now()
        let at = Usage.pollFire(rows, snapshot: snapshot, lastRun: lastRun, now: now)
        poll?.cancel()
        poll = Env.at(at) { [weak self] in self?.pollFired() }
        EventLog.write("poll: armed in \(Int(at.timeIntervalSince(now).rounded())) s\(rows == nil ? " (fallback)" : "")")
    }

    private func pollFired() {
        poll = nil
        let rows = Usage.pollRows(Self.read(usageURL))
        if Usage.anythingDue(rows, snapshot: snapshot, failed: failure != nil, now: Env.now()) {
            trigger("poll")
        } else {
            EventLog.write("poll: skipped (nothing due)")
            armPoll(rows)
        }
    }

    // MARK: Watching (R-3.3, R-3.4, R-5)

    private func rebaseline() {
        sequenceStamp = Self.stamp(sequenceURL)
        usageStamp = Self.stamp(usageURL)
        baseline = Usage.pollRows(Self.read(usageURL))
    }

    private func openWatchers() {
        guard !paused else { return }
        for dir in [root, cacheDir] where watchers[dir] == nil {
            if let close = Self.watch(dir, { [weak self] gone in self?.directoryEvent(dir, gone: gone) }) {
                watchers[dir] = close
                EventLog.write("watch: \(dir.lastPathComponent) opened")
            }
        }
    }

    private func closeWatchers() {
        for close in watchers.values { close() }
        watchers = [:]
    }

    private func directoryEvent(_ dir: URL, gone: Bool) {
        guard !paused else { return }
        if gone, let close = watchers.removeValue(forKey: dir) {
            close()
            EventLog.write("watch: \(dir.lastPathComponent) deleted or renamed, re-opened at the next run")
        }
        guard debounce == nil else { return }
        debounce = Env.after(1) { [weak self] in
            self?.debounce = nil
            self?.checkFiles()
        }
    }

    /// Compares the two files' identities with the last seen ones before doing anything else.
    private func checkFiles() {
        if inFlight { recheck = true; return } // decided against the baseline read after the run
        let seq = Self.stamp(sequenceURL), usage = Self.stamp(usageURL)
        var why: String?
        if seq != sequenceStamp {
            sequenceStamp = seq
            why = "sequence.json changed"
        }
        if usage != usageStamp {
            usageStamp = usage
            if Usage.hasNewerFetch(Usage.pollRows(Self.read(usageURL)), than: baseline) {
                why = why ?? "usage.json has a newer fetch"
            } else {
                EventLog.write("watch: usage.json skipped (claim-only change)")
            }
        } else if why == nil {
            EventLog.write("watch: event skipped (files unchanged)")
        }
        if let why { trigger(why) }
    }

    // MARK: Production implementations of the seams

    static func runProcess(_ exe: URL, _ args: [String], _ env: [String: String],
                           _ done: @escaping (Int32, Data) -> Void) throws -> () -> Void {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global(qos: .utility).async { // off the main thread (R-1)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async { done(process.terminationStatus, data) }
        }
        return { process.terminate() }
    }

    static func watchDirectory(_ dir: URL, _ event: @escaping (Bool) -> Void) -> (() -> Void)? {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [unowned source] in event(!source.data.isDisjoint(with: [.delete, .rename])) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return { source.cancel() }
    }

    static func fileStamp(_ url: URL) -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(inode: UInt64(st.st_ino), seconds: st.st_mtimespec.tv_sec, nanoseconds: st.st_mtimespec.tv_nsec)
    }
}
