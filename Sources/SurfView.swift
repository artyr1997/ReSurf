import AppKit
import WebKit

// The browser. Favourites run down the left edge, the other open tabs down the right one, each a dash (as
// ReDesk's wallpapers); the page sits in the card in the middle, its site above it and its path under it,
// between < and >. With no tab open, or ⌘T, ⌘L: Search, in the middle. FULL: the page over the whole window.

final class SurfView: Flipped, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// the first window keeps its tabs between launches; those ⌘N opens start clean and keep nothing
    var isMain = true

    private(set) var tabs: [Tab] = []
    private var active: Int?
    private var full = false
    private var nextId = 1
    private var searching = true
    /// Search opens a new tab, or takes the current one somewhere else
    private var editing = "new"

    private let nova = SideButton("NOVA", as: "NEW TAB") {}
    private let info = SideButton("INFO") {}
    private let favo = SideButton("FAVO") {}
    private let fullButton = SideButton("FULL") {}
    private let left = Dashes()
    private let right = Dashes()
    private let card = Flipped()
    private let stage = Flipped()
    private let titleButton = WordButton("", font: Fonts.words(16)) {}
    private let back = WordButton("<", font: Fonts.buttons(26)) {}
    private let forward = WordButton(">", font: Fonts.buttons(26)) {}
    private let pathButton = WordButton("", font: Fonts.words(16)) {}
    let search = Field(size: 24, align: .center)
    private let marks = Marks()
    private let strip = DragStrip()
    private var popup: Popup?
    private var popupKeys: ((NSEvent) -> Bool)?
    private var sleeper: Timer?
    private var saving: DispatchWorkItem?
    private var observers: [Int: [NSKeyValueObservation]] = [:]
    var pinned = false { didSet { marks.pinned = pinned } }

    private var favorites: [Tab] { tabs.filter(\.favorite) }
    private var others: [Tab] { tabs.filter { !$0.favorite } }
    var current: Tab? { tabs.first { $0.id == active } }
    private var showing: Bool { !searching && popup == nil && current != nil }
    private var results: Bool { !searching && current.map { Address.isSearch($0.url) } ?? false }
    private var fullShown: Bool { full && !searching }

    var W: CGFloat { bounds.width }
    var H: CGFloat { bounds.height }
    var small: Bool { W < 760 || H < 560 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        nova.action = { [weak self] in self?.newTab() }
        nova.title = "New tab (⌘T)"
        info.action = { [weak self] in self?.openInfo() }
        info.title = "Info (⌘I)"
        favo.action = { [weak self] in self?.toggleFavorite(self?.active) }
        favo.title = "Favourite (⌘D)"
        fullButton.action = { [weak self] in self?.toggleFull() }
        fullButton.title = "Page fills the window (⌘⇧F)"
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0x26 / 255, alpha: 1).cgColor
        addSubview(card)
        addSubview(stage)
        for b in [nova, info, favo, fullButton] { addSubview(b) }
        left.pick = { [weak self] id in self?.activate(id) }
        left.actions = { [weak self] id in self?.openActions(id) }
        right.pick = left.pick
        right.actions = left.actions
        addSubview(left)
        addSubview(right)
        titleButton.action = { [weak self] in self?.editAddress() }
        pathButton.action = { [weak self] in self?.editAddress() }
        back.action = { [weak self] in self?.current?.web?.goBack() }
        back.toolTip = "Back (⌘[)"
        forward.action = { [weak self] in self?.current?.web?.goForward() }
        forward.toolTip = "Forward (⌘])"
        for v in [titleButton, back, forward, pathButton] as [NSView] { addSubview(v) }
        search.placeholder = "Search"
        search.placeholderAlpha = 0.5
        addSubview(search)
        addSubview(strip)
        addSubview(marks)
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── at the start, and kept ──

    private static let stateFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.artursavytskyi.resurf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func start() {
        nextId = 1
        if isMain, let data = try? Data(contentsOf: Self.stateFile), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // the tabs come back as their names: their pages are made when they are looked at
            tabs = ((saved["tabs"] as? [[String: Any]]) ?? []).compactMap(Tab.from)
            nextId = (saved["nextId"] as? NSNumber)?.intValue ?? ((tabs.map(\.id).max() ?? 0) + 1)
            full = saved["full"] as? Bool ?? false
            if let a = (saved["active"] as? NSNumber)?.intValue, tabs.contains(where: { $0.id == a }) { active = a }
        } else if !isMain {
            // no two windows' tabs share an id
            nextId = (NSApp.windows.count + 1) * 1_000_000
        }
        searching = active == nil
        apply()
        // every minute: the tabs left alone half an hour sleep
        sleeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sleepTabs() }
    }

    private func keep() {
        guard isMain else { return }
        saving?.cancel()
        let state: [String: Any] = ["tabs": tabs.map(\.json), "active": active as Any? ?? NSNull(), "full": full, "nextId": nextId]
        let work = DispatchWorkItem {
            guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
            // written next to it, then swapped: a crash never leaves half a file
            let tmp = Self.stateFile.appendingPathExtension("tmp")
            try? data.write(to: tmp)
            _ = try? FileManager.default.replaceItemAt(Self.stateFile, withItemAt: tmp)
        }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func leave() {
        saving?.perform()
        saving = nil
    }

    func end() {
        sleeper?.invalidate()
        for t in tabs { drop(t) }
    }

    // ── a tab's page ──

    /// its page, made the first time it is looked at (or when it wakes)
    private func page(_ tab: Tab) -> WKWebView {
        if let w = tab.web { return w }
        let w = Engine.page(handler: self)
        w.navigationDelegate = self
        w.uiDelegate = self
        tab.web = w
        observers[tab.id] = [
            w.observe(\.title, options: .new) { [weak self, weak tab] w, _ in
                guard let tab, let t = w.title, !t.isEmpty else { return }
                tab.title = t
                self?.changed(tab)
            },
            w.observe(\.url, options: .new) { [weak self, weak tab] w, _ in
                guard let tab, let u = w.url?.absoluteString else { return }
                tab.url = u
                self?.changed(tab)
            },
            w.observe(\.isLoading, options: .new) { [weak self, weak tab] w, _ in
                guard let tab else { return }
                tab.loading = w.isLoading
                self?.changed(tab)
            },
        ]
        if let kept = tab.kept {
            // awake again: where it was, its back and forward with it
            w.interactionState = kept
            tab.kept = nil
            if w.url == nil, let u = URL(string: tab.url) { w.load(URLRequest(url: u)) }
        } else if let u = URL(string: tab.url) {
            w.load(URLRequest(url: u))
        }
        return w
    }

    /// its page given back (closed, or asleep)
    private func drop(_ tab: Tab) {
        guard let w = tab.web else { return }
        observers[tab.id] = nil
        w.stopLoading()
        w.navigationDelegate = nil
        w.uiDelegate = nil
        w.removeFromSuperview()
        tab.web = nil
        tab.loading = false
    }

    /// Tabs left alone half an hour give their page back; never the one on screen, nor one that plays sound
    /// or uses the camera or the microphone.
    private func sleepTabs() {
        let now = Date()
        for tab in tabs where tab.web != nil && tab.id != active && now.timeIntervalSince(tab.seen) > Engine.half {
            guard let w = tab.web, w.cameraCaptureState == .none, w.microphoneCaptureState == .none else { continue }
            w.requestMediaPlaybackState { [weak self, weak tab] state in
                guard let self, let tab, state != .playing, tab.id != self.active, let w = tab.web else { return }
                tab.kept = w.interactionState
                self.drop(tab)
            }
        }
    }

    private func changed(_ tab: Tab) {
        keep()
        if tab.id == active { refreshPage() }
        refreshDashes()
    }

    // ── tabs ──

    /// `takeKeys`: the page gets the keyboard (a tab walked to with ⇧ + an arrow leaves it with the app)
    func activate(_ id: Int, takeKeys: Bool = true) {
        current?.seen = Date()
        active = id
        searching = false
        closePopup()
        current?.seen = Date()
        apply()
        if takeKeys, let w = current?.web { window?.makeFirstResponder(w) } else { window?.makeFirstResponder(self) }
        keep()
    }

    func openTab(_ url: String) {
        let t = Tab(id: nextId, url: url)
        nextId += 1
        tabs.append(t)
        activate(t.id)
    }

    func newTab() {
        closePopup()
        editing = "new"
        search.stringValue = ""
        searching = true
        apply()
        search.focus()
    }

    func editAddress() {
        guard let c = current else { return newTab() }
        closePopup()
        editing = "address"
        search.stringValue = c.url
        searching = true
        apply()
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    private func submit() {
        let q = search.stringValue
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let url = Address.url(q)
        search.stringValue = ""
        if editing == "address", let c = current {
            c.url = url
            if let u = URL(string: url) { page(c).load(URLRequest(url: u)) }
            activate(c.id)
        } else {
            openTab(url)
        }
    }

    private func cancelSearch() {
        search.stringValue = ""
        if current != nil {
            searching = false
            apply()
            if let w = current?.web { window?.makeFirstResponder(w) }
        }
    }

    /// Favourites are kept: closing one gives its page back and takes it back to where it was pinned.
    func closeTab(_ id: Int?, remove: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        drop(tab)
        tab.kept = nil
        if tab.favorite && !remove {
            tab.url = tab.home ?? tab.url
            if active == tab.id {
                active = nil
                newTab()
            }
            keep()
            return apply()
        }
        let list = tab.favorite ? favorites : others
        let at = list.firstIndex { $0 === tab } ?? 0
        let neighbour = at + 1 < list.count ? list[at + 1] : at > 0 ? list[at - 1] : nil
        tabs.removeAll { $0 === tab }
        if active == tab.id {
            if let n = neighbour { activate(n.id) } else {
                active = nil
                newTab()
            }
        }
        keep()
        apply()
    }

    func toggleFavorite(_ id: Int?) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.favorite.toggle()
        tab.home = tab.favorite ? tab.url : nil
        keep()
        apply()
    }

    func cycle(_ d: Int, takeKeys: Bool = true) {
        let order = favorites + others
        guard !order.isEmpty else { return }
        let at = order.firstIndex { $0.id == active }
        let next = at.map { ($0 + d + order.count) % order.count } ?? (d > 0 ? 0 : order.count - 1)
        activate(order[next].id, takeKeys: takeKeys)
    }

    private var lastIn: [Bool: Int] = [:]

    /// ⇧ + an arrow: the tab above / below, or the other column
    private func walk(_ key: String, takeKeys: Bool) {
        switch key {
        case "ArrowDown": cycle(1, takeKeys: takeKeys)
        case "ArrowUp": cycle(-1, takeKeys: takeKeys)
        case "ArrowLeft", "ArrowRight":
            let fav = key == "ArrowLeft"
            let list = fav ? favorites : others
            guard let first = list.first else { return }
            activate((list.first { $0.id == lastIn[fav] } ?? first).id, takeKeys: takeKeys)
        default: break
        }
    }

    func toggleFull() {
        full.toggle()
        keep()
        apply()
    }

    // ── what a page says ──

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // ⇧ + an arrow on a page, in its fields too
        guard popup == nil, let body = message.body as? [String: Any], let key = body["key"] as? String else { return }
        walk(key, takeKeys: true)
    }

    // links that want a new window (target=_blank, window.open) open as a new tab
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url?.absoluteString, !u.isEmpty, u != "about:blank" { openTab(u) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        if let w = window { a.beginSheetModal(for: w) { _ in completionHandler() } } else { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        if let w = window { a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) } } else { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        if let w = window { a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) } } else { completionHandler(nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let w = window else { return completionHandler(nil) }
        panel.beginSheetModal(for: w) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    // a file the page can't show: downloaded into Downloads
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = Downloads.shared }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = Downloads.shared }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // ── drawn ──

    func apply() {
        refreshPage()
        refreshDashes()
        needsLayout = true
    }

    private func refreshDashes() {
        if let c = current { lastIn[c.favorite] = c.id }
        left.items = favorites.map { ($0.id, $0.title.isEmpty ? Address.host($0.url) : $0.title, $0.id == active && !searching, $0.loading) }
        right.items = others.map { ($0.id, $0.title.isEmpty ? Address.host($0.url) : $0.title, $0.id == active && !searching, $0.loading) }
    }

    private func refreshPage() {
        needsLayout = true
        guard let c = current, !searching else {
            stage.subviews.forEach { $0.removeFromSuperview() }
            for v in [titleButton, back, forward, pathButton] as [NSView] { v.isHidden = true }
            card.isHidden = true
            search.isHidden = false
            favo.enabled = current != nil
            favo.chosen = current?.favorite ?? false
            return
        }
        search.isHidden = true
        let w = page(c)
        if w.superview !== stage {
            stage.subviews.forEach { $0.removeFromSuperview() }
            stage.addSubview(w)
        }
        w.isHidden = popup != nil
        titleButton.word = results ? Address.query(c.url) : Address.host(c.url)
        titleButton.toolTip = c.title.isEmpty ? c.url : c.title
        titleButton.alphaValue = c.loading ? 0.55 : 1
        pathButton.word = c.title.isEmpty ? Address.path(c.url) : c.title
        pathButton.toolTip = c.url
        for v in [titleButton, back, forward, pathButton] as [NSView] { v.isHidden = fullShown }
        for v in [back, forward, pathButton] as [NSView] { v.isHidden = v.isHidden || results }
        back.alphaValue = 0.6
        forward.alphaValue = 0.6
        // search results lie on the glass itself: no card
        card.isHidden = results
        favo.enabled = true
        favo.chosen = c.favorite
    }

    override func layout() {
        super.layout()
        let sides = !small && !fullShown
        nova.top = true
        favo.top = true
        fullButton.top = true
        let place = { (b: SideButton, left: Bool, top: Bool) in
            let h = b.intrinsicContentSize.height
            b.frame = NSRect(x: left ? self.W * 0.0625 - 28 : self.W - (self.W * 0.0625 - 28) - SideButton.width,
                             y: top ? self.H * 0.0625 + 8 : self.H - self.H * 0.0625 - h, width: SideButton.width, height: h)
            b.isHidden = !sides
        }
        place(nova, true, true)
        place(info, true, false)
        info.top = false
        place(favo, false, true)
        place(fullButton, false, false)
        fullButton.chosen = full

        let colTop = H * 0.0625 + 160
        left.frame = NSRect(x: W * 0.0625 - 36, y: colTop, width: 58, height: max(0, H - 2 * colTop))
        right.frame = NSRect(x: W - (W * 0.0625 - 36) - 58, y: colTop, width: 58, height: max(0, H - 2 * colTop))
        left.isHidden = !sides
        right.isHidden = !sides

        let page: NSRect
        if fullShown { page = bounds.insetBy(dx: 6, dy: 6) } else if small { page = NSRect(x: 36, y: 44, width: W - 72, height: H - 88) } else {
            page = NSRect(x: W * 0.0625 + 80, y: H * 0.0625 + 24, width: W - 2 * (W * 0.0625 + 80), height: H - 2 * (H * 0.0625 + 24))
        }
        card.frame = page
        stage.frame = page
        stage.subviews.first?.frame = stage.bounds

        let titleW = W * (small ? 1 : 0.6) - (small ? 200 : 0)
        let ty = small ? 22 - 12 : H * 0.03125 + 12 - 12
        titleButton.frame = NSRect(x: (W - titleW) / 2, y: ty, width: titleW, height: 24)
        let py = H - (small ? 22 : H * 0.03125 + 12) - 12
        let pw = min(W * 0.7 - 120, max(40, attributed(pathButton.word, Fonts.words(16)).size().width + 8))
        pathButton.frame = NSRect(x: (W - pw) / 2, y: py, width: pw, height: 24)
        let gap: CGFloat = small ? 24 : 64
        back.frame = NSRect(x: pathButton.frame.minX - gap - 24, y: py - 4, width: 24, height: 32)
        forward.frame = NSRect(x: pathButton.frame.maxX + gap, y: py - 4, width: 24, height: 32)

        let sw = small ? W - 72 : min(640, W - 2 * (W * 0.0625 + 120))
        search.frame = NSRect(x: (W - sw) / 2, y: H / 2 - 16, width: sw, height: 32)
        strip.frame = NSRect(x: 0, y: 0, width: W, height: 28)
        marks.frame = NSRect(x: 14, y: 14, width: 13, height: 40)
        marks.isHidden = fullShown
        popup?.frame = bounds
    }

    // ── popups ──

    func showPopup(_ content: NSView, keys: ((NSEvent) -> Bool)? = nil) {
        closePopup()
        let p = Popup(content: content, modal: true)
        p.onClose = { [weak self] in self?.closePopup() }
        p.frame = bounds
        addSubview(p, positioned: .below, relativeTo: strip)
        popup = p
        popupKeys = keys
        // the page out of the way while a popup is up
        current?.web?.isHidden = true
        window?.makeFirstResponder(self)
    }

    func closePopup() {
        guard popup != nil else { return }
        popup?.removeFromSuperview()
        popup = nil
        popupKeys = nil
        current?.web?.isHidden = false
        if searching { window?.makeFirstResponder(self) } else if let w = current?.web { window?.makeFirstResponder(w) }
    }

    func openInfo() {
        if popup != nil { return closePopup() }
        let n = tabs.count, f = favorites.count
        let shortcuts: [(String, String)] = [
            ("⌘ N", "New window (its own tabs)"), ("⌘ T", "New tab"), ("⌘ L", "Edit address"), ("⌘ ⇧ W", "Close tab"),
            ("⌘ D", "Favourite"), ("⌘ [ / ⌘ ]", "Back / forward"), ("⌘ R", "Reload"), ("⌘ F", "Video fills the page"),
            ("⇧ ↑ / ⇧ ↓", "Previous / next tab"), ("⇧ ← / ⇧ →", "Favourites / other tabs"), ("⌘ ⇧ F", "Page fills the window"),
            ("⌘ I", "Info"), ("Right click", "Tab actions"),
        ]
        let rows = shortcuts.map { k, d -> [NSView] in
            [label(tx(k), Fonts.buttons(13), NSColor(white: 1, alpha: 0.8 * 0.85), kern: 1.3, align: .right),
             label(tx(d), Fonts.words(13), NSColor(white: 1, alpha: 0.8 * 0.7))]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 24
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let views: [NSView] = [
            heading("RE:SURF"), divider(),
            wrapping("\(tx(n == 1 ? "{n} tab" : "{n} tabs", ["n": n])) · \(tx(f == 1 ? "{n} favourite" : "{n} favourites", ["n": f]))", Fonts.words(16)),
            divider(), grid, divider(),
            label(tx("WebKit · Google Search · no history kept"), Fonts.words(13), NSColor(white: 1, alpha: 0.8 * 0.55), kern: 1.95),
        ]
        showPopup(stack(views, spacing: 24, center: true)) { [weak self] e in
            if [53, 36, 76].contains(e.keyCode) { self?.closePopup() }
            return true
        }
    }

    private func openActions(_ id: Int) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        var items: [(String, () -> Void)] = [
            ("Open", { [weak self] in self?.activate(t.id) }),
            ("Copy link", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.url, forType: .string)
            }),
            (t.favorite ? "Remove from favourites" : "Add to favourites", { [weak self] in self?.toggleFavorite(t.id) }),
            ("Close", { [weak self] in self?.closeTab(t.id) }),
        ]
        if t.favorite { items.append(("Remove", { [weak self] in self?.closeTab(t.id, remove: true) })) }
        let menu = Menu(items.map { tx($0.0) })
        let run = { [weak self] (i: Int) in
            self?.closePopup()
            items[i].1()
        }
        menu.onPick = run
        showPopup(stack([wrapping(Address.host(t.url), Fonts.words(22)), divider(), menu], spacing: 24, center: true)) { [weak self] e in
            switch e.keyCode {
            case 53: self?.closePopup()
            case 125: menu.chosen = (menu.chosen + 1) % items.count
            case 126: menu.chosen = (menu.chosen - 1 + items.count) % items.count
            case 36, 76: run(menu.chosen)
            default: break
            }
            return true
        }
    }

    // ── the menu's commands, and the keys that reach the app (a page keeps its own) ──

    func command(_ id: String) {
        switch id {
        case "new": newTab()
        case "address": editAddress()
        case "close": closeTab(active)
        case "favo": toggleFavorite(active)
        case "next-tab": cycle(1)
        case "prev-tab": cycle(-1)
        case "back": current?.web?.goBack()
        case "forward": current?.web?.goForward()
        case "reload": current?.web?.reload()
        case "video": current?.web?.evaluateJavaScript("window.__resurfVideo?.()")
        case "full": toggleFull()
        case "info": openInfo()
        default: break
        }
    }

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if popup != nil {
            if let keys = popupKeys, keys(e) { return true }
            return true
        }
        let arrows: [UInt16: String] = [125: "ArrowDown", 126: "ArrowUp", 123: "ArrowLeft", 124: "ArrowRight"]
        // ⇧ + arrows walk the tabs (in a page, page.js tells of them)
        if mods == .shift, let a = arrows[e.keyCode], !(window?.firstResponder is WKWebView) {
            walk(a, takeKeys: false)
            return true
        }
        // on the Search page with no cursor yet: the first letter typed puts it there, and goes in
        if searching && !search.editing && mods.isSubset(of: .shift), arrows[e.keyCode] == nil,
           let ch = e.characters, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            search.focus()
            (search.currentEditor() as? NSTextView)?.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        if search.editing {
            switch e.keyCode {
            case 36, 76: submit(); return true
            case 53: cancelSearch(); return true
            case 125, 126 where search.stringValue.isEmpty:
                // an empty Search walks the tabs, as ⇧↑ / ⇧↓ do
                cycle(e.keyCode == 125 ? 1 : -1, takeKeys: false)
                return true
            default: return false
            }
        }
        return false
    }

    func focusChanged(_ focused: Bool) { marks.focused = focused }
}

