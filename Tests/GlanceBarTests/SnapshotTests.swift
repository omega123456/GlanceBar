import AppKit
import SnapshotTesting
import Testing
@testable import GlanceBar

private let imageStrategy = Snapshotting<NSImage, NSImage>.image(precision: 0.99, perceptualPrecision: 0.98)

/// Offscreen renders of the status image for every fixture (Data & State → Test fixtures), compared with the PNGs in
/// __Snapshots__, plus the right-click menu as a text outline. Nothing is shown on screen; the appearance is pinned
/// through `Style.appearanceOverride` and the calendar (UTC) by the Harness.
extension Desktop {
    @MainActor @Suite struct SnapshotTests {
        enum Look { case dark, light, darkContrast, lightContrast }

        enum ImageCase: String, CaseIterable {
            case yoursNow, yoursNowLight, yoursNowContrast, yoursNowLightContrast, yoursNowNoDev
            case midSession, midSessionLight, midSessionContrast
            case withDollars, withDollarsLight, withDollarsContrast, withDollarsOpen
            case fiveAccounts, fiveAccountsLight, fiveAccountsContrast, fiveAccountsLightContrast, fiveAccountsOpen, fiveAccountsOpenLight
            case ownerShape, ownerShapeLight, ownerShapeContrast, ownerShapeOpen
            case transient, transientLight, transientContrast
            case cswapMissing, cswapMissingLight, cswapMissingContrast
            case envelope, envelopeLight, schema2, schema2Light, timeout, timeoutLight, zeroAccounts, zeroAccountsLight

            var look: Look {
                switch self {
                case .yoursNowLight, .midSessionLight, .withDollarsLight, .fiveAccountsLight, .fiveAccountsOpenLight,
                     .ownerShapeLight, .transientLight, .cswapMissingLight, .envelopeLight, .schema2Light, .timeoutLight,
                     .zeroAccountsLight: .light
                case .yoursNowContrast, .withDollarsContrast, .midSessionContrast, .fiveAccountsContrast, .ownerShapeContrast,
                     .transientContrast, .cswapMissingContrast: .darkContrast
                case .yoursNowLightContrast, .fiveAccountsLightContrast: .lightContrast
                default: .dark
                }
            }
        }

