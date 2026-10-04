import AppKit

private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// The artifact's colour tokens (UI/UX Wireframes → Colour tokens), literal per menu-bar appearance (DD-7), with the
/// Increase Contrast / Reduce Transparency variants (DD-9). Resolved per draw (the FancyMacZones `ZoneStyle` pattern).
struct Style: Equatable {
    var dark = false
    var contrast = false
    var reduceTransparency = false

    /// Seam: snapshot tests pin the drawing appearance; nil in production (the drawing appearance is used).
    static var appearanceOverride: NSAppearance?

    static func current(for appearance: NSAppearance) -> Style {
        let ws = Env.workspace
        return Style(dark: (appearanceOverride ?? appearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                     contrast: ws.accessibilityDisplayShouldIncreaseContrast,
                     reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency)
    }

    var fg: NSColor { dark ? rgba(0xf5, 0xf5, 0xf7) : rgba(0x1d, 0x1d, 0x1f) }
    // Owner deviation from the artifact's 0.58 / 0.55 (0.75 contrast): the macOS 26 menu bar is see-through, so the
    // wallpaper shows through; 0.80 / 0.78 keeps light-bar text above 4.5 : 1 on a flat bar.
    var dim: NSColor { dark ? rgba(245, 245, 247, contrast ? 0.92 : 0.80) : rgba(29, 29, 31, contrast ? 0.92 : 0.78) }
    var track: NSColor { dark ? rgba(255, 255, 255, contrast ? 0.32 : 0.2) : rgba(0, 0, 0, contrast ? 0.26 : 0.14) }
    var hot: NSColor { dark ? rgba(255, 255, 255, 0.08) : rgba(0, 0, 0, 0.05) }
    var sep: NSColor { dark ? rgba(255, 255, 255, contrast ? 0.4 : 0.12) : rgba(0, 0, 0, contrast ? 0.4 : 0.1) }
    var panel: NSColor { dark ? rgba(36, 38, 48, reduceTransparency ? 1 : 0.86) : rgba(250, 250, 252, reduceTransparency ? 1 : 0.9) }

    func color(_ level: Level) -> NSColor {
        switch level {
        case .ok: dark ? rgba(0x30, 0xd1, 0x58) : rgba(0x1f, 0x9d, 0x48)
        case .warn: dark ? rgba(0xff, 0xb3, 0x40) : rgba(0xc7, 0x77, 0x00)
        case .crit: dark ? rgba(0xff, 0x5a, 0x4f) : rgba(0xd9, 0x2d, 0x20)
        }
    }
}

/// A pure value describing the status image (R-13): only what the image shows, so it changes only when the drawn
/// content would. Drawn exactly as the artifact's `renderB` (UI/UX Wireframes → Status item image).
struct Glance: Equatable {
    enum Body: Equatable {
        case bars(fiveHour: Meter?, sevenDay: Meter?, top: String, bottom: String, pie: Meter?)
        case spend(symbol: String, meter: Meter, top: String, bottom: String)
        case pill(symbol: String)
        case error
    }

    struct Col: Equatable {
        var label: String
        var active: Bool
        var body: Body
    }

    var columns: [Col]
    var hot: Int? = nil           // the hovered column's hot rect (R-18, DD-14)
    var highlighted = false       // the open-panel item highlight (DD-14)
    var dev = false               // the Dev builds' "DEV" label (DD-14)
    var style = Style()           // the appearance the image was built for (DD-5)

    init(_ columns: [Column], hot: Int? = nil, highlighted: Bool = false, dev: Bool = false, style: Style = Style()) {
        self.columns = columns.map { c in
            let body: Body = switch c.kind {
            case let .subscription(fiveHour, sevenDay, extra, _, _):
                .bars(fiveHour: fiveHour?.meter, sevenDay: sevenDay?.meter, top: fiveHour?.compact ?? "",
                      bottom: sevenDay?.compact ?? "", pie: extra.flatMap { $0.spent ? $0.meter : nil })
            case .spendCap(let s): .spend(symbol: s.symbol, meter: s.meter, top: s.whole, bottom: s.daysLeft)
            case .apiKey(let symbol): .pill(symbol: symbol)
            case .error: .error
            }
            return Col(label: c.label, active: c.active, body: body)
        }
        self.hot = hot
        self.highlighted = highlighted
        self.dev = dev
        self.style = style
    }

