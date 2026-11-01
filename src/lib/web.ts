// Bridge to Rust (src-tauri/src/lib.rs) and helpers for addresses.
import { invoke } from '@tauri-apps/api/core';

export interface Tab {
	id: number;
	url: string;
	title: string;
	/** the site's icon, read from the page once it has loaded */
	icon?: string;
	/** favourites stay on the left and are kept when closed */
	favorite: boolean;
	/** where a favourite was pinned; closing it goes back there */
	home?: string;
}

export interface Saved {
	tabs: Tab[];
	active: number | null;
	eink: boolean;
	nextId: number;
}

export interface Bounds {
	x: number;
	y: number;
	width: number;
	height: number;
}

export const api = {
	loadState: () => invoke<string | null>('load_state'),
	saveState: (json: string) => invoke<void>('save_state', { json }),
	showTab: (id: number, url: string, bounds: Bounds, focus: boolean) => invoke<void>('show_tab', { id, url, bounds, focus }),
	hideTabs: () => invoke<void>('hide_tabs'),
	navigate: (id: number, url: string) => invoke<void>('navigate', { id, url }),
	closeTab: (id: number) => invoke<void>('close_tab', { id }),
	back: (id: number) => invoke<void>('go_back', { id }),
	forward: (id: number) => invoke<void>('go_forward', { id }),
	reload: (id: number) => invoke<void>('reload', { id }),
	fillVideo: (id: number) => invoke<void>('fill_video', { id }),
	tabUrl: (id: number) => invoke<string | null>('tab_url', { id }),
	setEink: (on: boolean) => invoke<void>('set_eink', { on }),
	copy: (text: string) => invoke<void>('copy_text', { text }),
};

// Google's Web filter (udm=14): just the links, which src-tauri/search.js redraws in the ReSurf look
const SEARCH = 'https://www.google.com/search?udm=14&q=';

/** What was typed into Search → an address: a URL as is, a bare domain over https, anything else searched with Google. */
export function toUrl(input: string): string {
	const text = input.trim();
	if (/^[a-z][a-z0-9+.-]*:\/\//i.test(text) || /^(about|data):/i.test(text)) return text;
	const looksLikeHost = !/\s/.test(text) && (/^[^/]+\.[a-z]{2,}(:\d+)?(\/.*)?$/i.test(text) || /^localhost(:\d+)?(\/.*)?$/i.test(text));
	if (looksLikeHost) return `${text.startsWith('localhost') ? 'http' : 'https'}://${text}`;
	return SEARCH + encodeURIComponent(text);
}

/** Google's web, image and video results (udm 14 / 2 / 7) and the focus search (resurf://localhost/focus,
 * Marginalia's): search.js draws them on the paper, without the card around the page */
export function isSearch(url: string): boolean {
	const u = parse(url);
	if (!u) return false;
	if (u.protocol === 'resurf:') return u.pathname === '/focus';
	return /(^|\.)google\.[a-z.]+$/.test(u.hostname) && u.pathname === '/search' && ['14', '2', '7'].includes(u.searchParams.get('udm') ?? '');
}

/** What was searched: shown where the site would be */
export function searchQuery(url: string): string {
	return parse(url)?.searchParams.get('q') ?? '';
}

function parse(url: string): URL | null {
	try {
		return new URL(url);
	} catch {
		return null;
	}
}

/** "nytimes.com" — shown as the title */
export function host(url: string): string {
	const u = parse(url);
	return u ? u.hostname.replace(/^www\./, '') || url : url;
}

/** "/international" — shown under the page */
export function path(url: string): string {
	const u = parse(url);
	if (!u) return '';
	let p = u.pathname + u.search;
	try {
		p = decodeURIComponent(p);
	} catch {
		// keep it encoded
	}
	return p === '/' ? '/' : p.replace(/\/$/, '');
}

export function letter(url: string): string {
	return (host(url)[0] ?? '·').toUpperCase();
}
