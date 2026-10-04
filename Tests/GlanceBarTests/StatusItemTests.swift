import AppKit
import ServiceManagement
import Testing
@testable import GlanceBar

extension Desktop {
    @MainActor @Suite struct StatusItemTests {
        let h = Harness()
        let feed = Feed()

        func item(_ output: Data = Fixture.yoursNow) -> StatusItem {
            let item = StatusItem(feed: feed)
            feed.onChange = { [weak item] in item?.update() }
            feed.start()
            h.finish(output)
            return item
        }

        func choose(_ title: String, in menu: NSMenu) {
            guard let entry = menu.items.first(where: { $0.title == title }) else { Issue.record("no \(title)"); return }
            NSApp.sendAction(entry.action!, to: entry.target, from: entry)
        }

        @Test func imageAndLabelFollowTheData() throws {
            let item = StatusItem(feed: feed)
            #expect(item.glance?.columns.isEmpty == true) // before the first result
            #expect(item.item.button?.accessibilityLabel() == "GlanceBar")
            feed.onChange = { [weak item] in item?.update() }
            feed.start()
            h.finish(Fixture.ownerShape)
            let button = try #require(item.item.button)
            #expect(item.glance?.columns.map(\.label) == ["1", "2", "3"])
            #expect(button.image?.isTemplate == false && button.image?.size.height == 22)
            #expect(button.accessibilityLabel() == "1: spend 7 dollars 34 of 1500 dollars, resets in 28 days. "
                    + "2: 5 hour 25 percent, resets in 4h 28m; 7 day 61 percent, resets in 18h 8m. "
                    + "3: 5 hour 0 percent, idle; 7 day 17 percent, resets in 4d 9h.")
            #expect(item.columnExtents.count == 3)

            // Same rendered content: the image is not reassigned (R-13).
            let image = button.image
            feed.trigger("again")
            h.finish(Fixture.ownerShape)
            #expect(button.image === image)
            item.update()
            #expect(button.image === image)

            // An app-wide error replaces the columns only when there is no last good data.
            feed.trigger("broken")
            h.finish(Fixture.schema2)
            #expect(button.image === image)
        }

        /// DD-14 hit-testing with the larger text: each column's extent is its content ± 4 pt and columns are 8 pt
        /// apart, so neighbouring extents meet exactly and the last one ends 4 pt past the image's content.
        @Test func columnExtentsTileTheImage() {
            for data in [Fixture.fiveAccounts, Fixture.withDollars, Fixture.ownerShape] {
                let layout = Glance(SnapshotTests.columns(data), dev: true).layout
                for (a, b) in zip(layout.extents, layout.extents.dropFirst()) {
                    #expect(a.upperBound == b.lowerBound && b.upperBound - b.lowerBound > 8)
                }
                #expect(abs((layout.extents.last?.upperBound ?? 0) - 4 - (layout.width - 1)) < 1) // ceil + 1 pt padding
            }
        }

        @Test func appWideErrorLabel() {
            h.installed = false
            let item = StatusItem(feed: feed)
            feed.onChange = { [weak item] in item?.update() }
            feed.start()
            #expect(item.glance?.columns.map(\.label) == ["cswap"])
            #expect(item.item.button?.accessibilityLabel() == "cswap: cswap not found.")
        }

        func top(_ item: StatusItem) -> String? {
            item.glance?.columns.first.map { if case let .bars(_, _, top, _, _) = $0.body { top } else { "" } }
        }

        @Test func countdownTimerTracksTheNextLabelChange() throws {
            let item = item(Fixture.midSession) // 5h resets in exactly 3h 12m: "3h12" turns "3h11" right after now
            let button = try #require(item.item.button)
            #expect(top(item) == "3h12")
            #expect(h.armed.contains { abs($0 - 0.001) < 0.0001 })
            let countdown = try #require(h.scheduler.pending.first)
            #expect(countdown.tolerance <= 5)
            let before = button.image
            h.advance(0.01)
            #expect(top(item) == "3h11")
            #expect(button.image !== before)
            #expect(h.armed.filter { $0 < 61 }.count == 1) // one countdown timer, at the next minute boundary
            #expect(h.armed.contains { abs($0 - 59.991) < 0.0001 })
            h.advance(60)
            #expect(top(item) == "3h10")
            // Each arm is logged (R-13): at the first label change, then every minute boundary.
            #expect(h.log.contains("countdown: armed in 0 s\n") && h.log.components(separatedBy: "countdown: armed in 60 s\n").count == 3)
        }

