import AppKit

// The window: no title bar, no rim, no shadow; glass (the system's blur of what is behind it) with the
// the page on it. ReDesk draws its opening and closing, lays one glass under windows it joins, pins one
// (⌃⌥P), hides and shows the app's windows: it says so with distributed notifications (Desk below).

final class SurfWindow: NSWindow {
    let main = SurfView()
    let root: Root
    private var closing = false

    init(frame: NSRect) {
        root = Root(main: main)
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .miniaturizable, .closable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        title = "ReSurf"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 360, height: 240)
        appearance = NSAppearance(named: .darkAqua)
        contentView = root
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main) { [weak self] _ in self?.main.focusChanged(true) }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in self?.main.focusChanged(false) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // a window ReDesk tiles as any other
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .standardWindow }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, main.key(event) { return }
        super.sendEvent(event)
    }

    /// shown softly: ReDesk draws the opening, then says to show it; without ReDesk it fades in
    func open() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        main.start()
        if Desk.tell("open", self) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if let self, self.alphaValue < 0.01 { Fade.windows([self], to: 1) }
            }
        } else {
            Fade.windows([self], to: 1, duration: 0.3, timing: .easeOut)
        }
    }

    /// a window asked to close fades out first, then goes (ReDesk draws the closing under it)
    override func close() {
        main.leave()
        if closing || !isVisible || alphaValue < 0.01 {
            main.end()
            return super.close()
        }
        closing = true
        _ = Desk.tell("close", self)
        Fade.windows([self], to: 0) { [weak self] in self?.close() }
    }

    override func performClose(_ sender: Any?) { close() }
}

enum Fade {
    static let seconds = 0.4

    static func windows(_ windows: [NSWindow], to alpha: CGFloat, duration: Double = seconds,
                        timing: CAMediaTimingFunctionName = .easeInEaseOut, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = duration
            c.timingFunction = CAMediaTimingFunction(name: timing)
            for w in windows { w.animator().alphaValue = alpha }
        }, completionHandler: done)
    }
}

/// the window's content: its glass, and the page on it
final class Root: Flipped {
    let glass = NSVisualEffectView()
    let main: SurfView

    /// joined to others (Flush): ReDesk lays one glass under them all, the window drops its own
    var shared = false { didSet { glass.isHidden = shared } }

