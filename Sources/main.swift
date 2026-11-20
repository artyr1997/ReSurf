import AppKit
import WebKit

// ReSurf: a quiet browser on the Mac's own WebKit. A native Mac app on the ReSpace desk.

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = menu()
        Lang.shared.follow()
        Desk.listen()
        Engine.prepare()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1440, screen.width), height: min(900, screen.height))
        open(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), main: true)
    }

    @discardableResult
    func open(_ frame: NSRect, main: Bool) -> SurfWindow {
        let w = SurfWindow(frame: frame)
        w.main.isMain = main
        w.open()
        return w
    }

    @objc func newWindow(_ sender: Any?) {
        let front = NSApp.keyWindow
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let base = front?.frame ?? NSRect(x: screen.midX - 720, y: screen.midY - 450, width: min(1440, screen.width), height: min(900, screen.height))
        open(front == nil ? base : base.offsetBy(dx: 28, dy: -28), main: false)
    }

    /// the menu's commands go to the window in front (in a page too: a menu's keys come first)
    @objc func command(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "close-window" { return (NSApp.keyWindow as? SurfWindow)?.close() ?? () }
        (NSApp.keyWindow as? SurfWindow ?? NSApp.windows.compactMap { $0 as? SurfWindow }.first)?.main.command(id)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for case let w as SurfWindow in NSApp.windows { w.main.leave() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSApp.windows.compactMap({ $0 as? SurfWindow }).isEmpty { newWindow(nil) }
        return true
    }

    private func item(_ menu: NSMenu, _ title: String, _ id: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
        let i = menu.addItem(withTitle: title, action: #selector(command(_:)), keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.representedObject = id
        i.target = self
    }

    private func menu() -> NSMenu {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Hide ReSurf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ReSurf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(withTitle: "ReSurf", action: nil, keyEquivalent: "").submenu = app

        // pages need the standard edit commands for ⌘C / ⌘V / ⌘A to work
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let tabs = NSMenu(title: "Tabs")
        item(tabs, "New Tab", "new", "t")
        let nw = tabs.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        nw.target = self
        item(tabs, "Edit Address", "address", "l")
        item(tabs, "Close Tab", "close", "w")
        item(tabs, "Favourite", "favo", "d")
        tabs.addItem(.separator())
        item(tabs, "Next Tab", "next-tab", "\t", .control)
        item(tabs, "Previous Tab", "prev-tab", "\t", [.control, .shift])
        bar.addItem(withTitle: "Tabs", action: nil, keyEquivalent: "").submenu = tabs

        let view = NSMenu(title: "View")
        item(view, "Back", "back", "[")
        item(view, "Forward", "forward", "]")
        item(view, "Reload", "reload", "r")
        item(view, "Video Fills the Page", "video", "f")
        view.addItem(.separator())
        item(view, "Page Fills the Window", "full", "f", [.command, .shift])
        item(view, "Info", "info", "i")
        bar.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        item(window, "Close Window", "close-window", "w", [.command, .shift])
        bar.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return bar
    }
}

let app = ReApp.shared
if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    Probe.run(CommandLine.arguments[i + 1])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    Render.run(into: CommandLine.arguments[i + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
