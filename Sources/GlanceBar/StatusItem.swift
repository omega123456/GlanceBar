import AppKit

/// The hover panel's window (R-15, R-16, DD-12): borderless and non-activating; it never becomes key or main, so
/// the frontmost app keeps the keyboard.
class GlancePanel: NSPanel {
    required override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives one tracking area's events (an NSTrackingArea's owner), so the item's and the panel's areas stay apart.
final class Tracker: NSObject {
    var entered: () -> Void = {}, exited: () -> Void = {}, moved: (NSEvent) -> Void = { _ in }
    @objc func mouseEntered(with event: NSEvent) { entered() }
    @objc func mouseExited(with event: NSEvent) { exited() }
    @objc func mouseMoved(with event: NSEvent) { moved(event) }

    /// Always active (GlanceBar is never the active app), enter/exit and moves, following the view's visible rect.
    func track(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }
}

/// The status item (R-8–R-22): image reassigned only when its value changes (R-13), the accessibility label
/// (R-14), the countdown timer, R-3.7 reset triggers, left vs right/⌃ click routing, the right-click menu, and the
/// hover panel (hover timers, click toggle, placement, fade, column highlight).
/// The status item never holds a permanent `menu`: it would capture the left click (DD-10).
final class StatusItem: NSObject {
    // Seams: tests hide the status item and capture the menu instead of tracking it.
    static var showsStatusItem = true
    static var popUp: (NSMenu, NSStatusBarButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 5 : -5), in: button)
    }
    /// Seam: the panel's window class (tests use one that is never ordered onto a real screen).
    static var panelClass: GlancePanel.Type = GlancePanel.self
    /// Seam: the status item's window frame and the visible frame of its screen, for placement (R-19).
    static var anchor: (NSStatusBarButton) -> (item: CGRect, visible: CGRect)? = { button in
        guard let window = button.window, let screen = window.screen else { return nil }
        return (window.frame, screen.visibleFrame)
    }

    /// Seam: animates the panel's frame and alpha over the 120 ms fade (R-20). The animator only advances on a live
    /// run loop, so tests apply the end state at once.
    static var animate: (NSWindow, _ frame: CGRect, _ alpha: CGFloat) -> Void = { window, frame, alpha in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fade
            ctx.timingFunction = CAMediaTimingFunction(name: .default)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        }
    }

    /// Seam: the system appearance (System Settings → Appearance) for the right-click menu. An LSUIElement app sets no
    /// appearance of its own, so the app's effective appearance is the system's; the status button's follows the
    /// wallpaper-tinted menu bar instead.
    static var systemAppearance: () -> NSAppearance = { NSApp.effectiveAppearance }

    /// Seam: a global mouse-down monitor (owner deviation from NFR-1, ADR "global mouse-down monitor while the panel is
    /// open"): it sees only clicks sent to other apps, i.e. outside the panel and the status item. Returns the remover.
    static var monitorClicks: (@escaping () -> Void) -> () -> Void = { handler in
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in handler() }
        return { monitor.map(NSEvent.removeMonitor) }
    }

    static let openDelay: TimeInterval = 0.3, closeDelay: TimeInterval = 0.4, fade: TimeInterval = 0.12

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let feed: Feed
    /// The value of the image on the button (R-13).
    private(set) var glance: Glance?
    private(set) var columns: [Column] = []
    private(set) var paused = false
    /// The open panel: the item highlight, and the hovered column in the image and the panel (DD-14, R-18).
    private(set) var panelOpen = false
    private(set) var hotColumn: Int?
    private(set) var panel: GlancePanel?
    let panelView = PanelView()
    /// The owners of the button's and the panel's tracking areas (tests send them events directly).
    let itemTracker = Tracker(), panelTracker = Tracker()
    /// The hover delays (only while hovering) and the pending order-out at the end of a fade-out.
    private var openTimer: Cancellable?, closeTimer: Cancellable?, fadeOut: Cancellable?
    /// Removes the outside-click monitor; set only while the panel is open.
    private var removeMonitor: (() -> Void)?
    /// The pointer's last x over the item, in image coordinates.
    private var pointerX: CGFloat?
    private var countdown: Cancellable?
    private var lastRender: Date?
    /// The countdown targets the last render showed: the reset instants R-3.7 watches.
    private var targets: [Date] = []
    private var appearanceObservation: NSKeyValueObservation?
    #if DEBUG
    static let dev = true
    #else
    static let dev = false
    #endif

    init(feed: Feed) {
        self.feed = feed
        super.init()
        item.isVisible = Self.showsStatusItem
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // DD-5: a changed menu-bar appearance (wallpaper, theme) builds a new image.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.update() }
            }
            itemTracker.track(button)
        }
        itemTracker.entered = { [weak self] in self?.pointerEntered() }
        itemTracker.exited = { [weak self] in self?.pointerExited() }
        itemTracker.moved = { [weak self] in self?.pointerMoved($0) }
        panelTracker.entered = { [weak self] in self?.cancelClose() }
        panelTracker.moved = { [weak self] _ in self?.cancelClose() }
        panelTracker.exited = { [weak self] in self?.armClose() }
        panelTracker.track(panelView.box)
        // R-15: a Space change or a screen-configuration change closes the panel.
        Env.workspace.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                     name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        Env.center.addObserver(self, selector: #selector(screensChanged),
                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        update()
    }

    deinit {
        removeMonitor?()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Recomputes the image value from the feed and the clock; reassigns the image and label only when it changed,
    /// re-arms the countdown timer and reports reset instants that passed since the last render (R-3.7).
    func update() {
        guard let button = item.button else { return }
        let now = Env.now()
        columns = Usage.columns(feed.snapshot, failure: feed.failure, now: now)
        let value = Glance(columns, hot: panelOpen ? hotColumn : nil, highlighted: panelOpen, dev: Self.dev,
                           style: Style.current(for: button.effectiveAppearance))
        if value != glance {
            glance = value
            button.image = value.image()
            button.setAccessibilityLabel(Usage.summary(columns))
            EventLog.write("image: updated (\(columns.count) columns)")
        }
        let countdowns = Usage.imageCountdowns(columns)
        var ages: [Date] = []
        var labels = countdowns
        if panelOpen {
            // R-21: while open, the panel's countdowns and footer age also aim the countdown timer.
            let footer = refreshPanel(now: now)
            labels += Usage.panelCountdowns(columns)
            if let footer { ages.append(footer) }
        }
        armCountdown(labels, ages: ages, now: now)
        let passed = Usage.passedResets(targets, from: lastRender, to: now)
        lastRender = now
        targets = countdowns.map(\.target)
        for instant in passed { feed.resetPassed(instant) }
    }

    /// One one-shot timer at the next instant a visible label changes (R-13): the image's, plus the open panel's.
    private func armCountdown(_ labels: [Countdown], ages: [Date], now: Date) {
        countdown?.cancel()
        countdown = nil
        guard !paused, let next = Usage.nextChange(labels, ages: ages, now: now) else { return }
        countdown = Env.at(next) { [weak self] in
            self?.countdown = nil
            self?.update()
        }
        EventLog.write("countdown: armed in \(Int(next.timeIntervalSince(now).rounded())) s")
    }

    /// Image-coordinate hit-test extents of the columns (DD-14); the pointer is mapped through these (R-18).
    var columnExtents: [ClosedRange<CGFloat>] { glance?.layout.extents ?? [] }

    // MARK: Visibility (R-6)

    /// Cancels the countdown and hover timers and closes the panel at once.
    func pause() {
        closePanel("not visible", animated: false)
        cancel(&openTimer)
        paused = true
        countdown?.cancel()
        countdown = nil
    }

    /// Redraws at once: countdowns that went stale while not visible are corrected from the clock.
    func resume() {
        paused = false
        update()
    }

    // MARK: Clicks (DD-10)

    @objc private func clicked() { handle(NSApp.currentEvent) }

    func handle(_ event: NSEvent?) {
        if Self.isMenuClick(event) {
            closePanel("menu", animated: false) // right-click closes the panel first
            showMenu()
        } else if panelOpen { // a left click toggles the panel, also when hover opened it (R-15)
            closePanel("click")
        } else {
            openPanel("click")
        }
    }

    /// Right-click or ⌃-click opens the app menu.
    static func isMenuClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || event.type == .rightMouseDown || event.modifierFlags.contains(.control)
    }

    func showMenu() {
        guard let button = item.button else { return }
        EventLog.write("menu: opened")
        let menu = makeMenu()
        // Without its own appearance the menu inherits the button's (the menu bar's, which follows the wallpaper);
        // it follows the system's light/dark setting like every other app menu. The image and panel keep DD-7.
        menu.appearance = Self.systemAppearance()
        Self.popUp(menu, button)
    }

    // MARK: Hover panel (R-15–R-21)

    private func cancel(_ timer: inout Cancellable?) {
        timer?.cancel()
        timer = nil
    }

    /// R-15: opens after the pointer rests on the item for 300 ms; re-entering cancels a pending close.
    private func pointerEntered() {
        cancel(&closeTimer)
        guard !panelOpen, !paused, openTimer == nil else { return }
        openTimer = Env.after(Self.openDelay) { [weak self] in
            self?.openTimer = nil
            self?.openPanel("hover")
        }
    }

    /// Leaving before 300 ms never opens it (a sweep across the menu bar); leaving an open panel's item closes it
    /// 400 ms later unless the pointer reaches the panel.
    private func pointerExited() {
        cancel(&openTimer)
        armClose()
    }

    private func cancelClose() { cancel(&closeTimer) }

    private func armClose() {
        guard panelOpen, closeTimer == nil else { return }
        closeTimer = Env.after(Self.closeDelay) { [weak self] in
            self?.closeTimer = nil
            self?.closePanel("pointer left")
        }
    }

    /// R-18: the column under the pointer (extents ± 4 pt); between and beyond columns the last one stays hot.
    private func pointerMoved(_ event: NSEvent) {
        guard let button = item.button else { return }
        let imageWidth = glance?.layout.width ?? 0
        pointerX = button.convert(event.locationInWindow, from: nil).x - max(0, (button.bounds.width - imageWidth) / 2)
        guard panelOpen else { return }
        if let hit = column(at: pointerX), hit != hotColumn {
            hotColumn = hit
            update()
        }
    }

    private func column(at x: CGFloat?) -> Int? {
        guard let x else { return nil }
        return columnExtents.firstIndex { $0.contains(x) }
    }

    private var reduceMotion: Bool { Env.workspace.accessibilityDisplayShouldReduceMotion }

    func openPanel(_ why: String) {
        guard !panelOpen, !paused, item.button != nil else { return }
        cancel(&openTimer)
        cancel(&closeTimer)
        cancel(&fadeOut)
        let window = panel ?? makePanel()
        panelOpen = true
        hotColumn = column(at: pointerX)
        removeMonitor = Self.monitorClicks { [weak self] in self?.closePanel("clicked outside") }
        update() // builds the content
        place(window) // R-19, on every open: a fade-out leaves the frame 4 pt up, and the item or screen may have moved
        EventLog.write("panel: opened (\(why))")
        if reduceMotion { // R-20: instant
            window.alphaValue = 1
            window.orderFrontRegardless()
        } else { // fade in while moving down 4 pt into place, 120 ms
            let target = window.frame
            if !window.isVisible { window.alphaValue = 0 }
            window.setFrame(target.offsetBy(dx: 0, dy: 4), display: false)
            window.orderFrontRegardless()
            Self.animate(window, target, 1)
        }
        feed.panelOpened() // R-3.6: refreshes only when the last run finished > 30 s ago
    }

    func closePanel(_ why: String, animated: Bool = true) {
        if !animated, fadeOut != nil { // a fade-out in progress ends now
            cancel(&fadeOut)
            panel?.orderOut(nil)
        }
        guard panelOpen else { return }
        cancel(&openTimer)
        cancel(&closeTimer)
        removeMonitor?()
        removeMonitor = nil
        panelOpen = false
        hotColumn = nil
        update()
        EventLog.write("panel: closed (\(why))")
        guard let window = panel else { return }
        if !animated || reduceMotion {
            window.orderOut(nil)
            return
        }
        // Fade out while moving back up 4 pt; ordered out when the 120 ms are over.
        Self.animate(window, window.frame.offsetBy(dx: 0, dy: 4), 0)
        fadeOut = Env.after(Self.fade) { [weak self] in
            self?.fadeOut = nil
            window.orderOut(nil)
        }
    }

    @objc private func spaceChanged() { closePanel("space changed", animated: false) }
    @objc private func screensChanged() { closePanel("screens changed", animated: false) }

    /// R-12/R-17/R-18 content for the open panel, rebuilt only when it changes, then placed (R-19). Returns the
    /// footer's measurement (the R-21 age label), nil when the footer is hidden.
    private func refreshPanel(now: Date) -> Date? {
        guard let window = panel else { return nil }
        let oldest = Usage.oldestMeasurement(columns)
        let value = Panel(columns: columns, footer: oldest.map { Usage.footer(measuredAt: $0, now: now) }, hot: hotColumn,
                          style: Style.current(for: window.effectiveAppearance))
        if value != panelView.panel {
            panelView.show(value)
            place(window)
        }
        return oldest
    }

    /// R-19: right-aligned to the item, 6 pt below its window, clamped 8 pt from the visible frame's sides.
    private func place(_ window: NSWindow) {
        guard let button = item.button, let anchor = Self.anchor(button) else { return }
        window.setFrame(Self.placement(size: panelView.frame.size, item: anchor.item, visible: anchor.visible), display: true)
    }

    static func placement(size: CGSize, item: CGRect, visible: CGRect) -> CGRect {
        let x = max(visible.minX + 8, min(item.maxX - size.width, visible.maxX - 8 - size.width))
        return CGRect(x: x, y: item.minY - 6 - size.height, width: size.width, height: size.height)
    }

    private func makePanel() -> GlancePanel {
        let p = Self.panelClass.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu // DD-12: over full-screen apps' menu bars
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        // The native shadow approximates the artifact's 0/12/32 black .28 and never catches clicks: the window is only
        // the box, so a click beside or below it reaches the app underneath (and the outside-click monitor).
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = panelView
        panel = p
        return p
    }

    // MARK: Right-click menu (R-22), built each time it opens

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if Self.dev {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            add("GlanceBar Dev \(version) (debug)", to: menu).isEnabled = false
            menu.addItem(.separator())
        }
        add("Launch at Login", #selector(toggleLaunchAtLogin), to: menu, on: LaunchAtLogin.isEnabled)
        add("Automatic Updates", #selector(toggleUpdates), to: menu, on: Updater.isEnabled)
        add("Check for Updates…", #selector(checkForUpdates), to: menu)
        menu.addItem(.separator())
        add("Quit GlanceBar", #selector(quit), to: menu)
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, to menu: NSMenu, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.state = on ? .on : .off
        menu.addItem(item)
        return item
    }

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
    @objc private func toggleUpdates() { Updater.toggle() }
    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func quit() { Env.terminate() }
}
