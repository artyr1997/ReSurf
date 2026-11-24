import AppKit

/// a view laid out from its top left, as a page is
class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// what a click does, for the controls that take a target
final class Do: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

// ── the side buttons: a word written down, letter under letter, in the window's corners ──

final class SideButton: NSView {
    let word: String
    let key: String?
    var action: () -> Void
    /// the top ones start a little lower, level with the others' first letters
    var top = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var title: String? { didSet { toolTip = title } }

    static let size: CGFloat = 20
    /// a letter and the space after it (0.6em)
    static let advance: CGFloat = 32
    static let width: CGFloat = 42

    private var hover = false { didSet { needsDisplay = true } }
    /// the one chosen: framed in the ink (on glass a frame means chosen)
    var chosen = false { didSet { needsDisplay = true } }
    /// a boxed one (BACK, READ, ADD…): tall, its word in the middle, filled with the ink when pointed at
    var boxed = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var enabled = true { didSet { alphaValue = enabled ? 1 : 0.3 } }

    init(_ word: String, as key: String? = nil, _ action: @escaping () -> Void) {
        self.word = word
        self.key = key
        self.action = action
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(forName: Lang.changed, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
            self?.invalidateIntrinsicContentSize()
            self?.superview?.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var shown: String { t(word, as: key) }

    var padTop: CGFloat { top ? Self.size * 0.55 : 0 }

    override var intrinsicContentSize: NSSize {
        if boxed { return NSSize(width: Self.width, height: max(164, 18 + CGFloat(shown.count) * Self.advance + 18 - Self.size * 0.6)) }
        return NSSize(width: Self.width, height: padTop + CGFloat(shown.count) * Self.advance)
    }

    override func draw(_ dirtyRect: NSRect) {
        let base: [NSAttributedString.Key: Any] = [
            .font: Fonts.buttons(Self.size),
            // the ink, a little faint until pointed at
            .foregroundColor: NSColor(white: 1, alpha: 0.8 * (hover || chosen ? 1 : 0.75)),
        ]
        var attrs = base
        var y = padTop
        if boxed {
            if hover {
                Ink.text.setFill()
                bounds.fill()
                attrs[.foregroundColor] = Ink.paper
            }
            y = (bounds.height - (CGFloat(shown.count) * Self.advance - Self.size * 0.6)) / 2
        }
        if chosen {
            Ink.text.setStroke()
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            frame.lineWidth = 1
            frame.stroke()
        }
        for letter in shown {
            let s = NSAttributedString(string: String(letter), attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y + (Self.size - size.height) / 2 + 1))
            y += Self.advance
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// ── the spaces' shapes: Feel a diamond, Body a square, Mind a pentagon, Soul a circle ──

enum Shape {
    /// the shape in a 16 × 16 box, laid in `rect` (flipped: y down)
    static func path(_ element: String, in rect: NSRect) -> NSBezierPath {
        let k = rect.width / 16
        let p = { (x: CGFloat, y: CGFloat) in NSPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        let path = NSBezierPath()
        switch element {
        case "water":
            path.move(to: p(8, 1)); path.line(to: p(15, 8)); path.line(to: p(8, 15)); path.line(to: p(1, 8)); path.close()
        case "earth":
            path.appendRect(NSRect(origin: p(2, 2), size: NSSize(width: 12 * k, height: 12 * k)))
        case "fire":
            path.move(to: p(8, 1.67)); path.line(to: p(14.66, 6.51)); path.line(to: p(12.11, 14.33))
            path.line(to: p(3.89, 14.33)); path.line(to: p(1.34, 6.51)); path.close()
        default:
            path.appendOval(in: NSRect(origin: p(1.75, 1.75), size: NSSize(width: 12.5 * k, height: 12.5 * k)))
        }
        path.lineJoinStyle = .miter
        return path
    }

    static func draw(_ element: String, in rect: NSRect, stroke width: CGFloat = 1.5, filled: Bool = false, color: NSColor = Ink.line) {
        let path = path(element, in: rect)
        color.set()
        if filled { path.fill() }
        path.lineWidth = width
        path.stroke()
    }
}

/// a space's shape on its own
final class ShapeView: Flipped {
    var element: String { didSet { needsDisplay = true } }
    var stroke: CGFloat = 1.5
    var filled = false { didSet { needsDisplay = true } }
    /// how much of the view the shape takes
    var share: CGFloat = 1

    init(_ element: String, stroke: CGFloat = 1.5) {
        self.element = element
        self.stroke = stroke
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height) * share
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        Shape.draw(element, in: rect, stroke: stroke, filled: filled)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// ── words ──

func attributed(_ s: String, _ font: NSFont, _ color: NSColor = Ink.text, kern: CGFloat = 0, align: NSTextAlignment? = nil) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if kern != 0 { attrs[.kern] = kern }
    if let align {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = p
    }
    return NSAttributedString(string: s, attributes: attrs)
}

func label(_ s: String, _ font: NSFont, _ color: NSColor = Ink.text, kern: CGFloat = 0, align: NSTextAlignment = .left) -> NSTextField {
    let field = NSTextField(labelWithAttributedString: attributed(s, font, color, kern: kern, align: align))
    // kept when its words change
    field.font = font
    field.textColor = color
    field.alignment = align
    field.lineBreakMode = .byTruncatingTail
    field.cell?.truncatesLastVisibleLine = true
    return field
}

/// a word in a frame, filled with the ink when pointed at (the popups' YES, NO, EXPORT)
final class BoxButton: NSView {
    private let word: String
    private let size: CGFloat
    private let kern: CGFloat
    private let pad: NSSize
    let action: () -> Void
    private var hover = false { didSet { needsDisplay = true } }

    init(_ word: String, size: CGFloat = 16, kern: CGFloat, pad: NSSize, _ action: @escaping () -> Void) {
        self.word = word
        self.size = size
        self.kern = kern
        self.pad = pad
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func text(_ color: NSColor) -> NSAttributedString { attributed(word, Fonts.buttons(size), color, kern: kern) }

    override var intrinsicContentSize: NSSize {
        let s = text(Ink.text).size()
        return NSSize(width: ceil(s.width) + pad.width * 2 + 4, height: ceil(s.height) + pad.height * 2 + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        if hover {
            Ink.line.setFill()
            box.fill()
        }
        let frame = NSBezierPath(rect: box)
        frame.lineWidth = 2
        Ink.line.setStroke()
        frame.stroke()
        let s = text(hover ? Ink.paper : Ink.text)
        let size = s.size()
        // the trailing letter space is not the word's: centred without it
        s.draw(at: NSPoint(x: (bounds.width - size.width + kern) / 2, y: (bounds.height - size.height) / 2))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// a word to click, nothing round it (the arrows under a note)
final class WordButton: NSView {
    var word: String { didSet { needsDisplay = true } }
    var font: NSFont { didSet { needsDisplay = true } }
    var action: () -> Void

    init(_ word: String, font: NSFont, _ action: @escaping () -> Void) {
        self.word = word
        self.font = font
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // in the middle, cut with … when longer than its place
        let s = attributed(word, font, align: .center)
        let h = s.size().height
        s.draw(with: NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

// ── a line to type in: no frame, its placeholder gone while it is typed in ──

final class Field: NSTextField, NSTextFieldDelegate {
    var placeholder = "" { didSet { showPlaceholder() } }
    var placeholderAlpha: CGFloat = 0.4
    var maxLength: Int?
    var onChange: (() -> Void)?

    init(size: CGFloat, align: NSTextAlignment) {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = Fonts.words(size)
        textColor = Ink.text
        alignment = align
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.lineBreakMode = .byClipping
        delegate = self
        NotificationCenter.default.addObserver(forName: Lang.changed, object: nil, queue: .main) { [weak self] _ in
            if let self, self.currentEditor() == nil { self.showPlaceholder() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // not in the key view loop: a window opening doesn't put the cursor here by itself (a click or focus() does)
    override var canBecomeKeyView: Bool { false }

    private func showPlaceholder() {
        // in the app's language (Search: 検索), as it turns
        placeholderAttributedString = attributed(tx(placeholder), font ?? Fonts.words(18), Ink.line.withAlphaComponent(0.5 * placeholderAlpha), align: alignment)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            placeholderAttributedString = nil
            (currentEditor() as? NSTextView)?.insertionPointColor = Ink.text
        }
        return ok
    }

    /// typing in it ended (Return, Esc, or a click elsewhere)
    var onEnd: (() -> Void)?

    func controlTextDidEndEditing(_ obj: Notification) {
        showPlaceholder()
        onEnd?()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let maxLength, stringValue.count > maxLength {
            stringValue = String(stringValue.prefix(maxLength))
        }
        onChange?()
    }

    /// whether it is being typed in now
    var editing: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    func focus() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
    }
}

// ── a list or a text whose lines fade near the edge where more is hidden ──

final class FadeScroll: NSScrollView {
    private let mask = CAGradientLayer()
    static let fade: CGFloat = 56

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        borderType = .noBorder
        wantsLayer = true
        layer?.mask = mask
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var documentView: NSView? {
        didSet {
            if let old = oldValue { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: old) }
            guard let doc = documentView else { return }
            doc.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: doc)
        }
    }

    override func layout() {
        super.layout()
        update()
    }

    @objc func update() {
        guard let doc = documentView else { return }
        let h = bounds.height
        guard h > 0 else { return }
        let y = contentView.bounds.minY
        let top = y > 1 ? min(Self.fade, h / 2) : 0
        let bottom = y + h < doc.frame.height - 1 ? min(Self.fade, h / 2) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        mask.frame = bounds
        // the layer's own y runs up: its first colour is at the bottom
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let flipped = layer?.contentsAreFlipped() ?? false
        let start = (flipped ? top : bottom) / h, end = 1 - (flipped ? bottom : top) / h
        mask.locations = [0, NSNumber(value: Double(start)), NSNumber(value: Double(end)), 1]
        CATransaction.commit()
    }
}

/// the blur of what is under it in the window (a popup's veil, the search's)
func veil() -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .hudWindow
    v.blendingMode = .withinWindow
    v.state = .active
    v.appearance = NSAppearance(named: .darkAqua)
    return v
}
