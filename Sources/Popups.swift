import AppKit

// The popups (the page blurred behind, a pane in the middle, a line round it), their pieces:
// a word written down in a frame that comes down from the top a moment.

func heading(_ s: String) -> NSTextField { label(s, Fonts.buttons(18), kern: 7.2) }

func divider() -> NSView {
    let line = Flipped()
    line.wantsLayer = true
    line.layer?.backgroundColor = Ink.line.withAlphaComponent(0.5 * 0.3).cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

/// a line: the words on the left, the rest on the right
func row(_ left: NSView, _ right: NSView) -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let r = NSStackView(views: [left, spacer, right])
    r.orientation = .horizontal
    r.alignment = .firstBaseline
    r.spacing = 20
    left.setContentCompressionResistancePriority(.required, for: .horizontal)
    return r
}

/// pieces one under another; lines and rows as wide as the pane
func stack(_ views: [NSView], spacing: CGFloat, center: Bool = false) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.spacing = spacing
    s.alignment = center ? .centerX : .leading
    for v in views where v is NSStackView || v.className.hasSuffix("Flipped") || v is NSGridView {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
    }
    return s
}

/// words that wrap, in the pane
func wrapping(_ s: String, _ font: NSFont, _ color: NSColor = Ink.text, align: NSTextAlignment = .center, width: CGFloat = 420) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: s)
    f.font = font
    f.textColor = color
    f.alignment = align
    f.preferredMaxLayoutWidth = width
    f.isSelectable = false
    return f
}

/// the buttons under a popup's words, side by side
func buttons(_ list: [(String, () -> Void)]) -> NSStackView {
    let s = NSStackView(views: list.map { BoxButton($0.0, size: 16, kern: 3.2, pad: NSSize(width: 19.2, height: 6.4), $0.1) })
    s.orientation = .horizontal
    s.spacing = 32
    return s
}

/// a name typed in a popup: no frame, in the middle
final class NameField: NSTextField {
    var onEnter: (() -> Void)?

    init(_ value: String) {
        super.init(frame: .zero)
        stringValue = value
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = Fonts.words(24)
        textColor = Ink.text
        alignment = .center
        cell?.isScrollable = true
        cell?.wraps = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.insertionPointColor = Ink.text
        return ok
    }

    /// its words chosen up to `end` (a name without its extension, as Finder)
    func choose(upTo end: Int) {
        window?.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: 0, length: end)
    }
}

/// a pane in the middle, the page blurred behind; a click beside it closes it
final class Popup: Flipped {
    let modal: Bool
    var keys: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?
    private let pane = Flipped()
    private let marks = CornerMarks()
    private let content: NSView
    private let scroll = FadeScroll()
    private let page = Flipped()

    init(content: NSView, modal: Bool) {
        self.content = content
        self.modal = modal
        super.init(frame: .zero)
        let blur = veil()
        blur.autoresizingMask = [.width, .height]
        blur.alphaValue = 0.85
        addSubview(blur)
        let paneBlur = veil()
        paneBlur.autoresizingMask = [.width, .height]
        pane.addSubview(paneBlur)
        pane.wantsLayer = true
        pane.layer?.backgroundColor = Ink.pane.cgColor
        // taller than the window allows: it scrolls, its lines fading at the edges
        page.addSubview(content)
        scroll.documentView = page
        pane.addSubview(scroll)
        addSubview(pane)
        // no frame round the pane: a + at each of its corners
        addSubview(marks)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
        let fit = content.fittingSize
        let w = max(280, fit.width + 96), h = min(fit.height + 80, bounds.height * 0.8)
        pane.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        marks.frame = bounds
        marks.pane = pane.frame
        pane.subviews.first?.frame = pane.bounds
        scroll.frame = NSRect(x: 2, y: 2, width: pane.bounds.width - 4, height: pane.bounds.height - 4)
        page.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: fit.height + 76)
        content.frame = NSRect(x: 46, y: 38, width: w - 96, height: fit.height)
    }

    func key(_ e: NSEvent) -> Bool { keys?(e) ?? false }

    override func mouseDown(with event: NSEvent) {
        if !pane.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
}

/// a pane's four corners marked with a thin + instead of a frame round it (as ReDesk marks windows' corners)
final class CornerMarks: NSView {
    static let arm: CGFloat = 7
    /// the pane it marks, in this view's coordinates
    var pane: NSRect = .zero { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let a = Self.arm
        for p in [NSPoint(x: pane.minX, y: pane.minY), NSPoint(x: pane.maxX, y: pane.minY),
                  NSPoint(x: pane.minX, y: pane.maxY), NSPoint(x: pane.maxX, y: pane.maxY)] {
            let x = p.x.rounded() + 0.25, y = p.y.rounded() - 0.25
            path.move(to: NSPoint(x: x - a, y: y)); path.line(to: NSPoint(x: x + a, y: y))
            path.move(to: NSPoint(x: x, y: y - a)); path.line(to: NSPoint(x: x, y: y + a))
        }
        path.lineWidth = 1.5
        NSColor(white: 1, alpha: 0.5).setStroke()
        path.stroke()
    }
}
