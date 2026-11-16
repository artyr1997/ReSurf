// Glass (an experiment, ReDesk's Settings › Glass windows): the window is the system's blur of what is
// behind it (src-tauri's set_glass) and the page goes clear, written in the desk's white ink (html.glass in
// app.css). ReDesk keeps it (read at start, `desk_glass`) and says when it changes (a `glass` event).
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

function set(on: boolean) {
	document.documentElement.classList.toggle('glass', on);
	invoke('set_glass', { on }).catch(() => {});
	// what draws in the theme's ink (a canvas, a PDF page) draws again in the new one
	dispatchEvent(new Event('themechange'));
}

/** once, at start: as ReDesk keeps it, and again when it changes */
export function followDeskGlass() {
	if (!('__TAURI_INTERNALS__' in window)) return;
	invoke<boolean>('desk_glass').then(set).catch(() => {});
	listen<boolean>('glass', e => set(e.payload));
}
