//! ReSurf: a quiet browser in the ReNote style.
//! The window holds the Svelte UI (label `main`) and one native webview per open
//! tab (label `tab-<id>`), laid over the page card the UI draws. Tab webviews
//! load remote pages and get no IPC permissions (see capabilities/default.json);
//! what they do comes back to the UI as `tab` / `open` events from Rust.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
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

/// E-ink: pages in greys with a little more contrast, white turned into the paper
/// (#F4F4F4 = 0.957 of white), and nothing moves.
const EINK_CSS: &str = "\
html { filter: grayscale(1) contrast(1.12) brightness(0.957) !important; scroll-behavior: auto !important; }
*, *::before, *::after {
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

/// Rounded corners like the cards in the other Re apps.
#[cfg(target_os = "macos")]
fn round_corners<R: Runtime>(webview: &Webview<R>) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    let _ = webview.with_webview(|platform| {
        let view = platform.inner() as *mut AnyObject;
        if view.is_null() {
            return;
        }
        // SAFETY: `inner()` is the live WKWebView (an NSView); this runs on the main thread.
        unsafe {
            let _: () = msg_send![view, setWantsLayer: true];
            let layer: *mut AnyObject = msg_send![view, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setCornerRadius: 22.0f64];
                let _: () = msg_send![layer, setMasksToBounds: true];
            }
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

fn create_tab<R: Runtime>(app: &AppHandle<R>, id: u64, url: Url, bounds: &Bounds) -> CmdResult<Webview<R>> {
    let window = app.get_window("main").ok_or("No window")?;
    let (load_app, title_app, open_app) = (app.clone(), app.clone(), app.clone());
    let builder = WebviewBuilder::new(label(id), WebviewUrl::External(url))
        .user_agent(user_agent())
        // the ads the rule list can't reach (YouTube's): see adblock.js
        .initialization_script_for_all_frames(include_str!("../adblock.js"))
        // ⌘F: the video fills the page
        .initialization_script(include_str!("../video.js"))
        .on_page_load(move |webview, payload| {
            let loading = payload.event() == PageLoadEvent::Started;
            let eink = load_app.state::<AppState>().eink.load(Ordering::Relaxed);
            if eink {
                let _ = webview.eval(eink_script(true));
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
        }
    });
}

/// The window starts hidden (tauri.conf.json) and fades in once its page has loaded, so the app
/// opens softly instead of appearing at once.
#[cfg(target_os = "macos")]
fn fade_in(window: &tauri::WebviewWindow) {
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
        let _: () = msg_send![context, setDuration: 0.45f64];
        let name: *mut AnyObject = msg_send![class!(NSString), stringWithUTF8String: c"easeOut".as_ptr()];
        let timing: *mut AnyObject = msg_send![class!(CAMediaTimingFunction), functionWithName: name];
        let _: () = msg_send![context, setTimingFunction: timing];
        let animator: *mut AnyObject = msg_send![ns_window, animator];
        let _: () = msg_send![animator, setAlphaValue: 1.0f64];
        let _: () = msg_send![class!(NSAnimationContext), endGrouping];
    }
}

/// Fades the window in on the main thread; `after` waits first (the fallback, should the page never load).
fn reveal(window: &tauri::WebviewWindow, after: std::time::Duration) {
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .on_page_load(|webview, payload| {
            use tauri::Manager;
            if webview.label() == "main" && matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                if let Some(window) = webview.app_handle().get_webview_window("main") {
                    reveal(&window, std::time::Duration::ZERO);
                }
            }
        })
        .setup(|app| {
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
                    reveal(&window, std::time::Duration::from_secs(4));
                }
                adblock::prepare(app.handle());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
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
