//! ReSurf: a quiet browser in the ReNote style.
//! The window holds the Svelte UI (label `main`) and one native webview per open
//! tab (label `tab-<id>`), laid over the page card the UI draws. Tab webviews
//! load remote pages and get no IPC permissions (see capabilities/default.json);
//! what they do comes back to the UI as `tab` / `open` events from Rust.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::webview::{NewWindowResponse, PageLoadEvent};
use tauri::{
    AppHandle, Emitter, EventTarget, LogicalPosition, LogicalSize, Manager, Rect, Runtime, State, Url,
    Webview, WebviewBuilder, WebviewUrl,
};

struct AppState {
    state_file: PathBuf,
    eink: AtomicBool,
}

type CmdResult<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn label(id: u64) -> String {
    format!("tab-{id}")
}

fn tab_id(label: &str) -> Option<u64> {
    label.strip_prefix("tab-")?.parse().ok()
}

/// E-ink: pages in the app's own two colours, as on a reader's screen, and nothing moves: a page's
/// light becomes the app's paper and its dark the app's ink (filters map 0…1 onto a…b: contrast c,
/// then brightness k, with k × (1 − c) / 2 = a and k × (1 + c) / 2 = b).
/// By day: white the paper #F4F4F4 (0.957), black the ink #474747 (0.278): c 0.55, k 1.235.
/// At night (the Mac dark): the page turned over, its white the night's paper #1D1D1D (0.114) and its
/// black the night's ink #808080 (0.502): c 0.631, k 0.616; pictures and videos turned back, so they
/// stay themselves, only grey and dimmed.
/// Pages already in the app's own style (the search page, resurf-search, and its held moment
/// before, resurf-hold) keep their buttons and words; only their pictures go grey and dim, as anywhere.
const EINK_CSS: &str = "\
html:not(.resurf-search):not(.resurf-hold) { filter: grayscale(1) contrast(0.55) brightness(1.235) !important; scroll-behavior: auto !important; }
@media (prefers-color-scheme: dark) {
  html:not(.resurf-search):not(.resurf-hold) { filter: grayscale(1) invert(1) contrast(0.631) brightness(0.616) !important; }
  html:not(.resurf-search):not(.resurf-hold) :is(img, picture, video, canvas, iframe, embed, object) { filter: invert(1) !important; }
  html.resurf-search #resurf-search img { filter: grayscale(1) contrast(0.631) brightness(0.616) !important; }
}
html.resurf-search #resurf-search img { filter: grayscale(1) contrast(0.55) brightness(1.235); }
html:not(.resurf-search):not(.resurf-hold) *,
html:not(.resurf-search):not(.resurf-hold) *::before,
html:not(.resurf-search):not(.resurf-hold) *::after {
  animation-duration: 0.001s !important; animation-iteration-count: 1 !important;
  transition-duration: 0s !important; transition-delay: 0s !important;
}";

fn eink_script(on: bool) -> String {
    format!(
        "(() => {{ const id = '__resurf_eink'; let s = document.getElementById(id);
          if ({on}) {{ if (!s) {{ s = document.createElement('style'); s.id = id; s.textContent = {css};
            (document.head || document.documentElement).appendChild(s); }} }}
          else if (s) s.remove(); }})();",
        css = serde_json::to_string(EINK_CSS).unwrap_or_default()
    )
}

/// What a tab tells the UI: where it is, what it's called, whether it's loading.
#[derive(Serialize, Clone, Default)]
struct TabEvent {
    id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    loading: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    icon: Option<String>,
}

/// The page's own icon: the biggest one it names, or /favicon.ico.
const ICON_SCRIPT: &str = "(() => {
  const size = l => Math.max(0, ...String(l.sizes || '').split(' ').map(s => parseInt(s, 10) || 0));
  const links = [...document.querySelectorAll('link[rel~=\"icon\" i], link[rel=\"apple-touch-icon\" i]')]
    .filter(l => l.href).sort((a, b) => size(b) - size(a));
  return links.length ? links[0].href : location.origin + '/favicon.ico';
})()";

fn to_ui<R: Runtime, S: Serialize + Clone>(app: &AppHandle<R>, event: &str, payload: S) {
    let _ = app.emit_to(EventTarget::webview("main"), event, payload);
}

/// The page card in the UI, in logical pixels.
#[derive(Deserialize)]
struct Bounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Bounds {
    fn rect(&self) -> Rect {
        Rect {
            position: LogicalPosition::new(self.x, self.y).into(),
            size: LogicalSize::new(self.width.max(1.0), self.height.max(1.0)).into(),
        }
    }
}