    init(main: SurfView) {
        self.main = main
        super.init(frame: .zero)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        main.autoresizingMask = [.width, .height]
        addSubview(main)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// In the corner where macOS has its buttons: a diamond while this window is the focused one, and P while
/// ReDesk has it pinned (⌃⌥P), under the diamond or in its place.
final class Marks: Flipped {
    var focused = true { didSet { needsDisplay = true } }
    var pinned = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let ink = NSColor(white: 1, alpha: 0.8 * 0.9)
        var y: CGFloat = 0
        if focused {
            ink.setFill()
            let c = NSPoint(x: 6.5, y: 6.5)
            let d: CGFloat = 9 / 2 * sqrt(2)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x, y: c.y - d)); p.line(to: NSPoint(x: c.x + d, y: c.y))
            p.line(to: NSPoint(x: c.x, y: c.y + d)); p.line(to: NSPoint(x: c.x - d, y: c.y)); p.close()
            p.fill()
            y = 13 + 6
        }
        if pinned {
            let s = attributed("P", Fonts.buttons(15), ink)
            s.draw(at: NSPoint(x: (13 - s.size().width) / 2, y: y - 2))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// an invisible strip along the top: the window moves with it
final class DragStrip: Flipped {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// ── ReDesk ──

enum Desk {
    static let id = "com.artursavytskyi.redesk"

    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

    /// Tells ReDesk a window opens or closes ("open" / "close"), so it draws that; whether ReDesk is there to.
    static func tell(_ kind: String, _ window: NSWindow) -> Bool {
        guard running else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.artursavytskyi.re.opening"), object: "\(kind) \(getpid()) \(window.windowNumber)",
            userInfo: nil, deliverImmediately: true)
        return true
    }

    private static var windows: [SurfWindow] { NSApp.windows.compactMap { $0 as? SurfWindow } }

    /// once, at start
    static func listen() {
        let center = DistributedNotificationCenter.default()
        // "hide" / "show" / "close" all the app's windows, "hide <pid>" this app alone,
        // "hide-window <pid> <n>" / "show-window …" one window out of sight on another desktop, or back
        // a window closed is no longer put away (a closed window stays in NSApp.windows)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            if let w = note.object as? NSWindow { putAway[w.windowNumber] = nil }
        }
        center.addObserver(forName: .init("com.artursavytskyi.re.windows"), object: nil, queue: .main) { note in
            guard let said = note.object as? String else { return }
            let words = said.split(separator: " ").map(String.init)
            let me = "\(getpid())"
            if words.count == 3, words[0] == "hide-window" || words[0] == "show-window" {
                guard words[1] == me, let n = Int(words[2]), let w = NSApp.window(withWindowNumber: n) else { return }
                if words[0] == "hide-window" {
                    putAway[n] = w
                    Fade.windows([w], to: 0) {
                        // shown again before it was done fading: it stays
                        guard putAway[n] != nil else { return }
                        w.orderOut(nil)
                        w.alphaValue = 1
                    }
                } else {
                    putAway[n] = nil
                    w.alphaValue = 0
                    w.orderFront(nil)
                    Fade.windows([w], to: 1)
                }
                return
            }
            if said == "hide \(me)" {
                if !NSApp.isHidden { NSApp.hide(nil) }
                return
            }
            switch said {
            case "hide": if !NSApp.isHidden { NSApp.hide(nil) }
            case "show": if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            case "close":
                let all = windows
                for w in all { w.main.leave() }
                Fade.windows(all.filter(\.isVisible), to: 0) { for w in all { w.close() } }
            default: break
            }
        }

        // which window ReDesk pinned (⌃⌥P), and which it joined (Flush) under one glass
        center.addObserver(forName: .init("com.artursavytskyi.re.corners"), object: nil, queue: .main) { note in
            guard let info = note.userInfo else { return }
            func number(_ key: String) -> Double { (info[key] as? NSNumber)?.doubleValue ?? -1 }
            guard Int32(number("pid")) == getpid() else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let near = { (a: Double, b: Double) in abs(a - b) < 24 }
            for w in windows {
                let f = w.frame
                if near(f.minX, number("x")) && near(top - f.maxY, number("y")) && near(f.width, number("w")) && near(f.height, number("h")) {
                    w.main.pinned = number("pinned") == 1
                    w.root.shared = number("shared") == 1
                }
            }
        }

        // the app shown again: its windows fade in
        let local = NotificationCenter.default
        local.addObserver(forName: NSApplication.willUnhideNotification, object: nil, queue: .main) { _ in
            for w in NSApp.windows { w.alphaValue = 0 }
        }
        local.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
            Fade.windows(NSApp.windows, to: 1)
        }
    }
}

/// hide: (⌘H, ReDesk's Hide Windows): the windows fade out first
final class ReApp: NSApplication {
    private var hiding = false

    override func hide(_ sender: Any?) {
        if hiding { return super.hide(sender) }
        hiding = true
        Fade.windows(windows.filter(\.isVisible), to: 0) { [weak self] in
            guard let self else { return }
            self.hide(sender)
            for w in self.windows { w.alphaValue = 1 }
            self.hiding = false
        }
    }
}

/// The windows put away on another of ReDesk's desktops, by number, held here: out of sight, nothing else
/// keeps one (AppKit lets it go, and it never comes back); and the last of them would count as the last
/// window closed and quit the app: they keep it running.
var putAway: [Int: NSWindow] = [:]