        @Test func resetPassingTriggersOneRun() {
            h.writeUsage([2: ["fetchedAt": Fixture.epoch(0), "nextPollAt": Fixture.epoch(6 * 3600)],
                          3: ["fetchedAt": Fixture.epoch(0), "nextPollAt": Fixture.epoch(6 * 3600)]])
            let item = item(Fixture.midSession) // 5h resets at +3h 12m; the next poll is at +6 h
            h.advance(3 * 3600 + 12 * 60 - 1)
            #expect(h.runs == 1)
            h.advance(2)
            #expect(h.runs == 2)
            #expect(h.log.contains("run: trigger reset passed"))
            #expect(top(item) == "idle")
            h.finish(Fixture.midSession) // cswap still reports the same (passed) reset: no second run
            h.advance(60)
            #expect(h.runs == 2)
        }

        @Test func pauseCancelsTheCountdownAndResumeRedraws() throws {
            let item = item(Fixture.midSession)
            feed.pause()
            item.pause()
            #expect(h.armed.isEmpty)
            h.advance(2 * 3600)
            #expect(top(item) == "3h12")
            item.resume()
            #expect(top(item) == "1h12")
        }

        @Test func appearanceAndContrastChangeTheImage() throws {
            let item = item()
            let button = try #require(item.item.button)
            let image = button.image
            h.ws.contrast = true
            item.update()
            #expect(button.image !== image)
            #expect(item.glance?.style.contrast == true)
            Style.appearanceOverride = NSAppearance(named: .darkAqua)
            item.update()
            #expect(item.glance?.style.dark == true)
            item.handle(mouseUp(.leftMouseUp)) // opens the panel
            move(item, to: 1)
            #expect(item.glance?.highlighted == true && item.glance?.hot == 1)
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.glance?.hot == nil && item.glance?.highlighted == false)
        }

        @Test func clickRouting() {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            item.handle(nil)
            #expect(h.popUps.isEmpty) // left click toggles the panel, never the menu
            item.handle(mouseUp(.rightMouseUp))
            item.handle(mouseUp(.leftMouseUp, flags: .control))
            #expect(h.popUps.count == 2)
            #expect(item.item.menu == nil) // never a permanent menu (DD-10)
            #expect(StatusItem.isMenuClick(mouseUp(.rightMouseDown)))
            #expect(!StatusItem.isMenuClick(mouseUp(.leftMouseUp, flags: .command)))
            item.perform(NSSelectorFromString("clicked")) // no current event: a left click
            #expect(h.popUps.count == 2)
        }

        // MARK: Hover panel (R-15–R-21)

        func shown(_ item: StatusItem) -> Bool { (item.panel as? OffscreenPanel)?.shown == true }
        func enter(_ item: StatusItem) { item.itemTracker.mouseEntered(with: pointer(.mouseEntered)) }
        func exit(_ item: StatusItem) { item.itemTracker.mouseExited(with: pointer(.mouseExited)) }

        /// Moves the pointer over column `index` (or to button x `x`), through the item's tracking area.
        func move(_ item: StatusItem, to index: Int? = nil, x: CGFloat? = nil) {
            let button = item.item.button!
            let offset = max(0, (button.bounds.width - (item.glance?.layout.width ?? 0)) / 2)
            let e = index.map { item.columnExtents[$0] }
            item.itemTracker.mouseMoved(with: pointer(x: x ?? (e!.lowerBound + e!.upperBound) / 2 + offset))
        }

        /// The first panel block's 5h or 7d time left.
        func long(_ item: StatusItem, fiveHour: Bool) -> String? {
            guard case let .subscription(f, d, _, _, _)? = item.panelView.panel?.columns.first?.kind else { return nil }
            return (fiveHour ? f : d)?.long
        }

        @Test func hoverOpensAfter300ms() {
            let item = item()
            enter(item)
            #expect(h.armed.contains { abs($0 - 0.3) < 0.0001 })
            h.advance(0.29)
            #expect(!item.panelOpen && !shown(item))
            h.advance(0.01)
            #expect(item.panelOpen && shown(item))
            #expect(item.glance?.highlighted == true)
            #expect(h.log.contains("panel: opened (hover)"))
            enter(item) // already open: nothing new is armed
            #expect(!h.armed.contains { abs($0 - 0.3) < 0.0001 })
        }

        @Test func sweepingAcrossNeverOpens() {
            let item = item()
            for _ in 0..<3 {
                enter(item)
                move(item, to: 0)
                h.advance(0.2)
                exit(item)
            }
            h.advance(5)
            #expect(!item.panelOpen && !shown(item))
            #expect(!h.log.contains("panel: opened"))
        }

        @Test func closesAfter400msGraceWithFade() {
            let item = item()
            enter(item)
            h.advance(0.3)
            exit(item)
            h.advance(0.39)
            #expect(item.panelOpen)
            enter(item) // back on the item: the close is cancelled
            h.advance(1)
            #expect(item.panelOpen)
            exit(item)
            h.advance(0.4)
            #expect(!item.panelOpen && item.glance?.highlighted == false)
            #expect(h.log.contains("panel: closed (pointer left)"))
            #expect(shown(item)) // fading out for 120 ms
            #expect(h.armed.contains { abs($0 - 0.12) < 0.0001 })
            h.advance(0.12)
            #expect(!shown(item))
        }

        @Test func movingIntoThePanelKeepsItOpen() {
            let item = item()
            enter(item)
            h.advance(0.3)
            exit(item)
            h.advance(0.2)
            item.panelTracker.mouseEntered(with: pointer(.mouseEntered))
            item.panelTracker.mouseMoved(with: pointer())
            h.advance(5)
            #expect(item.panelOpen)
            item.panelTracker.mouseExited(with: pointer(.mouseExited))
            h.advance(0.39)
            #expect(item.panelOpen)
            h.advance(0.01)
            #expect(!item.panelOpen)
        }

        @Test func clickToggles() {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.panelOpen && shown(item))
            #expect(h.log.contains("panel: opened (click)"))
            item.handle(mouseUp(.leftMouseUp))
            #expect(!item.panelOpen)
            #expect(h.log.contains("panel: closed (click)"))
            item.handle(mouseUp(.leftMouseUp)) // re-opened during the fade-out: stays up
            h.advance(1)
            #expect(item.panelOpen && shown(item))

            // A click while hover has it open closes it; resting on the item doesn't re-open it.
            item.handle(mouseUp(.leftMouseUp))
            h.advance(1)
            enter(item)
            h.advance(0.3)
            #expect(item.panelOpen)
            item.handle(mouseUp(.leftMouseUp))
            h.advance(5)
            #expect(!item.panelOpen && !shown(item))
            #expect(h.armed.allSatisfy { $0 > 0.5 }) // no hover timers left
        }

        @Test func rightClickClosesThePanelFirst() {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            item.handle(mouseUp(.rightMouseUp))
            #expect(!item.panelOpen && !shown(item)) // at once, no fade
            #expect(h.popUps.count == 1)
            #expect(h.log.contains("panel: closed (menu)"))
            #expect(item.item.menu == nil)
        }

        /// The right-click menu follows the system's light/dark setting, not the (wallpaper-tinted) menu bar's.
        @Test func menuFollowsTheSystemAppearance() throws {
            Style.appearanceOverride = NSAppearance(named: .darkAqua) // a dark menu bar on a light system
            let item = item()
            item.handle(mouseUp(.rightMouseUp))
            #expect(try #require(h.popUps.last).appearance?.name == .aqua)
            #expect(item.glance?.style.dark == true) // the image keeps following the menu bar (DD-7)
            h.systemAppearance = NSAppearance(named: .darkAqua)!
            item.handle(mouseUp(.leftMouseUp, flags: .control))
            #expect(try #require(h.popUps.last).appearance?.name == .darkAqua)
        }

        /// A mouse-down in another app closes the panel; the monitor exists only while the panel is open.
        @Test func clickOutsideCloses() {
            let item = item()
            #expect(h.clickMonitor == nil)
            enter(item) // hover-opened
            h.advance(0.3)
            #expect(item.panelOpen && h.clickMonitor != nil && h.monitorInstalls == 1)
            h.clickOutside()
            #expect(!item.panelOpen && h.clickMonitor == nil)
            #expect(h.log.contains("panel: closed (clicked outside)"))
            #expect(shown(item) && h.armed.contains { abs($0 - 0.12) < 0.0001 }) // the normal fade
            h.advance(0.12)
            #expect(!shown(item))
            h.clickOutside() // closed: nothing listens
            #expect(h.monitorInstalls == 1)

            // Click-opened, under Reduce Motion: closes at once.
            h.ws.still = true
            item.handle(mouseUp(.leftMouseUp))
            #expect(h.clickMonitor != nil && h.monitorInstalls == 2)
            h.clickOutside()
            #expect(!item.panelOpen && !shown(item))

            // Every other close path removes the monitor too.
            let closes: [() -> Void] = [
                { item.handle(mouseUp(.leftMouseUp)) },
                { item.handle(mouseUp(.rightMouseUp)) },
                { exit(item); h.advance(0.4) },
                { h.ws.center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) },
                { h.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) },
                { item.pause(); item.resume() },
            ]
            for close in closes {
                item.handle(mouseUp(.leftMouseUp))
                #expect(item.panelOpen && h.clickMonitor != nil)
                close()
                #expect(!item.panelOpen && h.clickMonitor == nil)
            }
            #expect(h.monitorInstalls == 2 + closes.count)
        }

        @Test func highlightFollowsThePointer() throws {
            let item = item(Fixture.fiveAccounts)
            enter(item)
            move(item, to: 2) // before opening: remembered
            h.advance(0.3)
            #expect(item.hotColumn == 2 && item.glance?.hot == 2 && item.panelView.panel?.hot == 2)
            move(item, to: 4)
            #expect(item.glance?.hot == 4 && item.panelView.panel?.hot == 4)
            move(item, x: -50) // outside every column: the last one stays hot
            #expect(item.glance?.hot == 4)
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.glance?.hot == nil && item.hotColumn == nil)
        }

        @Test func neverBecomesKey() throws {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            let panel = try #require(item.panel)
            #expect(!panel.canBecomeKey && !panel.canBecomeMain)
            #expect(panel.styleMask == [.borderless, .nonactivatingPanel])
            panel.makeKey()
            #expect(!panel.isKeyWindow)
            #expect(panel.level == .popUpMenu)
            #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
            #expect(!panel.hidesOnDeactivate && !panel.isOpaque && panel.hasShadow)
        }

        @Test func placementAndReduceMotion() throws {
            h.ws.still = true
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            let panel = try #require(item.panel)
            func box() -> CGRect { panel.frame } // the window is the box
            // R-19: right-aligned to the item, 6 pt below its window; instant under Reduce Motion (R-20).
            #expect(box().maxX == h.itemFrame.maxX && box().maxY == h.itemFrame.minY - 6)
            #expect(panel.alphaValue == 1)
            item.handle(mouseUp(.leftMouseUp))
            #expect(!shown(item) && !h.armed.contains { abs($0 - 0.12) < 0.0001 }) // closed at once, no fade timer

            // Clamped 8 pt from the visible frame's edges.
            #expect(StatusItem.placement(size: CGSize(width: 354, height: 100), item: CGRect(x: 20, y: 1093, width: 40, height: 24),
                                         visible: h.visibleFrame).minX == 8)
            #expect(StatusItem.placement(size: CGSize(width: 354, height: 100), item: CGRect(x: 1700, y: 1093, width: 40, height: 24),
                                         visible: h.visibleFrame).maxX == 1720)
            #expect(StatusItem.placement(size: CGSize(width: 354, height: 100), item: CGRect(x: 1700, y: 1050, width: 40, height: 37),
                                         visible: CGRect(x: 1728, y: 0, width: 1512, height: 1050)) == CGRect(x: 1736, y: 944, width: 354, height: 100))
        }

        @Test func fadeSlidesDownIntoPlace() throws {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            let panel = try #require(item.panel)
            #expect(shown(item))
            // The animator moves it 4 pt down into place over 120 ms; no timer is armed for the open.
            #expect(!h.armed.contains { abs($0 - 0.12) < 0.0001 })
            let placed = StatusItem.placement(size: item.panelView.frame.size, item: h.itemFrame, visible: h.visibleFrame)
            let open = try #require(h.animations.last)
            #expect(open.startFrame == placed.offsetBy(dx: 0, dy: 4) && open.startAlpha == 0)
            #expect(open.endFrame == placed && open.endAlpha == 1)
            #expect(panel.frame == placed && panel.frame.width == PanelView.width)

            item.handle(mouseUp(.leftMouseUp)) // the close fades out moving back up 4 pt
            let close = try #require(h.animations.last)
            #expect(h.animations.count == 2)
            #expect(close.startFrame == placed && close.startAlpha == 1)
            #expect(close.endFrame == placed.offsetBy(dx: 0, dy: 4) && close.endAlpha == 0)
        }

        /// Clicks beside or below the box reach the app underneath: the window is exactly the box and its shadow is
        /// the native one (which never catches clicks), so no transparent or shadow pixels belong to GlanceBar. That
        /// click then goes to another app, which the outside-click monitor sees.
        @Test func clicksBesideTheBoxPassThrough() throws {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            let panel = try #require(item.panel)
            #expect(panel.hasShadow && !panel.ignoresMouseEvents)
            #expect(panel.frame.size == item.panelView.frame.size && item.panelView.box.frame == item.panelView.bounds)
            #expect(panel.frame == StatusItem.placement(size: panel.frame.size, item: h.itemFrame, visible: h.visibleFrame))
            h.clickOutside() // e.g. 10 pt below the box, where the shadow is drawn
            #expect(!item.panelOpen && h.log.contains("panel: closed (clicked outside)"))
        }

        /// R-19 on every open: the animated close leaves the frame 4 pt up, and reopening with unchanged content
        /// must not start from there (no creep), nor from a frame placed for an item or screen that has moved.
        @Test func reopeningPlacesThePanelAgain() throws {
            let item = item()
            func box() throws -> CGRect { try #require(item.panel).frame } // the window is the box
            item.handle(mouseUp(.leftMouseUp))
            let first = try box()
            #expect(first.maxY == h.itemFrame.minY - 6 && first.maxX == h.itemFrame.maxX)
            for _ in 0..<3 {
                item.handle(mouseUp(.leftMouseUp)) // animated close: fades out moving up 4 pt
                #expect(try box().maxY == h.itemFrame.minY - 2)
                h.advance(0.13) // past the fade: ordered out
                #expect(!shown(item))
                item.handle(mouseUp(.leftMouseUp)) // same content, so refreshPanel doesn't place it
                #expect(try box() == first)
            }

            // The item moved (another status item appeared) and the screen changed between opens.
            item.handle(mouseUp(.leftMouseUp))
            h.advance(0.13)
            h.itemFrame = CGRect(x: 1700, y: 1050, width: 40, height: 37)
            h.visibleFrame = CGRect(x: 1728, y: 0, width: 1512, height: 1050)
            item.handle(mouseUp(.leftMouseUp))
            let moved = try box()
            #expect(moved.maxY == 1050 - 6 && moved.minX == 1736) // clamped 8 pt inside the new visible frame
        }

        @Test func closesOnPauseSpaceAndScreenChanges() {
            let item = item()
            item.handle(mouseUp(.leftMouseUp))
            h.ws.center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            #expect(!item.panelOpen && !shown(item))
            #expect(h.log.contains("panel: closed (space changed)"))

            item.handle(mouseUp(.leftMouseUp))
            h.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(!item.panelOpen && !shown(item))
            #expect(h.log.contains("panel: closed (screens changed)"))

            // Pause: the panel closes at once (also mid-fade), hover timers go; nothing re-opens while not visible.
            item.handle(mouseUp(.leftMouseUp))
            item.handle(mouseUp(.leftMouseUp)) // fading out
            enter(item)
            feed.pause()
            item.pause()
            #expect(!shown(item) && h.armed.isEmpty)
            item.handle(mouseUp(.leftMouseUp))
            enter(item)
            #expect(!item.panelOpen && h.armed.isEmpty)

            item.resume()
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.panelOpen)
            item.pause()
            #expect(!item.panelOpen && !shown(item) && h.log.contains("panel: closed (not visible)"))
        }

        @Test func openRefreshesOnlyAfter30s() {
            let item = item() // run 1 finished at now
            h.advance(10)
            item.handle(mouseUp(.leftMouseUp))
            #expect(h.runs == 1)
            #expect(h.log.contains("run: panel opened skipped (last run < 30 s ago)"))
            item.handle(mouseUp(.leftMouseUp))
            h.advance(21)
            enter(item)
            h.advance(0.3)
            #expect(h.runs == 2) // exactly one refresh for this open
            #expect(h.log.components(separatedBy: "run: trigger panel opened").count == 2)
            h.finish(Fixture.midSession)
            // New data while open updates the panel in place.
            #expect(item.panelOpen)
            #expect(long(item, fiveHour: true) == "3h 11m") // 31.3 s after the fixture's 3h 12m
            item.handle(mouseUp(.leftMouseUp))
            item.handle(mouseUp(.leftMouseUp))
            #expect(h.runs == 2)
        }

        @Test func countdownCoversThePanelWhileOpen() throws {
            let item = item() // gm's 7d: "18h" in the image (next change in 34 min), "18h 34m" in the panel
            h.advance(1) // past hm's "4d9h" → "4d8h"
            #expect(!h.armed.contains { $0 < 100 })
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.panelView.panel?.footer == "Updated 3m ago" && long(item, fiveHour: false) == "18h 33m")
            #expect(h.armed.contains { abs($0 - 59) < 0.01 }) // "18h 33m" → "18h 32m" and the footer's 4th minute, together
            h.advance(59.01)
            #expect(item.panelView.panel?.footer == "Updated 4m ago" && long(item, fiveHour: false) == "18h 32m")
            item.handle(mouseUp(.leftMouseUp))
            #expect(!h.armed.contains { $0 > 1 && $0 < 100 }) // closed: back to the image's labels only (and the fade)
        }

        @Test func panelContentAndAccessibility() throws {
            let item = item(Fixture.fiveAccounts)
            item.handle(mouseUp(.leftMouseUp))
            let blocks = item.panelView.box.subviews
            #expect(blocks.count == 6) // five accounts and the footer
            #expect(blocks.first?.accessibilityRole() == .group)
            #expect(blocks.first?.accessibilityLabel() == "gm, person-2@example.com, active. 5h 0%, idle, starts with your next message. "
                    + "7d 58%, 18h 34m · 5 Oct 09:00. Week: 31 pts under pace")
            #expect(blocks[3].accessibilityLabel() == "w2, person-5@example.com, slot 5. ! Re-login needed. "
                    + "refresh token dead; log in with Claude Code, then run: cswap add")
            #expect(blocks.last?.accessibilityLabel() == "Updated 3m ago")
            #expect(item.panelView.effect.state == .active && item.panelView.effect.material == .menu)

            // App-wide error: one error block and no footer (nothing measured).
            h.installed = false
            let broken = StatusItem(feed: Feed())
            broken.handle(mouseUp(.leftMouseUp))
            #expect(broken.panelView.box.subviews.count == 0) // no result yet: nothing to show
            let feed2 = Feed()
            let item2 = StatusItem(feed: feed2)
            feed2.onChange = { [weak item2] in item2?.update() }
            feed2.start()
            item2.handle(mouseUp(.leftMouseUp))
            #expect(item2.panelView.panel?.footer == nil)
            #expect(item2.panelView.box.subviews.map { $0.accessibilityLabel() } == ["cswap. ! cswap not found. Install claude-swap: uv tool install claude-swap"])
        }

        @Test func rightClickMenu() {
            let item = item()
            let menu = item.makeMenu()
            #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }.dropFirst(2)
                    == ["Launch at Login", "Automatic Updates", "Check for Updates…", "-", "Quit GlanceBar"])
            #expect(menu.items.first?.title.hasPrefix("GlanceBar Dev ") == true && menu.items.first?.isEnabled == false)

            // Launch at Login: registering may need approval in System Settings; on again unregisters.
            choose("Launch at Login", in: menu)
            #expect(h.loginCalls == ["register", "settings"])
            choose("Launch at Login", in: menu) // requires approval: settings again
            h.loginStatus = .enabled
            #expect(item.makeMenu().items.first { $0.title == "Launch at Login" }?.state == .on)
            choose("Launch at Login", in: menu)
            h.loginError = CocoaError(.featureUnsupported)
            choose("Launch at Login", in: menu)
            #expect(h.loginCalls == ["register", "settings", "settings", "unregister", "register"])
            #expect(h.log.contains("launch at login failed"))

            // Updates: a development build can't update.
            choose("Check for Updates…", in: menu)
            #expect(h.notices == ["Updates unavailable"])
            choose("Automatic Updates", in: menu)
            #expect(!Updater.isEnabled)
            #expect(item.makeMenu().items.first { $0.title == "Automatic Updates" }?.state == .off)
            choose("Automatic Updates", in: menu)
            #expect(Updater.isEnabled)

            choose("Quit GlanceBar", in: menu)
            #expect(h.terminations == 1)
        }
    }

    @MainActor @Suite struct AppTests {
        let h = Harness()

        func launch() -> AppDelegate {
            let app = AppDelegate()
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            return app
        }

        @Test func visibilityGate() throws {
            h.writeUsage([:])
            let app = launch()
            #expect(app.visible && h.runs == 1)
            h.finish()

            // Each condition alone hides GlanceBar: no runs, no timers.
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                         NSWorkspace.sessionDidResignActiveNotification] {
                h.ws.center.post(name: name, object: nil)
                #expect(!app.visible && app.feed.paused && app.statusItem.paused)
                #expect(h.armed.isEmpty)
                let back = [NSWorkspace.willSleepNotification: NSWorkspace.didWakeNotification,
                            NSWorkspace.screensDidSleepNotification: NSWorkspace.screensDidWakeNotification,
                            NSWorkspace.sessionDidResignActiveNotification: NSWorkspace.sessionDidBecomeActiveNotification][name]!
                h.ws.center.post(name: back, object: nil)
                #expect(app.visible && !app.feed.paused)
                h.advance(5)
                h.finish()
            }
            h.distributed.post(name: AppDelegate.locked, object: nil)
            #expect(!app.visible)
            h.ws.center.post(name: NSWorkspace.willSleepNotification, object: nil) // still hidden: nothing changes
            h.ws.center.post(name: NSWorkspace.didWakeNotification, object: nil)
            #expect(!app.visible)
            h.distributed.post(name: AppDelegate.unlockedName, object: nil)
            #expect(app.visible)
            h.advance(5)
            #expect(h.runs == 5) // launch + one per return
            #expect(h.log.contains("visibility: hidden (com.apple.screenIsLocked)"))
            h.finish()
            let image = app.statusItem.item.button?.image
            h.distributed.post(name: Notification.Name("com.apple.other"), object: nil)
            #expect(app.statusItem.item.button?.image === image)
        }

        @Test func lockedAtLaunch() {
            h.locked = true
            let app = launch()
            #expect(!app.visible && h.runs == 0)
            h.locked = false
            h.distributed.post(name: AppDelegate.unlockedName, object: nil)
            h.advance(5)
            #expect(h.runs == 1)
            #expect(h.log.contains("visibility: hidden at launch"))
        }

        @Test func displaysAsleepAtLaunch() {
            h.displaysAsleep = true
            let app = launch()
            #expect(!app.visible && h.runs == 0)
        }

        @Test func redrawTriggers() throws {
            let app = launch()
            h.finish()
            let button = try #require(app.statusItem.item.button)
            let image = button.image
            h.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(button.image === image) // nothing visible changed
            h.ws.contrast = true
            h.ws.center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            #expect(button.image !== image)
            h.now = h.now.addingTimeInterval(3600) // the clock jumped
            h.center.post(name: .NSSystemClockDidChange, object: nil)
            #expect(app.statusItem.glance?.columns.first.map { if case let .bars(_, _, _, bottom, _) = $0.body { bottom } else { "" } } == "17h")
        }

        @Test func eventLog() {
            EventLog.write("hello")
            #expect(h.log.contains(" hello\n"))
            EventLog.removeFile()
            #expect(!FileManager.default.fileExists(atPath: EventLog.url.path))
        }
    }
}