fn tabs<R: Runtime>(app: &AppHandle<R>) -> impl Iterator<Item = Webview<R>> {
    app.webviews().into_iter().filter(|(l, _)| tab_id(l).is_some()).map(|(_, w)| w)
}

/// The pages' corners: the card's (22), or the window's (12) while a page fills the window (FULL).
static CORNER_RADIUS: AtomicU32 = AtomicU32::new(22);

/// Rounded corners like the cards in the other Re apps, and no background of its own.
#[cfg(target_os = "macos")]
fn round_corners<R: Runtime>(webview: &Webview<R>) {
    let radius = CORNER_RADIUS.load(Ordering::Relaxed) as f64;
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    let _ = webview.with_webview(move |platform| {
        let view = platform.inner() as *mut AnyObject;
        if view.is_null() {
            return;
        }
        // SAFETY: `inner()` is the live WKWebView (an NSView); this runs on the main thread.
        unsafe {
            let _: () = msg_send![view, setWantsLayer: true];
            let layer: *mut AnyObject = msg_send![view, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setCornerRadius: radius];
                let _: () = msg_send![layer, setMasksToBounds: true];
            }
            // clear where the page paints nothing: the card behind shows (and, for search
            // results, the paper: the card goes bare)
            let no: *mut AnyObject = msg_send![objc2::class!(NSNumber), numberWithBool: false];
            let key = objc2_foundation::NSString::from_str("drawsBackground");
            let _: () = msg_send![view, setValue: no, forKey: &*key];
        }
    });
}

/// No ads or trackers: EasyList + EasyPrivacy as a WebKit content rule list (adblock.json,
/// made by scripts/adblock.py), the way Safari's content blockers work. WebKit compiles it once
/// (a few seconds) and keeps it under an identifier made from the rules, so later launches
/// only look it up; a new list gets a new identifier and the old one is removed.
#[cfg(target_os = "macos")]
mod adblock {
    use super::{tabs, AppHandle, Runtime, Webview};
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::MainThreadMarker;
    use objc2_foundation::{NSArray, NSError, NSString};
    use objc2_web_kit::{WKContentRuleList, WKContentRuleListStore, WKWebView};
    use std::cell::RefCell;

    const RULES: &str = include_str!("../adblock.json");

    thread_local! {
        static LIST: RefCell<Option<Retained<WKContentRuleList>>> = const { RefCell::new(None) };
    }

    fn identifier() -> String {
        // FNV-1a: the same rules give the same name in every build
        let hash = RULES.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100_0000_01b3));
        format!("ads-{hash:016x}")
    }

    /// At launch (on the main thread): find the compiled list, or compile it.
    pub fn prepare<R: Runtime>(app: &AppHandle<R>) {
        let Some(mtm) = MainThreadMarker::new() else { return };
        // SAFETY: main thread; WebKit calls the completion handlers on the main thread too.
        let Some(store) = (unsafe { WKContentRuleListStore::defaultStore(mtm) }) else { return };
        let id = NSString::from_str(&identifier());
        let (app, compile_store, compile_id) = (app.clone(), store.clone(), id.clone());
        let found = RcBlock::new(move |list: *mut WKContentRuleList, _: *mut NSError| {
            // SAFETY: WebKit hands over a live list or null.
            if let Some(list) = unsafe { Retained::retain(list) } {
                return ready(&app, list, false);
            }
            let app = app.clone();
            let compiled = RcBlock::new(move |list: *mut WKContentRuleList, error: *mut NSError| {
                // SAFETY: as above.
                match unsafe { Retained::retain(list) } {
                    Some(list) => ready(&app, list, true),
                    None => eprintln!("ReSurf: the ad blocker's rules did not compile: {:?}", unsafe { error.as_ref() }),
                }
            });
            let rules = NSString::from_str(RULES);
            // SAFETY: valid strings and block; main thread.
            unsafe {
                compile_store.compileContentRuleListForIdentifier_encodedContentRuleList_completionHandler(
                    Some(&compile_id),
                    Some(&rules),
                    Some(&compiled),
                )
            };
        });
        // SAFETY: as above.
        unsafe { store.lookUpContentRuleListForIdentifier_completionHandler(Some(&id), Some(&found)) };
        remove_old(&store);
    }

    /// Lists compiled from earlier rules.
    fn remove_old(store: &Retained<WKContentRuleListStore>) {
        let current = identifier();
        let store_ = store.clone();
        let done = RcBlock::new(move |ids: *mut NSArray<NSString>| {
            // SAFETY: WebKit hands over a live array or null.
            let Some(ids) = (unsafe { ids.as_ref() }) else { return };
            for id in ids.iter() {
                let name = id.to_string();
                if name.starts_with("ads-") && name != current {
                    let ignore = RcBlock::new(|_: *mut NSError| {});
                    // SAFETY: valid string and block; main thread.
                    unsafe { store_.removeContentRuleListForIdentifier_completionHandler(Some(&id), Some(&ignore)) };
                }
            }
        });
        // SAFETY: as above.
        unsafe { store.getAvailableContentRuleListIdentifiers(Some(&done)) };
    }

    /// The list is there: every open tab gets it (and reloads, if it was only just compiled
    /// and the tabs have loaded their pages with the ads meanwhile).
    fn ready<R: Runtime>(app: &AppHandle<R>, list: Retained<WKContentRuleList>, reload: bool) {
        LIST.with(|l| *l.borrow_mut() = Some(list));
        for tab in tabs(app) {
            attach(&tab);
            if reload {
                let _ = tab.reload();
            }
        }
    }

    /// A tab gets the list (until it's ready, nothing: `ready` catches up).
    pub fn attach<R: Runtime>(webview: &Webview<R>) {
        let _ = webview.with_webview(|platform| {
            let view = platform.inner() as *const WKWebView;
            LIST.with(|l| {
                if let (Some(list), Some(view)) = (l.borrow().as_ref(), unsafe { view.as_ref() }) {
                    // SAFETY: `inner()` is the tab's live WKWebView; with_webview runs on the main thread.
                    unsafe {
                        let rules = view.configuration().userContentController();
                        rules.removeContentRuleList(list);
                        rules.addContentRuleList(list);
                    }
                }
            });
        });
    }
}

