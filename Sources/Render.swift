import AppKit
import WebKit

// --render <dir>: ReSurf drawn into pictures, out of sight, in a window of its own (it keeps nothing and reads
// nothing of the tabs kept on this Mac), with made-up pages.

enum Render {
    static func run(into dir: String) {
        let w = SurfWindow(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        w.main.isMain = false
        w.main.frame = w.contentView!.bounds
        w.main.start()
        func shoot(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            guard let view = w.contentView else { return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let out = NSImage(size: view.bounds.size)
            out.lockFocus()
            NSColor(white: 0.16, alpha: 1).setFill()
            view.bounds.fill()
            rep.draw(in: view.bounds)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        shoot("start")
        let page = "data:text/html,<title>A quiet page</title><body style='font:20px sans-serif;color:%23ccc'><h1>Hello</h1>"
        for _ in 0..<3 { w.main.openTab(page) }
        w.main.toggleFavorite(w.main.tabs.first?.id)
        shoot("page")
        w.main.command("info")
        shoot("info")
        w.main.closePopup()
        w.main.command("full")
        shoot("full")
        w.main.end()
    }
}

// --probe <url> [--size W×H] [--scroll]: a page loaded out of sight, then what its root and its first result say of
// themselves (--scroll: and how many results there are after its list is scrolled to the end)
enum Probe {
    static func run(_ url: String) {
        var size = NSSize(width: 1440, height: 900)
        if let i = CommandLine.arguments.firstIndex(of: "--size"), i + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[i + 1].split(whereSeparator: { "x×".contains($0) }).compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        let w = SurfWindow(frame: NSRect(origin: .zero, size: size))
        w.main.isMain = false
        w.main.frame = w.contentView!.bounds
        w.main.start()
        w.main.openTab(url)
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        let js = """
        JSON.stringify({cls: document.documentElement.className, scripts: !!window.__resurfVideo, search: !!window.__resurfSearch,
          title: (() => { const t = document.querySelector('#resurf-search .re-title'); return t ? getComputedStyle(t).color : 'none'; })(),
          text: getComputedStyle(document.documentElement).getPropertyValue('--text'), dark: matchMedia('(prefers-color-scheme: dark)').matches,
          width: innerWidth, results: document.querySelectorAll('#resurf-search li').length,
          rise: (() => { const li = document.querySelector('#resurf-search li'); return li ? getComputedStyle(li).animationName + ' ' + getComputedStyle(li).animationDuration : 'none'; })()})
        """
        var done = false
        w.main.current?.web?.evaluateJavaScript(js) { r, e in
            print(r ?? "nil", e.map { "\($0)" } ?? "")
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        // --scroll: the results' list scrolled to its end, twice, and counted after each (the next ones come in)
        guard CommandLine.arguments.contains("--scroll") else { return }
        for _ in 0..<2 {
            w.main.current?.web?.evaluateJavaScript("document.querySelector('#resurf-search').scrollTop = 1e9") { _, _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(12))
            var counted = false
            w.main.current?.web?.evaluateJavaScript("document.querySelectorAll('#resurf-search li').length") { r, _ in
                print("after scrolling:", r ?? "nil")
                counted = true
            }
            while !counted { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
    }
}