    // MARK: Metrics

    static let height: CGFloat = 22
    // Owner deviation from the artifact's 9 / 7.5 pt (readability): every text is ~1.4× larger (labels
    // 13 pt = the menu bar font, countdowns 11 pt = the largest two lines fit in 22 pt). Vertical metrics are
    // re-derived from the SF glyph boxes so each text is centred on what it labels and the image's middle is y 11.
    private static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold) // artifact 9; also "DEV"
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) // artifact 7.5
    private static let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) // artifact 7.5
    private static let dollarFont = NSFont.systemFont(ofSize: 11, weight: .bold) // artifact 8
    private static let pillFont = NSFont.systemFont(ofSize: 12, weight: .bold) // artifact 8.5
    private static let bangFont = NSFont.systemFont(ofSize: 12.5, weight: .bold) // artifact 9
    /// Label baseline: cap height 9.2 centred on y 11; descenders end at 18.3, clear of the active dot (centre 20.3).
    private static let labelBaseline: CGFloat = 15.6, dotY: CGFloat = 20.3
    /// The 5h and 7d bars (3.5 pt): centres 6.5 and 15.5, 9 pt apart (artifact 6.5) so the two 11 pt text lines
    /// beside them (digit ink 7.75 tall, ascenders 8.4) stay 0.6 pt apart; 11.5 pt would make them touch.
    private static let topBar: CGFloat = 4.75, bottomBar: CGFloat = 13.75
    /// Text baselines beside the bars: the digits' ink centre (3.9 above the baseline) on each bar's centre.
    private static let topLine: CGFloat = 10.4, bottomLine: CGFloat = 19.4

    /// Image width and each column's hit-test extent (content ± 4 pt) in image coordinates, which are the button's (DD-14).
    struct Layout: Equatable {
        var width: CGFloat
        var extents: [ClosedRange<CGFloat>]
    }

    var layout: Layout { walk(nil, nil) }

    /// The status image: non-template, 22 pt tall, drawn at draw time in the drawing appearance (DD-5), so each
    /// display's menu bar replica gets its own colours.
    func image() -> NSImage {
        let l = layout
        let image = NSImage(size: NSSize(width: l.width, height: Self.height), flipped: true) { _ in
            self.walk(Style.current(for: NSAppearance.currentDrawing()), l)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Drawing

    /// One pass over the columns as the artifact's `renderB`: measures only (`style` nil), or draws using the measured layout.
    @discardableResult
    private func walk(_ style: Style?, _ measured: Layout?) -> Layout {
        if let style, let measured {
            if highlighted { // the item highlight: fg at 16 % over the whole image
                fill(CGRect(x: 0, y: 0, width: measured.width, height: Self.height), 4, style.fg.withAlphaComponent(0.16))
            }
            if let hot, measured.extents.indices.contains(hot) {
                let e = measured.extents[hot]
                fill(CGRect(x: e.lowerBound + 1, y: 1, width: e.upperBound - e.lowerBound - 2, height: 20), 3, style.hot)
            }
        }
        var x: CGFloat = 1 // the artifact's 1 pt side padding
        if dev { x += text("DEV", x, Self.labelBaseline, Self.labelFont, style?.dim) + 8 }
        var extents: [ClosedRange<CGFloat>] = []
        for col in columns {
            let x0 = x
            let labelWidth = text(col.label, x, Self.labelBaseline, Self.labelFont, style?.fg)
            if let style, col.active {
                fill(CGRect(x: x + labelWidth / 2 - 1.3, y: Self.dotY - 1.3, width: 2.6, height: 2.6), 1.3, style.fg)
            }
            x += labelWidth + 3
            switch col.body {
            case let .bars(fiveHour, sevenDay, top, bottom, pie):
                if let style {
                    bar(x, Self.topBar, 22, fiveHour, style)
                    bar(x, Self.bottomBar, 22, sevenDay, style)
                }
                x += 25
                x += max(text(top, x, Self.topLine, Self.timeFont, style?.dim), text(bottom, x, Self.bottomLine, Self.timeFont, style?.dim))
                if let pie {
                    if let style { self.pie(CGPoint(x: x + 6.5, y: 11), 3.6, pie, style) }
                    x += 10.5
                }
            case let .spend(symbol, meter, top, bottom):
                // The `$` glyph (ink centre 3.88 above its baseline) centred on the bar (y 9–12.5), just left of it.
                text(symbol, x, 14.6, Self.dollarFont, style?.dim)
                if let style { bar(x + 8, 9, 16, meter, style) }
                x += 27
                x += max(text(top, x, Self.topLine, Self.amountFont, style?.fg), text(bottom, x, Self.bottomLine, Self.timeFont, style?.dim))
            case .pill(let symbol):
                if let style {
                    // Scaled with its glyph (artifact 21 × 11 for 8.5 pt), centred on y 11.
                    let path = NSBezierPath(roundedRect: CGRect(x: x + 0.5, y: 3.5, width: 28, height: 15), xRadius: 7.5, yRadius: 7.5)
                    path.lineWidth = 1
                    style.dim.setStroke()
                    path.stroke()
                }
                text(symbol, x + 14.5, 15.25, Self.pillFont, style?.dim, centred: true) // ink centre 4.25 above the baseline
                x += 29 // the pill only: no text lines follow (owner)
            case .error:
                if let style {
                    hatch(x, Self.topBar, 22, style)
                    hatch(x, Self.bottomBar, 22, style)
                }
                text("!", x + 25, 15.3, Self.bangFont, style?.color(.crit)) // ink centred on y 11
                x += 31
            }
            extents.append((x0 - 4)...(x + 4))
            x += 8
        }
        let end = columns.isEmpty && !dev ? x : x - 8
        return Layout(width: ceil(end) + 1, extents: extents)
    }

    /// Draws `s` with its baseline at `baseline` (flipped coordinates) when `color` is given; returns its width.
    @discardableResult
    private func text(_ s: String, _ x: CGFloat, _ baseline: CGFloat, _ font: NSFont, _ color: NSColor?, centred: Bool = false) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let string = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color ?? .clear])
        let width = string.size().width
        if color != nil { string.draw(at: CGPoint(x: centred ? x - width / 2 : x, y: baseline - font.ascender)) }
        return width
    }

    private func fill(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Track, level fill (never narrower than its height when > 0, R-10) and the 7d pace tick.
    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ m: Meter?, _ style: Style) {
        let h: CGFloat = 3.5
        fill(CGRect(x: x, y: y, width: w, height: h), h / 2, style.track)
        guard let m else { return }
        if m.fraction > 0 { fill(CGRect(x: x, y: y, width: Usage.fillWidth(m.fraction, width: w, height: h), height: h), h / 2, style.color(m.level)) }
        if let pace = m.pace {
            style.fg.setFill()
            CGRect(x: x + w * pace - 0.5, y: y - 1.5, width: 1, height: h + 3).fill()
        }
    }

    /// The error column's hatched track: track + 1.5 pt crit stripes every 4 pt from x + 2.
    private func hatch(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ style: Style) {
        fill(CGRect(x: x, y: y, width: w, height: 3.5), 1.75, style.track)
        style.color(.crit).setFill()
        for i in stride(from: CGFloat(2), to: w, by: 4) { CGRect(x: x + i, y: y, width: 1.5, height: 3.5).fill() }
    }

    /// The extra-usage pie: track disc, wedge clockwise from 12 o'clock; full disc at ≥ 100 %.
    private func pie(_ c: CGPoint, _ r: CGFloat, _ m: Meter, _ style: Style) {
        fill(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), r, style.track)
        style.color(m.level).setFill()
        if m.maxed {
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
        } else if m.shown > 0 {
            let path = NSBezierPath()
            path.move(to: c)
            path.line(to: CGPoint(x: c.x, y: c.y - r))
            // Flipped coordinates (y down): increasing angles run clockwise on screen.
            path.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * CGFloat(m.shown) / 100, clockwise: false)
            path.close()
            path.fill()
        }
    }
}