/// Pages see ReSurf as the Safari installed on this Mac. A bare WKWebView leaves
/// "Version/… Safari/…" out of its user agent, and sites like Gmail then call
/// the browser unsupported.
fn user_agent() -> &'static str {
    static AGENT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    AGENT.get_or_init(|| {
        let plist = std::fs::read_to_string("/Applications/Safari.app/Contents/Info.plist").unwrap_or_default();
        let version = safari_version(&plist).unwrap_or("26.0");
        format!(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/{version} Safari/605.1.15"
        )
    })
}

fn safari_version(plist: &str) -> Option<&str> {
    let after = &plist[plist.find("<key>CFBundleShortVersionString</key>")?..];
    let start = after.find("<string>")? + "<string>".len();
    let end = after[start..].find("</string>")? + start;
    Some(after[start..end].trim())
}

/// The UI lies under the tabs' webviews, and WebKit hands every webview the mouse's moves over its
/// whole rectangle: over a page the UI would set its arrow while the page sets its hand or I-beam,
/// turn about at each move (a flickering cursor). So a webview's mouseMoved: (the class all of
/// them share) now passes on only the moves that land on that webview, as the window sees it.
#[cfg(target_os = "macos")]
mod one_cursor {
    use objc2::encode::{Encode, Encoding};
    use objc2::ffi;
    use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
    use objc2::{msg_send, sel};
    use std::sync::OnceLock;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Point {
        x: f64,
        y: f64,
    }

    // SAFETY: the layout of CGPoint
    unsafe impl Encode for Point {
        const ENCODING: Encoding = Encoding::Struct("CGPoint", &[f64::ENCODING, f64::ENCODING]);
    }

    type MouseMoved = unsafe extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject);
    static ORIGINAL: OnceLock<MouseMoved> = OnceLock::new();

    unsafe extern "C-unwind" fn mouse_moved(this: &AnyObject, cmd: Sel, event: *mut AnyObject) {
        // SAFETY: AppKit's own calls, on the main thread, with the event it is handling
        unsafe {
            let window: *mut AnyObject = msg_send![this, window];
            if !window.is_null() && !event.is_null() {
                let content: *mut AnyObject = msg_send![window, contentView];
                if !content.is_null() {
                    let at: Point = msg_send![event, locationInWindow];
                    // hitTest: wants the point in the content view's superview (the window's frame)
                    let frame: *mut AnyObject = msg_send![content, superview];
                    let at: Point =
                        if frame.is_null() { at } else { msg_send![frame, convertPoint: at, fromView: std::ptr::null_mut::<AnyObject>()] };
                    let hit: *mut AnyObject = msg_send![content, hitTest: at];
                    if !hit.is_null() {
                        let mine: bool = msg_send![hit, isDescendantOf: this];
                        if !mine {
                            return;
                        }
                    }
                }
            }
            if let Some(original) = ORIGINAL.get() {
                original(this, cmd, event);
            }
        }
    }

    /// `view`: any of the app's webviews (they all share one class).
    pub fn install(view: *mut AnyObject) {
        if view.is_null() || ORIGINAL.get().is_some() {
            return;
        }
        // SAFETY: the runtime's own calls; the replaced method keeps its type (v@:@)
        unsafe {
            let class = ffi::object_getClass(view) as *mut AnyClass;
            let name = sel!(mouseMoved:);
            let method = ffi::class_getInstanceMethod(class, name);
            if method.is_null() {
                return;
            }
            let Some(original) = ffi::method_getImplementation(method) else { return };
            let _ = ORIGINAL.set(std::mem::transmute::<Imp, MouseMoved>(original));
            let ours: Imp = std::mem::transmute::<MouseMoved, Imp>(mouse_moved);
            ffi::class_replaceMethod(class, name, ours, ffi::method_getTypeEncoding(method));
        }
    }
}

