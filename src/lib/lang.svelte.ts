// The desk's language, as ReDesk's Settings › Language says (English or Japanese): the side buttons are
// written in it. ReDesk keeps it (read at start, `desk_language`) and says when it changes (a `language`
// event from src-tauri's listen_for_desk_language). A word not here stays in English.
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

const japanese: Record<string, string> = {
	// ReFile
	COLM: '列',
	LIST: '一覧',
	INFO: '情報',
	DEL: '削除',
	SONG: '曲',
	LIVE: 'ラジオ',
	MINI: 'ミニ',
	PREV: '前',
	NEXT: '次',
	READ: '読む',
	ADD: '追加',
	EDIT: '編集',
	NEW: '新規',
	CLOSE: '閉じる',
	BACK: '戻る',
	FULL: '全画面',
	MANGA: '漫画',
	// ReSurf
	FAVO: '好き',
	// ReDraw
	PEN: 'ペン',
	BRUSH: '筆',
	UNDO: '戻す',
	PAD: 'パッド',
	SAVE: '保存',
	RUB: '消す',
	// ReNote
	EXIT: '終了',
	IMP: '読込',
	EXP: '書出',
	HOME: 'ホーム',
};

export const language = $state({ japanese: false });

/** a button's word in the desk's language */
export function t(word: string): string {
	return language.japanese ? (japanese[word] ?? word) : word;
}

function set(code: string) {
	language.japanese = code === 'ja';
	document.documentElement.lang = language.japanese ? 'ja' : 'en';
}

/** once, at start: the language ReDesk keeps, and its word when it changes */
export function followDeskLanguage() {
	if (!('__TAURI_INTERNALS__' in window)) return;
	invoke<string>('desk_language').then(set).catch(() => {});
	listen<string>('language', e => set(e.payload));
}
