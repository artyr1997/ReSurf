import AppKit

/// a popup's list of words to choose (the actions): the one chosen underlined
final class Menu: Flipped {
    let items: [String]
    var chosen = 0 { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private let rowH: CGFloat = 19.2, gap: CGFloat = 16

    init(_ items: [String]) {
        self.items = items
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let w = items.map { attributed($0, Fonts.words(16)).size().width }.max() ?? 100
        widthAnchor.constraint(equalToConstant: ceil(w) + 20).isActive = true
        heightAnchor.constraint(equalToConstant: CGFloat(items.count) * (rowH + gap) - gap + 10).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        for (i, item) in items.enumerated() {
            var a: [NSAttributedString.Key: Any] = [.font: Fonts.words(16), .foregroundColor: Ink.text]
            if i == chosen {
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                a[.underlineColor] = Ink.text
            }
            NSAttributedString(string: item, attributes: a).draw(at: NSPoint(x: 6, y: 5 + CGFloat(i) * (rowH + gap)))
        }
    }

    private func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        let i = Int((p.y - 5 + gap / 2) / (rowH + gap))
        return i >= 0 && i < items.count ? i : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { if let i = index(event) { chosen = i } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if let i = index(event) { onPick?(i) } }
}