/// FCS, the focus search: resurf://localhost/focus?q=…&page=… asks Marginalia (the small, text web)
/// and answers with a page holding what it found as `window.__resurfFocus`; search.js draws it
/// as it draws Google's results. curl does the asking (it comes with macOS), off the main thread.
fn focus_page(uri: &str) -> Vec<u8> {
    let asked = Url::parse(uri).ok();
    let param = |key: &str| {
        asked.as_ref().and_then(|u| u.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.into_owned()))
    };
    let query = param("q").unwrap_or_default();
    let page: u32 = param("page").and_then(|p| p.parse().ok()).unwrap_or(1).max(1);

    let mut api = Url::parse("https://api.marginalia.nu/public/search/").expect("a fixed address");
    if let Ok(mut path) = api.path_segments_mut() {
        path.pop_if_empty().push(&query);
    }
    api.query_pairs_mut().append_pair("count", "20").append_pair("page", &page.to_string());
    let found = std::process::Command::new("/usr/bin/curl")
        .args(["-s", "-f", "-m", "25", api.as_str()])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| serde_json::from_slice::<serde_json::Value>(&out.stdout).ok())
        .unwrap_or_else(|| serde_json::json!({ "error": "Marginalia didn't answer." }));

    // inside a <script>: no "</" may close it early
    let data = found.to_string().replace("</", "<\\/");
    let title = serde_json::to_string(&query).unwrap_or_default().replace("</", "<\\/");
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><script>window.__resurfFocus = {data}; \
         document.title = {title};</script></head><body></body></html>"
    )
    .into_bytes()
}

/// search.js with the ink brushstroke's pieces (public/ink), across and down, put in.
fn search_script() -> &'static str {
    static SCRIPT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    SCRIPT.get_or_init(|| {
        include_str!("../search.js")
            .replace("__BRUSH_LEFT__", include_str!("../../public/ink/brush-left.svg").trim())
            .replace("__BRUSH_MID__", include_str!("../../public/ink/brush-mid.svg").trim())
            .replace("__BRUSH_RIGHT__", include_str!("../../public/ink/brush-right.svg").trim())
            .replace("__BRUSH_TOP__", include_str!("../../public/ink/brush-top.svg").trim())
            .replace("__BRUSH_MID_V__", include_str!("../../public/ink/brush-mid-v.svg").trim())
            .replace("__BRUSH_BOTTOM__", include_str!("../../public/ink/brush-bottom.svg").trim())
            .replace("__DARK_LEFT__", include_str!("../../public/ink/dark/brush-left.svg").trim())
            .replace("__DARK_MID__", include_str!("../../public/ink/dark/brush-mid.svg").trim())
            .replace("__DARK_RIGHT__", include_str!("../../public/ink/dark/brush-right.svg").trim())
    })
}