/// a column of tabs as ReDesk's wallpapers: a dash each, the open one long and strong, the others short and faint
final class Dashes: Flipped {
    let scroll = FadeScroll()
    private let doc = DashDoc()
    var items: [(id: Int, title: String, on: Bool, loading: Bool)] = [] { didSet { relayout() } }
    var pick: ((Int) -> Void)?
    var actions: ((Int) -> Void)?
    var hover: Int? { didSet { doc.needsDisplay = true } }
    private var breathe: Timer?
    private var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        doc.list = self
        scroll.documentView = doc
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        relayout()
    }

    private func relayout() {
        let h = CGFloat(items.count) * 16 + 24
        doc.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(h, scroll.contentSize.height))
        doc.removeAllToolTips()
        for (i, item) in items.enumerated() { doc.addToolTip(rect(i), owner: item.title as NSString, userData: nil) }
        doc.needsDisplay = true
        scroll.update()
        // a page loading: its dash breathes
        let any = items.contains { $0.loading }
        if any && breathe == nil {
            breathe = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase += 1 / 24
                self.doc.needsDisplay = true
            }
        } else if !any {
            breathe?.invalidate()
            breathe = nil
        }
    }

    /// the dashes in the middle of the column
    private var top: CGFloat { max(12, (doc.bounds.height - CGFloat(items.count) * 16) / 2) }

    func rect(_ i: Int) -> NSRect { NSRect(x: 0, y: top + CGFloat(i) * 16, width: doc.bounds.width, height: 16) }

    func index(_ p: NSPoint) -> Int? {
        let i = Int(floor((p.y - top) / 16))
        return i >= 0 && i < items.count ? i : nil
    }

    func drawDashes() {
        for (i, item) in items.enumerated() {
            let r = rect(i)
            let w: CGFloat = item.on ? 20 : hover == i ? 14 : 10
            var alpha: CGFloat = item.on ? 0.5 : hover == i ? 0.4 : 0.25
            if item.loading { alpha *= 0.35 + 0.65 * (0.5 + 0.5 * cos(phase * 2 * .pi)) }
            NSColor(white: 1, alpha: alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.midX - w / 2, y: r.midY - 1, width: w, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

private final class DashDoc: Flipped {
    weak var list: Dashes?
    private var area: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) { list?.drawDashes() }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area!)
    }

    override func mouseMoved(with event: NSEvent) { list?.hover = list?.index(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { list?.hover = nil }
    override func mouseDown(with event: NSEvent) {
        guard let list, let i = list.index(convert(event.locationInWindow, from: nil)) else { return }
        list.pick?(list.items[i].id)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let list, let i = list.index(convert(event.locationInWindow, from: nil)) else { return }
        list.actions?(list.items[i].id)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// files the pages hand over: into Downloads, under their own name (a second one "name 2")
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = dir.appendingPathComponent(suggestedFilename)
        let stem = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {}
}
