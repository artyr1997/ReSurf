// The desk's language, as ReDesk's Settings › Language says (English or Japanese): the side buttons are
// written in it. ReDesk keeps it (read at start, `desk_language`) and says when it changes (a `language`
// event from src-tauri's listen_for_desk_language). A word not here stays in English.
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

const japanese: Record<string, string> = {
	// four characters each, as the English words are four letters
	COLM: '縦列表示',
	LIST: '一覧表示',
	INFO: '詳細情報',
	DEL: '削除する',
	SONG: '楽曲一覧',
	LIVE: 'ラジオ局',
	MINI: 'ミニ表示',
	PREV: '前の曲へ',
	NEXT: '次の曲へ',
	READ: '中を見る',
	ADD: '追加する',
	EDIT: '編集する',
	NEW: '新規作成',
	CLOSE: '閲覧終了',
	BACK: '前に戻る',
	FULL: '全画面化',
	MANGA: '右から左',
	FAVO: '栞を挟む',
	PEN: 'ペン書き',
	BRUSH: '筆で書く',
	UNDO: '元に戻す',
	PAD: '指で描く',
	SAVE: '保存する',
	RUB: '消しゴム',
	EXIT: '編集終了',
	IMP: '読み込み',
	EXP: '書き出し',
	HOME: 'ホームへ',
	'NEW TAB': '新規タブ',
	'FULL NOTE': '全文表示',
	'NEXT SPACE': '次の場所',
};

export const language = $state({ japanese: false });

// The language turning, as on a departures board: each letter runs through others (Latin and katakana)
// before it stops at its new one, the first soonest, the next a little later (as ReDesk's corner words).
const POOL = [...'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'];
const STEP = 55, SETTLE = 260, STAGGER = 110, LENGTH = 1200;
const flap = $state({ frame: -1 });

/** a button's word in the desk's language; `as` names it where the same word means another thing (NEW TAB) */
export function t(word: string, as?: string): string {
	const target = language.japanese ? (japanese[as ?? word] ?? word) : word;
	const frame = flap.frame;
	if (frame < 0) return target;
	const elapsed = frame * STEP;
	return [...target]
		.map((letter, i) => {
			if (letter === ' ' || elapsed >= SETTLE + i * STAGGER) return letter;
			let hash = frame * 31 + i * 17;
			for (const c of as ?? word) hash = (hash * 33 + c.charCodeAt(0)) | 0;
			return POOL[Math.abs(hash) % POOL.length];
		})
		.join('');
}

let flapTimer: ReturnType<typeof setInterval> | null = null;
function turn() {
	if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
	if (flapTimer) clearInterval(flapTimer);
	flap.frame = 0;
	flapTimer = setInterval(() => {
		if ((flap.frame + 1) * STEP > LENGTH) {
			flap.frame = -1;
			clearInterval(flapTimer!);
			flapTimer = null;
		} else flap.frame++;
	}, STEP);
}

function set(code: string, animate = false) {
	const japanese = code === 'ja';
	if (animate && japanese !== language.japanese) turn();
	language.japanese = japanese;
	document.documentElement.lang = language.japanese ? 'ja' : 'en';
}

/** once, at start: the language ReDesk keeps, and its word when it changes */
export function followDeskLanguage() {
	if (!('__TAURI_INTERNALS__' in window)) return;
	invoke<string>('desk_language').then(set).catch(() => {});
	listen<string>('language', e => set(e.payload, true));
}