fn create_tab<R: Runtime>(app: &AppHandle<R>, id: u64, url: Url, bounds: &Bounds) -> CmdResult<Webview<R>> {
    let window = app.get_window("main").ok_or("No window")?;
    let (load_app, title_app, open_app) = (app.clone(), app.clone(), app.clone());
    let builder = WebviewBuilder::new(label(id), WebviewUrl::External(url))
        .user_agent(user_agent())
        // the ads the rule list can't reach (YouTube's): see adblock.js
        .initialization_script_for_all_frames(include_str!("../adblock.js"))
        // ⌘F: the video fills the page
        .initialization_script(include_str!("../video.js"))
        // Google's results in the ReSurf look
        .initialization_script(search_script())
        .on_page_load(move |webview, payload| {
            let loading = payload.event() == PageLoadEvent::Started;
            let eink = load_app.state::<AppState>().eink.load(Ordering::Relaxed);
            if eink {
                let _ = webview.eval(eink_script(true));
            }
            if is_full() {
                let _ = webview.eval(full_script(true));
            }
            if !loading {
                let icon_app = load_app.clone();
                let _ = webview.eval_with_callback(ICON_SCRIPT, move |result| {
                    if let Ok(icon) = serde_json::from_str::<String>(&result) {
                        to_ui(&icon_app, "tab", TabEvent { id, icon: Some(icon), ..Default::default() });
                    }
                });
            }
            let url = Some(payload.url().to_string());
            to_ui(&load_app, "tab", TabEvent { id, url, loading: Some(loading), ..Default::default() });
        })
        .on_document_title_changed(move |_, title| {
            to_ui(&title_app, "tab", TabEvent { id, title: Some(title), ..Default::default() });
        })
        // links that want a new window (target=_blank, window.open) open as a new tab
        .on_new_window(move |url, _| {
            to_ui(&open_app, "open", url.to_string());
            NewWindowResponse::Deny
        });
    let size = LogicalSize::new(bounds.width.max(1.0), bounds.height.max(1.0));
    let webview = window.add_child(builder, LogicalPosition::new(bounds.x, bounds.y), size).map_err(err)?;
    #[cfg(target_os = "macos")]
    {
        round_corners(&webview);
        adblock::attach(&webview);
    }
    Ok(webview)
}

// ── state ──

/// The tabs, the favourites and the settings, as the UI saved them (JSON).
#[tauri::command]
fn load_state(state: State<AppState>) -> Option<String> {
    std::fs::read_to_string(&state.state_file).ok()
}

#[tauri::command]
fn save_state(state: State<AppState>, json: String) -> CmdResult<()> {
    // write next to it, then swap, so a crash never leaves half a file
    let tmp = state.state_file.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(err)?;
    std::fs::rename(&tmp, &state.state_file).map_err(err)
}

// ── tabs ──

/// Shows tab `id` over the page card (creating its webview the first time) and hides the rest.
#[tauri::command]
fn show_tab(app: AppHandle, id: u64, url: String, bounds: Bounds, focus: bool) -> CmdResult<()> {
    for webview in tabs(&app).filter(|w| w.label() != label(id)) {
        let _ = webview.hide();
    }
    let webview = match app.get_webview(&label(id)) {
        Some(webview) => {
            webview.set_bounds(bounds.rect()).map_err(err)?;
            webview.show().map_err(err)?;
            webview
        }
        None => create_tab(&app, id, Url::parse(&url).map_err(err)?, &bounds)?,
    };
    if focus {
        webview.set_focus().map_err(err)?;
    }
    Ok(())
}

/// Start page and popups: no page on top of the UI, and the UI gets the keyboard.
#[tauri::command]
fn hide_tabs(app: AppHandle) -> CmdResult<()> {
    for webview in tabs(&app) {
        let _ = webview.hide();
    }
    if let Some(ui) = app.get_webview("main") {
        ui.set_focus().map_err(err)?;
    }
    Ok(())
}

#[tauri::command]
fn navigate(app: AppHandle, id: u64, url: String) -> CmdResult<()> {
    let Some(webview) = app.get_webview(&label(id)) else { return Ok(()) };
    webview.navigate(Url::parse(&url).map_err(err)?).map_err(err)
}

/// Closes the tab's webview; the page is gone, the UI decides whether the tab stays.
#[tauri::command]
fn close_tab(app: AppHandle, id: u64) -> CmdResult<()> {
    if let Some(webview) = app.get_webview(&label(id)) {
        webview.close().map_err(err)?;
    }
    Ok(())
}

fn eval_in(app: &AppHandle, id: u64, js: &str) -> CmdResult<()> {
    match app.get_webview(&label(id)) {
        Some(webview) => webview.eval(js).map_err(err),
        None => Ok(()),
    }
}

#[tauri::command]
fn go_back(app: AppHandle, id: u64) -> CmdResult<()> {
    eval_in(&app, id, "history.back()")
}

#[tauri::command]
fn go_forward(app: AppHandle, id: u64) -> CmdResult<()> {
    eval_in(&app, id, "history.forward()")
}

#[tauri::command]
fn reload(app: AppHandle, id: u64) -> CmdResult<()> {
    match app.get_webview(&label(id)) {
        Some(webview) => webview.reload().map_err(err),
        None => Ok(()),
    }
}

