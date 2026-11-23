import AppKit

/// How far a window's side buttons and what it shows stand from its edges, as a share of its width (x) and
/// height (y): set with ReDesk's keys while this app is in front (⌃⌥- / ⌃⌥= across, ⌃⌥[ / ⌃⌥] down; ReDesk
/// tells it, com.artursavytskyi.re.spacing), kept. Thin lines across the window show them a moment.
enum Spacing {
    static let least: CGFloat = 0.02, most: CGFloat = 0.15, step: CGFloat = 0.005, usual: CGFloat = 0.0625

    static var x: CGFloat { (UserDefaults.standard.object(forKey: "spacing.x") as? Double).map { CGFloat($0) } ?? usual }
    static var y: CGFloat { (UserDefaults.standard.object(forKey: "spacing.y") as? Double).map { CGFloat($0) } ?? usual }

    static func start() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.artursavytskyi.re.spacing"), object: nil, queue: .main) { note in
            // "<bundle> <x|y> <-1|1>": this app's, across or down, nearer the edges or further
            let parts = (note.object as? String ?? "").split(separator: " ").map(String.init)
            guard parts.count == 3, parts[0] == Bundle.main.bundleIdentifier, let way = Double(parts[2]) else { return }
            move(parts[1], CGFloat(way))
        }
    }

    static func move(_ axis: String, _ way: CGFloat) {
        let key = "spacing." + axis
        let now = axis == "x" ? x : y
        let next = min(most, max(least, now + way * step))
        guard next != now else { return NSSound.beep() }
        UserDefaults.standard.set(Double(next), forKey: key)
        // every window laid out again
        func mark(_ v: NSView) { v.needsLayout = true; v.subviews.forEach(mark) }
        for w in NSApp.windows { if let v = w.contentView { mark(v) } }
        if let w = NSApp.keyWindow ?? NSApp.mainWindow { Guides.show(in: w) }
    }

    /// thin lines across the window where the distances now are, fading a moment after the last key
    private final class Guides: NSView {
        static var shown: Guides?
        static var hiding: DispatchWorkItem?

        static func show(in window: NSWindow) {
            guard let content = window.contentView else { return }
            let g = shown ?? Guides()
            if g.superview !== content { g.removeFromSuperview(); content.addSubview(g, positioned: .above, relativeTo: nil) }
            g.frame = content.bounds
            g.autoresizingMask = [.width, .height]
            g.alphaValue = 1
            g.needsDisplay = true
            shown = g
            hiding?.cancel()
            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; g.animator().alphaValue = 0 },
                                                     completionHandler: { if g.alphaValue == 0 { g.removeFromSuperview(); shown = nil } })
            }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let W = bounds.width, H = bounds.height
            let path = NSBezierPath()
            for x in [W * Spacing.x, W - W * Spacing.x] {
                path.move(to: NSPoint(x: x.rounded() + 0.5, y: 0)); path.line(to: NSPoint(x: x.rounded() + 0.5, y: H))
            }
            for y in [H * Spacing.y, H - H * Spacing.y] {
                path.move(to: NSPoint(x: 0, y: y.rounded() + 0.5)); path.line(to: NSPoint(x: W, y: y.rounded() + 0.5))
            }
            path.lineWidth = 1
            NSColor(white: 1, alpha: 0.35).setStroke()
            path.stroke()
        }
    }
}
