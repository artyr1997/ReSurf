// Glass: the Re apps' one look. The window is the system's blur of what is behind it (src-tauri's set_glass)
// and the page is clear on it, written in the desk's white ink (html.glass in app.css; the page has the class
// from its first frame, index.html). Joined to others (Flush), ReDesk lays one glass under them all
// (`glass-shared`): the window drops its own, so they are one glass, no seams where they meet.
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

let shared = false;

/** the window's own glass, or none while ReDesk's is under it; the corners square either way */
const apply = () => invoke('set_glass', { on: !shared, sharp: true }).catch(() => {});

/** once, at start */
export function followDeskGlass() {
	const root = document.documentElement;
	root.classList.add('glass');
	// its inked words light, as on the night's paper (the rules for it are under [data-theme='dark'])
	root.dataset.theme = 'dark';
	if (!('__TAURI_INTERNALS__' in window)) return;
	apply();
	listen<boolean>('glass-shared', (e) => {
		if (e.payload === shared) return;
		shared = e.payload;
		apply();
	});
}