/// ⌘F: the tab's video fills the page, or goes back (video.js).
#[tauri::command]
fn fill_video(app: AppHandle, id: u64) -> CmdResult<()> {
    eval_in(&app, id, "window.__resurfVideo?.()")
}

/// Where the tab is now; pages that change the address without loading (history.pushState)
/// don't send a page-load event, so the UI asks.
#[tauri::command]
fn tab_url(app: AppHandle, id: u64) -> Option<String> {
    app.get_webview(&label(id))?.url().ok().map(|u| u.to_string())
}

#[tauri::command]
fn set_eink(app: AppHandle, state: State<AppState>, on: bool) {
    state.eink.store(on, Ordering::Relaxed);
    let js = eink_script(on);
    for webview in tabs(&app) {
        let _ = webview.eval(&js);
    }
}

fn is_full() -> bool {
    CORNER_RADIUS.load(Ordering::Relaxed) == 12
}

/// The page hears of FULL (html.resurf-full): search results put their buttons where ReSurf's own are.
fn full_script(on: bool) -> String {
    format!("document.documentElement.classList.toggle('resurf-full', {on})")
}

/// FULL: the pages as round as the window, or back to the card's corners.
#[tauri::command]
fn set_full(app: AppHandle, on: bool) {
    CORNER_RADIUS.store(if on { 12 } else { 22 }, Ordering::Relaxed);
    for webview in tabs(&app) {
        let _ = webview.eval(full_script(on));
    }
    #[cfg(target_os = "macos")]
    for webview in tabs(&app) {
        round_corners(&webview);
    }
}

#[tauri::command]
fn copy_text(text: String) -> CmdResult<()> {
    use std::io::Write;
    let mut child = std::process::Command::new("pbcopy").stdin(std::process::Stdio::piped()).spawn().map_err(err)?;
    child.stdin.take().ok_or("No stdin")?.write_all(text.as_bytes()).map_err(err)?;
    child.wait().map(|_| ()).map_err(err)
}

// ── menu: the shortcuts work wherever the keyboard is, also inside a page ──

fn build_menu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Menu<R>> {
    let item = |id: &str, text: &str, accel: &str| MenuItem::with_id(app, id, text, true, Some(accel));
    let sep = || PredefinedMenuItem::separator(app);

    let app_menu = Submenu::with_items(
        app,
        "ReSurf",
        true,
        &[
            &PredefinedMenuItem::about(app, None, None)?,
            &sep()?,
            &PredefinedMenuItem::hide(app, None)?,
            &PredefinedMenuItem::hide_others(app, None)?,
            &PredefinedMenuItem::show_all(app, None)?,
            &sep()?,
            &PredefinedMenuItem::quit(app, None)?,
        ],
    )?;
    // pages need the standard edit commands for ⌘C / ⌘V / ⌘A to work
    let edit = Submenu::with_items(
        app,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(app, None)?,
            &PredefinedMenuItem::redo(app, None)?,
            &sep()?,
            &PredefinedMenuItem::cut(app, None)?,
            &PredefinedMenuItem::copy(app, None)?,
            &PredefinedMenuItem::paste(app, None)?,
            &PredefinedMenuItem::select_all(app, None)?,
        ],
    )?;
    let tabs = Submenu::with_items(
        app,
        "Tabs",
        true,
        &[
            &item("new", "New Tab", "CmdOrCtrl+T")?,
            &item("address", "Edit Address", "CmdOrCtrl+L")?,
            &item("close", "Close Tab", "CmdOrCtrl+W")?,
            &item("favo", "Favourite", "CmdOrCtrl+D")?,
            &sep()?,
            &item("next-tab", "Next Tab", "Ctrl+Tab")?,
            &item("prev-tab", "Previous Tab", "Ctrl+Shift+Tab")?,
        ],
    )?;
    let view = Submenu::with_items(
        app,
        "View",
        true,
        &[
            &item("back", "Back", "CmdOrCtrl+[")?,
            &item("forward", "Forward", "CmdOrCtrl+]")?,
            &item("reload", "Reload", "CmdOrCtrl+R")?,
            &item("video", "Video Fills the Page", "CmdOrCtrl+F")?,
            &sep()?,
            &item("full", "Page Fills the Window", "CmdOrCtrl+Shift+F")?,
            &item("eink", "E-ink", "CmdOrCtrl+E")?,
            &item("info", "Info", "CmdOrCtrl+I")?,
            &sep()?,
            &PredefinedMenuItem::fullscreen(app, None)?,
        ],
    )?;
    let window = Submenu::with_items(
        app,
        "Window",
        true,
        &[&PredefinedMenuItem::minimize(app, None)?, &PredefinedMenuItem::maximize(app, None)?],
    )?;
    Menu::with_items(app, &[&app_menu, &edit, &tabs, &view, &window])
}

