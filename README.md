# ReSurf

A quiet browser for macOS in the style of ReNote. Rust (Tauri) holds one WebKit
webview per tab; the interface is Svelte.

- **Tabs**: favourites run down the left edge, the other open tabs down the right one.
  FAVO pins the open tab to the left; closing a favourite only unloads it.
- **Page**: shown in a card with the site as the title and the path under it, between ← and →.
- **E-ink**: EINK turns every page grey with a little more contrast and stops animations.
- **Search**: NEW opens it; an address goes straight there, anything else is searched with Brave Search.
- Keys: ⌘T new tab · ⌘L address · ⌘W close · ⌘D favourite · ⌘[ ⌘] back / forward ·
  ⌘R reload · ⌃Tab next tab · ⌘E e-ink · ⌘I info · right click on a tab for actions

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReSurf.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.

Tabs and favourites live in `~/Library/Application Support/com.artursavytskyi.resurf/state.json`;
cookies and site data in WebKit's own store. No history is kept.