// MARK: - Hover panel (R-17, DD-6)

/// A pure value of what the panel shows, so its views are rebuilt only when the content changes (as `Glance`, R-13).
/// `footer` is nil when no column shows a measurement (app-wide error, only error or API-key columns): the footer
/// row is hidden then.
struct Panel: Equatable {
    var columns: [Column]
    var footer: String?
    var hot: Int?
    var style: Style
}

/// A flipped view that draws through a closure: the panel's box, account blocks and footer.
final class Drawn: NSView {
    var paint: (Drawn) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { paint(self) }
}

/// The panel's content view (the artifact's `.panel`, UI/UX Wireframes → Hover panel): a menu-material blur forced
/// active (the app is never active), and the box with the tint, border, account blocks and footer. The view and its
/// window are exactly the box: the shadow is the window's native one, which never catches clicks, so clicks beside
/// or below the box reach the app underneath (and close the panel through the outside-click monitor).
final class PanelView: NSView {
    /// The artifact's `.panel` is `width: 340px` content-box: 340 + 2 × 6 padding + 2 × 1 border.
    static let width: CGFloat = 354
    static let content: CGFloat = 340

    let effect = NSVisualEffectView()
    let box = Drawn()
    private(set) var panel: Panel?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = NSImage(size: NSSize(width: 21, height: 21), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            return true
        }
        effect.maskImage?.capInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        effect.maskImage?.resizingMode = .stretch
        addSubview(effect)
        addSubview(box)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilds the blocks and footer for `p` and resizes to fit: the box is `width` wide.
    func show(_ p: Panel) {
        panel = p
        let s = p.style
        box.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 7 // 1 px border + 6 pt padding
        for (i, c) in p.columns.enumerated() {
            let top: CGFloat = i > 0 ? 1 : 0 // `.acct + .acct` border-top
            let measured = Self.block(c, nil, top: top)
            let hot = p.hot == i
            let divider = i > 0 && p.hot != i && p.hot != i - 1 // hidden next to the hot block
            let view = Drawn(frame: CGRect(x: 7, y: y, width: Self.content, height: measured.height))
            view.paint = { view in
                let shape = NSBezierPath(roundedRect: view.bounds, xRadius: 6, yRadius: 6)
                if hot {
                    s.hot.setFill()
                    shape.fill()
                }
                if divider {
                    NSGraphicsContext.saveGraphicsState()
                    shape.addClip()
                    s.sep.setFill()
                    CGRect(x: 0, y: 0, width: view.bounds.width, height: 1).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                Self.block(c, s, top: top)
            }
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel(measured.texts.joined(separator: ". "))
            box.addSubview(view)
            y += measured.height + 2
        }
        if let footer = p.footer {
            let height = 1 + 6 + Self.lineHeight(11) + 4
            let view = Drawn(frame: CGRect(x: 7, y: y, width: Self.content, height: height))
            view.paint = { _ in
                s.sep.setFill()
                CGRect(x: 0, y: 0, width: Self.content, height: 1).fill()
                Self.text([(footer, Self.font(11), s.dim)], x: 8, top: 7, width: Self.content - 16)
            }
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.staticText)
            view.setAccessibilityLabel(footer)
            box.addSubview(view)
            y += height + 2
        }
        let boxHeight = (y - 2 + 7).rounded(.up) // whole points: the window (exactly the box) can't be fractional
        setFrameSize(NSSize(width: Self.width, height: boxHeight))
        box.frame = bounds
        effect.frame = box.frame
        effect.isHidden = s.reduceTransparency // DD-9: solid
        box.paint = { box in
            // The panel tint over the blur, then the 1 px sep border (radius 10).
            s.panel.setFill()
            NSBezierPath(roundedRect: box.bounds, xRadius: 10, yRadius: 10).fill()
            let border = NSBezierPath(roundedRect: box.bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
            border.lineWidth = 1
            s.sep.setStroke()
            border.stroke()
        }
        box.needsDisplay = true
        window?.invalidateShadow() // the native shadow follows the new shape
    }

    // MARK: Text in CSS line boxes (font size × 1.35)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, digits: Bool = false) -> NSFont {
        digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat { (size * 1.35 * 100).rounded() / 100 }

    /// From the line box's top to the baseline: half the leading plus the ascender, as the browser places it.
    static func baseline(_ font: NSFont) -> CGFloat {
        (lineHeight(font.pointSize) - (font.ascender - font.descender)) / 2 + font.ascender
    }

    /// Draws runs of text (the first run's font sets the line box) at `top`: one line truncated at the tail, or
    /// wrapped onto as many lines as needed. Measures only when every colour is nil. Returns the size used.
    @discardableResult
    static func text(_ runs: [(String, NSFont, NSColor?)], x: CGFloat, top: CGFloat, width: CGFloat,
                     wrap: Bool = false) -> CGSize {
        guard let first = runs.first?.1 else { return .zero }
        let lh = lineHeight(first.pointSize)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lh
        para.maximumLineHeight = lh
        para.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        let string = NSMutableAttributedString()
        for (s, font, color) in runs {
            string.append(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: color ?? .clear, .paragraphStyle: para,
                // TextKit puts a fixed line height's extra space above the glyphs; centre them as CSS does.
                .baselineOffset: (lh - (font.ascender - font.descender)) / 2,
            ]))
        }
        let natural = string.size().width
        let height = wrap ? string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin]).height.rounded(.up) : lh
        if runs.contains(where: { $0.2 != nil }) {
            string.draw(with: CGRect(x: x, y: top, width: width, height: max(height, lh)),
                        options: wrap ? [.usesLineFragmentOrigin] : [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        return CGSize(width: min(natural, width), height: max(height, lh))
    }

    // MARK: Account block (the artifact's `.acct`)

    /// Measures (style nil) or draws one account block: header, then the kind's rows, padding 8 and 4 pt between
    /// rows. Returns its height and the visible texts (the block's combined accessibility label, NFR-5).
    @discardableResult
    static func block(_ c: Column, _ s: Style?, top: CGFloat) -> (height: CGFloat, texts: [String]) {
        let inner = content - 16
        var texts: [String] = []
        var y = top + 8
        y += header(c, s, x: 8, top: y, width: inner, texts: &texts)

        func line(_ runs: [(String, NSFont, NSColor?)], indent: CGFloat = 0, wrap: Bool = false) {
            y += 4
            texts.append(runs.map(\.0).joined())
            y += text(runs, x: 8 + indent, top: y, width: inner - indent, wrap: wrap).height
        }
        func row(_ name: String, _ meter: Meter, _ rest: [(String, NSFont, NSColor?)], tail: [(String, NSFont, NSColor?)] = [],
                 percent: Bool = true) {
            y += 4
            let all = rest.map(\.0).joined() + (tail.isEmpty ? "" : " · " + tail.map(\.0).joined()) // spoken pause
            texts.append(name + (percent ? " \(meter.shown)%" : "") + (all.isEmpty ? "" : ", " + all))
            y += windowRow(name, meter, rest, tail, s, x: 8, top: y, percent: percent)
        }
        let dim = s?.dim, fg = s?.fg
        let small = font(12), medium = font(12, .medium, digits: true), plain = font(12, digits: true)
        func spendRow(_ r: SpendRow) {
            row(r.symbol, r.meter, [(r.used, medium, fg), (" of \(r.limit) · \(r.detail)", plain, dim)])
        }

        switch c.kind {
        case let .subscription(fiveHour, sevenDay, extra, scoped, pace):
            for w in Usage.panelWindows(fiveHour: fiveHour, sevenDay: sevenDay) {
                if w.long == Usage.fiveHourIdle || w.clock == nil {
                    row(w.name, w.meter, w.long.isEmpty ? [] : [(w.long, plain, w.long == Usage.fiveHourIdle ? dim : fg)],
                        percent: w.percent)
                } else {
                    row(w.name, w.meter, [(w.long, medium, fg)], tail: [(w.clock ?? "", plain, dim)], percent: w.percent)
                }
            }
            if let extra { spendRow(extra) }
            for w in scoped {
                row(w.name, w.meter, [(w.long, medium, fg)], tail: w.meter.maxed ? [("maxed", plain, dim)] : [])
            }
            if let pace {
                line([(pace.text, font(11), pace.ahead ? s?.color(.warn) : dim)], indent: 41)
            }
        case .spendCap(let r):
            spendRow(r)
        case .apiKey:
            line([(Usage.apiKeyLine, small, dim)])
        case .error(let p):
            line([("! " + p.error, font(12, .medium), s?.color(.crit))], wrap: true)
            line([(p.fix, small, dim)], wrap: true)
        }
        return (y + 8, texts)
    }

    /// The header (`.ahead`): label 13 pt semibold, email 12 pt dim truncated at the tail, chip; baseline-aligned,
    /// 8 pt apart. Returns its height.
    private static func header(_ c: Column, _ s: Style?, x: CGFloat, top: CGFloat, width: CGFloat, texts: inout [String]) -> CGFloat {
        let label = font(13, .semibold), email = font(12), chip = font(10.5, .semibold)
        let chipHeight = lineHeight(10.5) + 2
        let above = max(baseline(label), baseline(email), 1 + baseline(chip))
        let below = max(lineHeight(13) - baseline(label), lineHeight(12) - baseline(email), chipHeight - 1 - baseline(chip))
        let b = top + above
        texts.append([c.label, c.email, c.chip].filter { !$0.isEmpty }.joined(separator: ", "))
        let labelWidth = text([(c.label, label, s?.fg)], x: x, top: b - baseline(label), width: width).width
        var right = x + width
        if !c.chip.isEmpty {
            let w = text([(c.chip, chip, nil)], x: 0, top: 0, width: width).width + 12
            right -= w
            if let s {
                let pill = CGRect(x: right, y: b - 1 - baseline(chip), width: w, height: chipHeight)
                (c.active ? s.color(.ok).withAlphaComponent(0.22) : s.track).setFill()
                NSBezierPath(roundedRect: pill, xRadius: chipHeight / 2, yRadius: chipHeight / 2).fill()
                text([(c.chip, chip, s.fg)], x: right + 6, top: pill.minY + 1, width: w)
            }
            right -= 8
        }
        let left = x + labelWidth + 8
        if !c.email.isEmpty, right > left {
            text([(c.email, email, s?.dim)], x: left, top: b - baseline(email), width: right - left)
        }
        return above + below
    }

    /// A window row (`.win`): label 34 · bar 82 · percent · the rest (· the tail), 7 pt apart, centred in one 12 pt
    /// line box. Owner deviation: the percent is left-aligned in a column as wide as "100%" (the artifact's 34 px
    /// right-aligned cell is narrower than "100%"), and a tail ("19:20", "maxed", no "·") starts in its own column after
    /// the widest countdown, so every block's percents, countdowns and clocks start on the same x.
    static let percentWidth = text([("100%", font(12, .semibold, digits: true), nil)], x: 0, top: 0, width: 200).width.rounded(.up)
    static let countdownWidth = ["23h 59m", "6d 23h"].map {
        text([($0, font(12, .medium, digits: true), nil)], x: 0, top: 0, width: 200).width
    }.max()!.rounded(.up)

    private static func windowRow(_ name: String, _ m: Meter, _ rest: [(String, NSFont, NSColor?)],
                                  _ tail: [(String, NSFont, NSColor?)], _ s: Style?,
                                  x: CGFloat, top: CGFloat, percent: Bool) -> CGFloat {
        let lh = lineHeight(12)
        guard let s else { return lh }
        text([(name, font(12, digits: true), s.dim)], x: x, top: top, width: 200) // overflows like the artifact's grid cell
        let bar = CGRect(x: x + 41, y: top + (lh - 5) / 2, width: 82, height: 5)
        s.track.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if m.fraction > 0 {
            s.color(m.level).setFill()
            let fill = CGRect(x: bar.minX, y: bar.minY, width: Usage.fillWidth(m.fraction, width: 82, height: 5), height: 5)
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
        if let pace = m.pace { // 1.5 pt wide, 2 pt above and below, its left edge at the pace position
            s.fg.setFill()
            CGRect(x: bar.minX + 82 * pace, y: bar.minY - 2, width: 1.5, height: 9).fill()
        }
        if percent {
            text([("\(m.shown)%", font(12, .semibold, digits: true), s.fg)], x: x + 130, top: top, width: percentWidth + 1)
        }
        let restX = 130 + percentWidth + 7
        if !rest.isEmpty { text(rest, x: x + restX, top: top, width: content - 16 - restX) }
        let tailX = restX + countdownWidth + 7
        if !tail.isEmpty { text(tail, x: x + tailX, top: top, width: content - 16 - tailX) }
        return lh
    }
}