/// No title bar at all (decorations are off in tauri.conf.json): macOS rims every titled window with
/// a light line that can't be turned off. The window is clear instead, its page is rounded here like a
/// window's corners, and the UI draws its own close / minimise / zoom buttons. No shadow either
/// (tauri.conf.json).
#[cfg(target_os = "macos")]
fn round_window(window: &tauri::WebviewWindow) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    let _ = window.with_webview(|platform| {
        let view = platform.inner() as *mut AnyObject;
        if view.is_null() {
            return;
        }
        // SAFETY: `inner()` is the live WKWebView (an NSView); this runs on the main thread.
        unsafe {
            let _: () = msg_send![view, setWantsLayer: true];
            let layer: *mut AnyObject = msg_send![view, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setCornerRadius: 12.0f64];
                let _: () = msg_send![layer, setMasksToBounds: true];
            }
            // clear where the page paints nothing: the card behind shows (and, for search
            // results, the paper: the card goes bare)
            let no: *mut AnyObject = msg_send![objc2::class!(NSNumber), numberWithBool: false];
            let key = objc2_foundation::NSString::from_str("drawsBackground");
            let _: () = msg_send![view, setValue: no, forKey: &*key];
        }
    });
}

/// The window starts hidden (tauri.conf.json) and fades in once the interface has drawn itself
/// (window_ready), so the app opens softly instead of appearing empty.
#[cfg(target_os = "macos")]
fn fade_in(window: &tauri::Window) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};

    if window.is_visible().unwrap_or(true) {
        return;
    }
    let Ok(ns_window) = window.ns_window() else {
        let _ = window.show();
        return;
    };
    let ns_window = ns_window as *mut AnyObject;
    // SAFETY: the live NSWindow of `window`, on the main thread (see reveal).
    unsafe {
        let _: () = msg_send![ns_window, setAlphaValue: 0.0f64];
    }
    let _ = window.show();
    let _ = window.set_focus();
    unsafe {
        let _: () = msg_send![class!(NSAnimationContext), beginGrouping];
        let context: *mut AnyObject = msg_send![class!(NSAnimationContext), currentContext];
        let _: () = msg_send![context, setDuration: 0.3f64];
        let name: *mut AnyObject = msg_send![class!(NSString), stringWithUTF8String: c"easeOut".as_ptr()];
        let timing: *mut AnyObject = msg_send![class!(CAMediaTimingFunction), functionWithName: name];
        let _: () = msg_send![context, setTimingFunction: timing];
        let animator: *mut AnyObject = msg_send![ns_window, animator];
        let _: () = msg_send![animator, setAlphaValue: 1.0f64];
        let _: () = msg_send![class!(NSAnimationContext), endGrouping];
    }
}

/// Fades the window in on the main thread; `after` waits first (the fallback, should the interface never say it is ready).
fn reveal(window: &tauri::Window, after: std::time::Duration) {
    let window = window.clone();
    std::thread::spawn(move || {
        std::thread::sleep(after);
        let target = window.clone();
        let _ = window.run_on_main_thread(move || {
            #[cfg(target_os = "macos")]
            fade_in(&target);
            #[cfg(not(target_os = "macos"))]
            let _ = target.show();
        });
    });
}

/// The interface has drawn itself (main.ts): the window can fade in.
#[tauri::command]
fn window_ready(webview: tauri::Webview) {
    // the webview's window: ReSurf's holds its tabs' webviews too
    reveal(&webview.window(), std::time::Duration::ZERO);
}

