// Glass (an experiment, ReDesk's Settings › Glass windows): the window is the system's blur of what is
// behind it (src-tauri's set_glass) and the page goes clear, written in the desk's white ink (html.glass in
// app.css). ReDesk keeps it (read at start, `desk_glass`) and says when it changes (a `glass` event).
// Joined to others (Flush), ReDesk lays one glass under them all (`glass-shared`): the window drops its own,
// so they are one glass, no seams where they meet.
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

let glass = false;
let shared = false;

function apply() {
	const was = document.documentElement.classList.contains('glass');
	document.documentElement.classList.toggle('glass', glass);
	// on glass the corners are square, its own glass or the one under them all
	invoke('set_glass', { on: glass && !shared, sharp: glass }).catch(() => {});
	// what draws in the theme's ink (a canvas, a PDF page) draws again in the new one
	if (was !== glass) dispatchEvent(new Event('themechange'));
}

/** once, at start: as ReDesk keeps it, and again when it changes */
export function followDeskGlass() {
	if (!('__TAURI_INTERNALS__' in window)) return;
	invoke<boolean>('desk_glass')
		.then(on => {
			glass = on;
			apply();
		})
		.catch(() => {});
	listen<boolean>('glass', e => {
		glass = e.payload;
		apply();
	});
	listen<boolean>('glass-shared', e => {
		if (e.payload === shared) return;
		shared = e.payload;
		apply();
	});
}
