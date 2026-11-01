# ReSurf

A quiet browser for macOS in the style of ReNote. Rust (Tauri) holds one WebKit
webview per tab; the interface is Svelte.

- **Tabs**: favourites run down the left edge, the other open tabs down the right one.
  FAVO pins the open tab to the left; closing a favourite only unloads it.
- **Page**: shown in a card with the site above it and the page's title under it, between ← and →.
- **Video**: ⌘F stretches the page's video, with its player, over the whole page (the window stays
  as it is); ⌘F again or Esc puts it back.
- **E-ink**: EINK turns every page grey with a little more contrast and stops animations.
- **No ads**: EasyList + EasyPrivacy as a WebKit content rule list (like Safari's content blockers):
  requests to ad and tracking servers are not made, and ad slots are hidden. WebKit compiles the
  list once (a few seconds on the first launch). `python3 scripts/adblock.py` fetches the lists again
  and rewrites `src-tauri/adblock.json`. Ads a site serves itself are for `src-tauri/adblock.js`, a
  script that runs in every page before the site's own: on YouTube it takes the ads out of the
  player's data, hides the ad slots and the anti-adblock popup, and should an ad play all the same,
  mutes it, runs it to its end and presses Skip.
- **Search**: NEW opens it; an address goes straight there, anything else is searched with Google (its Web results, redrawn in the ReSurf look: ↑ / ↓ choose one, Enter opens it; see src-tauri/search.js).
- Keys: ⌘T new tab · ⌘L address · ⌘W close · ⌘D favourite · ⌘[ ⌘] back / forward ·
  ⌘R reload · ⌘F video fills the page · ⌃Tab next tab · ⌘E e-ink · ⌘I info · right click on a tab for actions

## Run

```sh
npm install
npm run desktop        # dev window with live reload
npm run desktop:build  # ReSurf.app + .dmg in src-tauri/target/release/bundle/
```

Rust tests: `cd src-tauri && cargo test`.

Tabs and favourites live in `~/Library/Application Support/com.artursavytskyi.resurf/state.json`;
cookies and site data in WebKit's own store. No history is kept.
