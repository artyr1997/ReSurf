import AppKit

/// How far a window's side buttons and what it shows stand from its edges, as a share of its width (x) and
/// height (y): set with ReDesk's keys while this app is in front (⌃⌥- / ⌃⌥= across, ⌃⌥[ / ⌃⌥] down; ReDesk
/// tells it, com.artursavytskyi.re.spacing), kept. Thin lines across the window show them a moment.
enum Spacing {
    static let least: CGFloat = 0.02, most: CGFloat = 0.15, step: CGFloat = 0.005

    /// across: the side buttons' column from the left and right edges; down: the title's line from the top
    /// (and the line at the foot from the bottom). What is shown stands as far again from them, so the
    /// distances are the same either side of a button or a title.
    static var x: CGFloat { (UserDefaults.standard.object(forKey: "spacing.x") as? Double).map { CGFloat($0) } ?? 0.0625 }
    static var y: CGFloat { (UserDefaults.standard.object(forKey: "spacing.y") as? Double).map { CGFloat($0) } ?? 0.045 }

    /// the middle of the side buttons' column, from the left (and the right) edge
    static func column(_ W: CGFloat) -> CGFloat { W * x }
    /// where what is shown begins across, from the left (and the right) edge: as far again
    static func inner(_ W: CGFloat) -> CGFloat { 2 * W * x }
    /// the middle of the title's line, from the top (and of the line at the foot, from the bottom)
    static func band(_ H: CGFloat) -> CGFloat { H * y }
    /// where what is shown begins down, from the top (and ends, from the bottom): as far again
    static func innerTop(_ H: CGFloat) -> CGFloat { 2 * H * y }
    /// what is shown, between the buttons and under the title
    static func content(_ W: CGFloat, _ H: CGFloat) -> NSRect {
        NSRect(x: inner(W), y: innerTop(H), width: W - 2 * inner(W), height: H - 2 * innerTop(H))
    }
    /// a side button at a corner: its column's middle on the column, its top at what is shown's top (a bottom
    /// one's foot at its foot) (in a flipped view)
    static func button(width: CGFloat, height: CGFloat, left: Bool, top: Bool, _ W: CGFloat, _ H: CGFloat) -> NSRect {
        NSRect(x: left ? column(W) - width / 2 : W - column(W) - width / 2,
               y: top ? innerTop(H) : H - innerTop(H) - height, width: width, height: height)
    }

    static func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.artursavytskyi.re.spacing"), object: nil, queue: .main) { note in
            // "<bundle> <x|y> <-1|1> [all]": this app's, across or down, nearer the edges or further; with "all"
            // (fn A and the arrows) the others given the same
            let parts = (note.object as? String ?? "").split(separator: " ").map(String.init)
            guard parts.count >= 3, parts[0] == Bundle.main.bundleIdentifier, let way = Double(parts[2]) else { return }
            move(parts[1], CGFloat(way))
            if parts.count > 3 && parts[3] == "all" {
                // the others' own settings written too, so one not running finds them when it opens
                for other in ["com.artursavytskyi.refile", "com.artursavytskyi.resurf", "com.artursavytskyi.renote", "com.artursavytskyi.reterm"]
                where other != Bundle.main.bundleIdentifier {
                    CFPreferencesSetAppValue("spacing.x" as CFString, Double(x) as CFNumber, other as CFString)
                    CFPreferencesSetAppValue("spacing.y" as CFString, Double(y) as CFNumber, other as CFString)
                    CFPreferencesAppSynchronize(other as CFString)
                }
                center.postNotificationName(Notification.Name("com.artursavytskyi.re.spacing.set"),
                                            object: "\(parts[0]) \(Double(x)) \(Double(y))", userInfo: nil, deliverImmediately: true)
            }
        }
        // another app's distances, to take as they are: "<its bundle> <x> <y>"
        center.addObserver(forName: Notification.Name("com.artursavytskyi.re.spacing.set"), object: nil, queue: .main) { note in
            let parts = (note.object as? String ?? "").split(separator: " ").map(String.init)
            guard parts.count == 3, parts[0] != Bundle.main.bundleIdentifier, let nx = Double(parts[1]), let ny = Double(parts[2]) else { return }
            UserDefaults.standard.set(nx, forKey: "spacing.x")
            UserDefaults.standard.set(ny, forKey: "spacing.y")
            relayout()
        }
    }

    /// every window laid out again
    static func relayout() {
        func mark(_ v: NSView) { v.needsLayout = true; v.subviews.forEach(mark) }
        for w in NSApp.windows { if let v = w.contentView { mark(v) } }
    }

    static func move(_ axis: String, _ way: CGFloat) {
        let key = "spacing." + axis
        let now = axis == "x" ? x : y
        let next = min(most, max(least, now + way * step))
        guard next != now else { return NSSound.beep() }
        UserDefaults.standard.set(Double(next), forKey: key)
        relayout()
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
            // the buttons' columns and what is shown's sides; the titles' lines and what is shown's top and foot
            for x in [column(W), inner(W), W - inner(W), W - column(W)] {
                path.move(to: NSPoint(x: x.rounded() + 0.5, y: 0)); path.line(to: NSPoint(x: x.rounded() + 0.5, y: H))
            }
            for y in [band(H), innerTop(H), H - innerTop(H), H - band(H)] {
                path.move(to: NSPoint(x: 0, y: y.rounded() + 0.5)); path.line(to: NSPoint(x: W, y: y.rounded() + 0.5))
            }
            path.lineWidth = 1
            NSColor(white: 1, alpha: 0.35).setStroke()
            path.stroke()
        }
    }
}