/// ReDesk's Hide / Show Windows (a distributed notification, "hide" or "show"): the windows fade out
/// and then the app hides, or the app shows again with its windows fading in.
#[cfg(target_os = "macos")]
fn listen_for_desk_fades() {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use std::ffi::CStr;

    /// every window of the app animated to `alpha`, then `done`
    unsafe fn animate(alpha: f64, done: Option<&block2::Block<dyn Fn()>>) {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let windows: *mut AnyObject = msg_send![app, windows];
        let count: usize = msg_send![windows, count];
        let _: () = msg_send![class!(NSAnimationContext), beginGrouping];
        let context: *mut AnyObject = msg_send![class!(NSAnimationContext), currentContext];
        let _: () = msg_send![context, setDuration: 0.25f64];
        if let Some(done) = done {
            let _: () = msg_send![context, setCompletionHandler: done];
        }
        for i in 0..count {
            let window: *mut AnyObject = msg_send![windows, objectAtIndex: i];
            let animator: *mut AnyObject = msg_send![window, animator];
            let _: () = msg_send![animator, setAlphaValue: alpha];
        }
        let _: () = msg_send![class!(NSAnimationContext), endGrouping];
    }

    /// every window's alpha set at once
    unsafe fn set_alpha(alpha: f64) {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let windows: *mut AnyObject = msg_send![app, windows];
        let count: usize = msg_send![windows, count];
        for i in 0..count {
            let window: *mut AnyObject = msg_send![windows, objectAtIndex: i];
            let _: () = msg_send![window, setAlphaValue: alpha];
        }
    }

    let handler = RcBlock::new(|note: *mut AnyObject| {
        // SAFETY: on the main queue, with AppKit's own objects
        unsafe {
            let object: *mut AnyObject = msg_send![note, object];
            if object.is_null() {
                return;
            }
            let text: *const std::os::raw::c_char = msg_send![object, UTF8String];
            if text.is_null() {
                return;
            }
            let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
            let hidden: bool = msg_send![app, isHidden];
            match CStr::from_ptr(text).to_bytes() {
                b"hide" if !hidden => {
                    let done = RcBlock::new(|| {
                        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
                        let _: () = msg_send![app, hide: std::ptr::null::<AnyObject>()];
                        set_alpha(1.0);
                    });
                    animate(0.0, Some(&done));
                }
                b"show" if hidden => {
                    set_alpha(0.0);
                    let _: () = msg_send![app, unhideWithoutActivation];
                    animate(1.0, None);
                }
                _ => {}
            }
        }
    });
    // SAFETY: the center copies the block and keeps the observer for the app's life
    unsafe {
        let center: *mut AnyObject = msg_send![class!(NSDistributedNotificationCenter), defaultCenter];
        let name: *mut AnyObject =
            msg_send![class!(NSString), stringWithUTF8String: c"com.artursavytskyi.re.windows".as_ptr()];
        let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), mainQueue];
        let _: *mut AnyObject = msg_send![center, addObserverForName: name, object: std::ptr::null::<AnyObject>(),
                                          queue: queue, usingBlock: &*handler];
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .register_asynchronous_uri_scheme_protocol("resurf", |_ctx, request, responder| {
            let uri = request.uri().to_string();
            std::thread::spawn(move || {
                let page = if uri.contains("/focus") { focus_page(&uri) } else { Vec::new() };
                let response = tauri::http::Response::builder()
                    .header("Content-Type", "text/html; charset=utf-8")
                    .body(page);
                if let Ok(response) = response {
                    responder.respond(response);
                }
            });
        })
        .setup(|app| {
            #[cfg(target_os = "macos")]
            listen_for_desk_fades();
            // ~/Library/Application Support/<identifier>/ on macOS
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            app.manage(AppState { state_file: dir.join("state.json"), eink: AtomicBool::new(false) });

            app.set_menu(build_menu(app.handle())?)?;
            app.on_menu_event(|app, event| to_ui(app, "menu", event.id().0.clone()));

            #[cfg(target_os = "macos")]
            {
                if let Some(window) = app.get_webview_window("main") {
                    round_window(&window);
                    let _ = window.with_webview(|platform| {
                        one_cursor::install(platform.inner() as *mut objc2::runtime::AnyObject)
                    });
                    reveal(&window.as_ref().window(), std::time::Duration::from_secs(3));
                }
                adblock::prepare(app.handle());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            window_ready,
            load_state,
            save_state,
            show_tab,
            hide_tabs,
            navigate,
            close_tab,
            go_back,
            go_forward,
            reload,
            fill_video,
            tab_url,
            set_eink,
            set_full,
            copy_text,
        ])
        .run(tauri::generate_context!())
        .expect("error while running ReSurf");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tab_labels_round_trip() {
        assert_eq!(tab_id(&label(42)), Some(42));
        assert_eq!(tab_id("main"), None);
        assert_eq!(tab_id("tab-x"), None);
    }

    #[test]
    fn safari_version_is_read_from_the_plist() {
        let plist = "<key>CFBundleShortVersionString</key>\n\t<string>26.5</string>";
        assert_eq!(safari_version(plist), Some("26.5"));
        assert_eq!(safari_version(""), None);
    }

    #[test]
        fn eink_script_switches_the_style() {
        assert!(eink_script(true).contains("if (true)"));
        assert!(eink_script(false).contains("if (false)"));
        assert!(eink_script(true).contains("grayscale(1)"));
    }
}
