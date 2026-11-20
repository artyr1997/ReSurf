import AppKit
import WebKit

// The tabs and their pages. A tab is an address and a name until it is looked at: its page (a WKWebView, and
// WebKit's process behind it) is made then, not before. A tab left alone for half an hour sleeps: it gives its
// page back and keeps what it takes to come back where it was (its back and forward, through WebKit's own
// interaction state), unless it plays sound or uses the camera or microphone. Ads and trackers are stopped
// inside WebKit's networking (a content rule list, as Safari's content blockers), before they load.

final class Tab {
    let id: Int
    var url: String
    var title: String
    var favorite: Bool
    /// where a favourite was pinned; closing it takes it back there
    var home: String?
    var icon: String?
    var web: WKWebView?
    var loading = false
    /// when it was last looked at (it sleeps half an hour after)
    var seen = Date()
    /// what it takes to come back where it was, while it sleeps
    var kept: Any?

    init(id: Int, url: String, title: String = "", favorite: Bool = false, home: String? = nil, icon: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.favorite = favorite
        self.home = home
        self.icon = icon
    }

    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "url": url, "title": title, "favorite": favorite]
        if let home { d["home"] = home }
        if let icon { d["icon"] = icon }
        return d
    }

    static func from(_ d: [String: Any]) -> Tab? {
        guard let id = (d["id"] as? NSNumber)?.intValue, let url = d["url"] as? String else { return nil }
        return Tab(id: id, url: url, title: d["title"] as? String ?? "", favorite: d["favorite"] as? Bool ?? false,
                   home: d["home"] as? String, icon: d["icon"] as? String)
    }
}

/// what every page shares: the scripts, the ad blocker, the Safari it says it is
enum Engine {
    static let half = 30 * 60.0

    /// as Safari says it is (the version of the Safari on this Mac), so sites treat it as Safari
    static let agent: String = {
        let version = (NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    private static func script(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "web").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static let scripts: [WKUserScript] = {
        let search = script("search").replacingOccurrences(of: #"__[A-Z_]+__"#, with: "", options: .regularExpression)
        return [
            // the ads the rule list can't reach (YouTube's, served by the site itself), in every frame, first
            WKUserScript(source: script("adblock"), injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: script("page"), injectionTime: .atDocumentStart, forMainFrameOnly: true),
            // Google's results in the ReSurf look
            WKUserScript(source: search, injectionTime: .atDocumentStart, forMainFrameOnly: true),
        ]
    }()

    static var rules: WKContentRuleList?
    private static var waiting: [WKWebView] = []

    /// At launch: the ad blocker's list, compiled once by WebKit and kept under a name made from the rules (a
    /// later launch only looks it up); compiled anew when the rules change, the old one removed.
    static func prepare() {
        guard let url = Bundle.main.url(forResource: "adblock", withExtension: "json", subdirectory: "web") else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let id = "ads-\(String(size, radix: 16))-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")"
        guard let store = WKContentRuleListStore.default() else { return }
        store.lookUpContentRuleList(forIdentifier: id) { list, _ in
            if let list { return ready(list, reload: false) }
            DispatchQueue.global(qos: .utility).async {
                guard let rules = try? String(contentsOf: url, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: rules) { list, _ in
                        if let list { ready(list, reload: true) }
                    }
                }
            }
        }
        store.getAvailableContentRuleListIdentifiers { ids in
            for old in ids ?? [] where old.hasPrefix("ads-") && old != id { store.removeContentRuleList(forIdentifier: old) { _ in } }
        }
    }

    private static func ready(_ list: WKContentRuleList, reload: Bool) {
        rules = list
        for w in waiting {
            w.configuration.userContentController.add(list)
            if reload { w.reload() }
        }
        waiting = []
    }

    /// a new page, with what every page has
    static func page(handler: WKScriptMessageHandler) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        for s in scripts { content.addUserScript(s) }
        content.add(WeakHandler(handler), name: "resurf")
        config.userContentController = content
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = agent
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        // clear where the page paints nothing: the card (or, for search results, the glass) shows
        web.setValue(false, forKey: "drawsBackground")
        if let rules { content.add(rules) } else { waiting.append(web) }
        return web
    }
}

/// a script message handler held weakly (WebKit keeps its handlers for the page's life)
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

// ── addresses ──

enum Address {
    /// Google's Web filter (udm=14): just the links, which search.js draws in the ReSurf look
    static let search = "https://www.google.com/search?udm=14&q="

    /// what was typed: an address as it is, a bare domain over https, anything else searched with Google
    static func url(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"^(about|data):"#, options: [.regularExpression, .caseInsensitive]) != nil { return text }
        let host = !text.contains(" ") && (text.range(of: #"^[^/]+\.[a-z]{2,}(:\d+)?(/.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"^localhost(:\d+)?(/.*)?$"#, options: .regularExpression) != nil)
        if host { return (text.hasPrefix("localhost") ? "http://" : "https://") + text }
        return search + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text)
    }

    /// Google's results for the web (drawn on the glass, no card)
    static func isSearch(_ url: String) -> Bool {
        guard let u = URLComponents(string: url), let host = u.host else { return false }
        return host.range(of: #"(^|\.)google\.[a-z.]+$"#, options: .regularExpression) != nil && u.path == "/search"
            && u.queryItems?.first(where: { $0.name == "udm" })?.value == "14"
    }

    static func query(_ url: String) -> String { URLComponents(string: url)?.queryItems?.first { $0.name == "q" }?.value ?? "" }

    /// "nytimes.com", the title
    static func host(_ url: String) -> String {
        guard let h = URL(string: url)?.host else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// "/international", under the page
    static func path(_ url: String) -> String {
        guard let u = URLComponents(string: url) else { return "" }
        var p = u.percentEncodedPath + (u.percentEncodedQuery.map { "?" + $0 } ?? "")
        p = p.removingPercentEncoding ?? p
        if p.isEmpty || p == "/" { return "/" }
        return p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}