        /// The menu bar behind the image (the artifact's `--mb-bg` over its wallpaper, flattened).
        static func backdrop(_ look: Look) -> NSColor {
            switch look {
            case .dark, .darkContrast: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.24, alpha: 1)
            case .light, .lightContrast: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.94, alpha: 1)
            }
        }

        /// Draws the image at 2x over the backdrop, 4 pt margin, through AppKit's drawing-handler path.
        static func render(_ glance: Glance, _ look: Look) -> NSImage {
            let image = glance.image()
            let size = NSSize(width: image.size.width + 8, height: Glance.height + 8)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            backdrop(look).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: 4, y: 4, width: image.size.width, height: Glance.height))
            NSGraphicsContext.restoreGraphicsState()
            let out = NSImage(size: size)
            out.addRepresentation(rep)
            return out
        }

        @Test(arguments: ImageCase.allCases)
        func statusImage(_ c: ImageCase) {
            let h = Harness()
            h.ws.contrast = c.look == .darkContrast || c.look == .lightContrast
            Style.appearanceOverride = NSAppearance(named: c.look == .light || c.look == .lightContrast ? .aqua : .darkAqua)
            defer { Style.appearanceOverride = nil }
            let columns: [Column] = switch c {
            case .yoursNow, .yoursNowLight, .yoursNowContrast, .yoursNowLightContrast, .yoursNowNoDev: Self.columns(Fixture.yoursNow)
            case .midSession, .midSessionLight, .midSessionContrast: Self.columns(Fixture.midSession)
            case .withDollars, .withDollarsLight, .withDollarsContrast, .withDollarsOpen: Self.columns(Fixture.withDollars)
            case .fiveAccounts, .fiveAccountsLight, .fiveAccountsContrast, .fiveAccountsLightContrast, .fiveAccountsOpen,
                 .fiveAccountsOpenLight: Self.columns(Fixture.fiveAccounts)
            case .ownerShape, .ownerShapeLight, .ownerShapeContrast, .ownerShapeOpen: Self.columns(Fixture.ownerShape)
            case .transient, .transientLight, .transientContrast: Self.columns(Fixture.transient)
            case .cswapMissing, .cswapMissingLight, .cswapMissingContrast: Self.columns(failure: .notFound)
            case .envelope, .envelopeLight: Self.columns(Fixture.envelope)
            case .schema2, .schema2Light: Self.columns(Fixture.schema2)
            case .timeout, .timeoutLight: Self.columns(failure: .timedOut)
            case .zeroAccounts, .zeroAccountsLight: Self.columns(Fixture.zero)
            }
            // Open-panel highlight with a hot column: an error column, a spend-cap column, the API-key pill.
            let hot: Int? = switch c {
            case .fiveAccountsOpen, .fiveAccountsOpenLight: 3
            case .ownerShapeOpen: 0
            case .withDollarsOpen: 3
            default: nil
            }
            let glance = Glance(columns, hot: hot, highlighted: hot != nil,
                                dev: c != .yoursNowNoDev, style: Style.current(for: NSAppearance(named: .aqua)!))
            assertSnapshot(of: Self.render(glance, c.look), as: imageStrategy, named: c.rawValue, testName: "StatusImage")
        }

        /// The columns a fixture's run (or a failed run) shows at `Fixture.now`.
        nonisolated static func columns(_ data: Data? = nil, failure: Failure? = nil) -> [Column] {
            var snapshot: Snapshot?
            var failure = failure
            if let data {
                switch Usage.decode(data, at: Fixture.now) {
                case .success(let s): snapshot = s
                case .failure(let f): failure = f
                }
            }
            return Usage.columns(snapshot, failure: failure, now: Fixture.now)
        }

        /// The hover panel (R-17) for every fixture, in dark, light, Increase Contrast and Reduce Transparency, and
        /// with a hovered block (R-18).
        enum PanelCase: String, CaseIterable {
            case yoursNow, yoursNowLight, yoursNowContrast, yoursNowSolid, yoursNowSolidLight
            case midSession, midSessionLight
            case withDollars, withDollarsLight, withDollarsContrast
            case fiveAccounts, fiveAccountsLight, fiveAccountsContrast, fiveAccountsLightContrast, fiveAccountsSolid
            case fiveAccountsHot, fiveAccountsHotLight, fiveAccountsHotFirst
            case ownerShape, ownerShapeLight, ownerShapeHot
            case transient, transientLight
            case cswapMissing, cswapMissingLight, envelope, envelopeLight, schema2, schema2Light
            case timeout, timeoutLight, zeroAccounts, zeroAccountsLight
            case noFiveHour, noSevenDay

            var light: Bool { rawValue.contains("Light") }
            var contrast: Bool { rawValue.contains("Contrast") }
            var solid: Bool { rawValue.contains("Solid") }
            var hot: Int? {
                switch self {
                case .fiveAccountsHot, .fiveAccountsHotLight: 3 // the error block
                case .fiveAccountsHotFirst, .ownerShapeHot: 0
                default: nil
                }
            }
            var columns: [Column] {
                let name = rawValue.replacingOccurrences(of: "(Light|Contrast|Solid|Hot|First)+$", with: "", options: .regularExpression)
                return switch name {
                case "yoursNow": SnapshotTests.columns(Fixture.yoursNow)
                case "midSession": SnapshotTests.columns(Fixture.midSession)
                case "withDollars": SnapshotTests.columns(Fixture.withDollars)
                case "fiveAccounts": SnapshotTests.columns(Fixture.fiveAccounts)
                case "ownerShape": SnapshotTests.columns(Fixture.ownerShape)
                case "transient": SnapshotTests.columns(Fixture.transient)
                case "cswapMissing": SnapshotTests.columns(failure: .notFound)
                case "envelope": SnapshotTests.columns(Fixture.envelope)
                case "schema2": SnapshotTests.columns(Fixture.schema2)
                case "timeout": SnapshotTests.columns(failure: .timedOut)
                case "noFiveHour": SnapshotTests.columns(Fixture.noFiveHour)
                case "noSevenDay": SnapshotTests.columns(Fixture.noSevenDay)
                default: SnapshotTests.columns(Fixture.zero)
                }
            }
        }

        /// The panel's view (`PanelView.show`, the production path) drawn at 2x over a flat wallpaper colour.
        static func render(_ view: PanelView, light: Bool) -> NSImage {
            let size = view.bounds.size
            func bitmap() -> NSBitmapImageRep {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                return rep
            }
            let panel = bitmap(), out = bitmap()
            view.cacheDisplay(in: view.bounds, to: panel)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            (light ? NSColor(srgbRed: 0.75, green: 0.8, blue: 0.88, alpha: 1) : NSColor(srgbRed: 0.17, green: 0.2, blue: 0.32, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            panel.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size)
            image.addRepresentation(out)
            return image
        }

        @Test(arguments: PanelCase.allCases)
        func panel(_ c: PanelCase) {
            let h = Harness()
            h.ws.contrast = c.contrast
            h.ws.solid = c.solid
            let appearance = NSAppearance(named: c.light ? .aqua : .darkAqua)!
            Style.appearanceOverride = appearance
            defer { Style.appearanceOverride = nil }
            let columns = c.columns
            let view = PanelView()
            view.appearance = appearance
            view.show(Panel(columns: columns, footer: Usage.oldestMeasurement(columns).map { Usage.footer(measuredAt: $0, now: Fixture.now) },
                            hot: c.hot, style: Style.current(for: appearance)))
            assertSnapshot(of: Self.render(view, light: c.light), as: imageStrategy, named: c.rawValue, testName: "Panel")
        }

        /// NSMenu can't be drawn offscreen (it renders only while tracking on a real display), so the menu is
        /// compared as text: ✓ for on, (disabled), separators as ---.
        enum MenuCase: String, CaseIterable { case defaults, loginOnUpdatesOff }

        @Test(arguments: MenuCase.allCases)
        func menu(_ c: MenuCase) {
            let h = Harness()
            if c == .loginOnUpdatesOff {
                h.loginStatus = .enabled
                Updater.toggle()
            }
            let item = StatusItem(feed: Feed())
            assertSnapshot(of: Self.outline(item.makeMenu()), as: .lines, named: c.rawValue, testName: "Menu")
        }

        static func outline(_ menu: NSMenu) -> String {
            menu.items.map { item in
                if item.isSeparatorItem { return "---" }
                // The debug header carries the host bundle's version, which isn't ours under swift test.
                let title = item.title.hasPrefix("GlanceBar Dev ") ? "GlanceBar Dev <version> (debug)" : item.title
                return (item.state == .on ? "✓ " : "  ") + title + (item.isEnabled ? "" : " (disabled)")
            }.joined(separator: "\n")
        }
    }
}
