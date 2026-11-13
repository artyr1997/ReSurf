<script lang="ts">
	// The browser. Favourites run down the left edge, the other open tabs down the
	// right one. The page sits in the card in the middle: it is a native webview
	// that Rust lays over the card (show_tab), so whenever the UI needs that space
	// (Search, popups) the webview is hidden and the card is plain paper.
	import { onMount, tick, untrack } from 'svelte';
	import { getCurrentWebview } from '@tauri-apps/api/webview';
	import WindowControls from './lib/WindowControls.svelte';
	import Popup from './lib/Popup.svelte';
	import { scrollFade } from './lib/scrollFade';
	import { api, toUrl, host, path, letter, isSearch, searchQuery, type Tab, type Saved, type Bounds } from './lib/web';

	type Mode = 'page' | 'search';
	type PopupKind = 'none' | 'actions' | 'info';
	type TabEvent = { id: number; url?: string; title?: string; loading?: boolean; icon?: string };

	let tabs: Tab[] = $state([]);
	let active: number | null = $state(null);
	let eink = $state(false);
	// FULL: the page over the whole window, nothing around it (⌘⇧F, or FULL, goes back)
	let full = $state(false);
	let nextId = $state(1);
	let ready = $state(false);

	let mode = $state<Mode>('search');
	// Search either opens a new tab or takes the current one somewhere else
	let editing = $state<'new' | 'address'>('new');
	let query = $state('');
	let searchInput: HTMLInputElement | undefined = $state();

	let loading: Record<number, boolean> = $state({});
	let brokenIcon: Record<number, boolean> = $state({});

	let favorites = $derived(tabs.filter(t => t.favorite));
	let others = $derived(tabs.filter(t => !t.favorite));
	let current: Tab | undefined = $derived(tabs.find(t => t.id === active));

	// ── the page card and the webview over it ──

	let card: HTMLDivElement | undefined = $state();
	let bounds: Bounds | null = $state(null);
	let popup = $state<PopupKind>('none');
	let showing = $derived(mode === 'page' && popup === 'none' && !!current);
	// search results lie on the paper itself: no card, what was searched above in place of the site,
	// nothing below: the pages turn with PREV / NEXT at the sides (see search.js)
	let results = $derived(mode === 'page' && !!current && isSearch(current.url));

	function measure() {
		if (!card) return;
		const r = card.getBoundingClientRect();
		bounds = { x: r.left, y: r.top, width: r.width, height: r.height };
	}

	$effect(() => {
		if (!card) return;
		const observer = new ResizeObserver(measure);
		observer.observe(card);
		measure();
		return () => observer.disconnect();
	});

	// a tab picked with ⌥ + arrows leaves the keys with the UI, so the next ⌥ + arrow works too;
	// anything else hands them to the page
	let pageTakesKeys = true;

	$effect(() => {
		const b = bounds;
		const tab = current;
		if (showing && tab && b) {
			// the address only matters the first time, when the webview is created
			api.showTab(tab.id, untrack(() => tab.url), b, pageTakesKeys);
		} else {
			api.hideTabs().then(() => {
				if (mode === 'search') searchInput?.focus();
			});
		}
	});

	// ── saving: tabs, favourites and e-ink survive a restart ──

	// this window's interface: the first window ("main") is the one kept; those ⌘N opens ("w2", "w3"…)
	// start clean, keep nothing, and number their tabs from a million times their number, so no two
	// windows' tabs share an id (each tab's webview is named by it: lib.rs)
	const ui = getCurrentWebview();
	const isMain = ui.label === 'main';
	const firstId = isMain ? 1 : (Number(ui.label.slice(1)) || 2) * 1_000_000;

	let saveTimer: ReturnType<typeof setTimeout> | null = null;
	$effect(() => {
		const json = JSON.stringify({ tabs, active, eink, full, nextId } satisfies Saved);
		if (!ready || !isMain) return;
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(() => api.saveState(json), 300);
	});

	async function restore() {
		const text = await api.loadState().catch(() => null);
		nextId = firstId;
		if (text && !isMain) {
			// another window: only e-ink, which is the app's
			try {
				eink = !!(JSON.parse(text) as Saved).eink;
			} catch {}
		} else if (text) {
			try {
				const saved = JSON.parse(text) as Saved;
				tabs = saved.tabs ?? [];
				nextId = saved.nextId ?? tabs.reduce((m, t) => Math.max(m, t.id + 1), 1);
				eink = !!saved.eink;
				full = !!saved.full;
				active = tabs.some(t => t.id === saved.active) ? saved.active : null;
			} catch {
				// a damaged file: start clean
			}
		}
		if (eink) api.setEink(true);
		mode = active === null ? 'search' : 'page';
		ready = true;
	}

	// ── tabs ──

	function activate(id: number, takeKeys = true) {
		pageTakesKeys = takeKeys;
		active = id;
		mode = 'page';
		popup = 'none';
	}

	function openTab(url: string) {
		const tab: Tab = { id: nextId++, url, title: '', favorite: false };
		tabs.push(tab);
		activate(tab.id);
	}

	async function newTab() {
		popup = 'none';
		editing = 'new';
		query = '';
		mode = 'search';
		await tick();
		searchInput?.focus();
	}

	async function editAddress() {
		if (!current) return newTab();
		popup = 'none';
		editing = 'address';
		query = current.url;
		mode = 'search';
		await tick();
		searchInput?.focus();
		searchInput?.select();
	}

	function submit() {
		if (!query.trim()) return;
		const url = toUrl(query);
		if (editing === 'address' && current) {
			current.url = url;
			api.navigate(current.id, url);
			activate(current.id);
		} else {
			openTab(url);
		}
		query = '';
	}

	function cancelSearch() {
		query = '';
		if (current) mode = 'page';
	}

	/** Favourites are kept: closing one unloads it and takes it back to where it was pinned. */
	function closeTab(id: number | null, remove = false) {
		const tab = tabs.find(t => t.id === id);
		if (!tab) return;
		api.closeTab(tab.id);
		delete loading[tab.id];
		if (tab.favorite && !remove) {
			tab.url = tab.home ?? tab.url;
			if (active === tab.id) {
				active = null;
				newTab();
			}
			return;
		}
		const list = tab.favorite ? favorites : others;
		const at = list.indexOf(tab);
		const neighbour = list[at + 1] ?? list[at - 1];
		tabs = tabs.filter(t => t.id !== tab.id);
		if (active === tab.id) {
			if (neighbour) activate(neighbour.id);
			else {
				active = null;
				newTab();
			}
		}
	}

	function toggleFavorite(id: number | null) {
		const tab = tabs.find(t => t.id === id);
		if (!tab) return;
		tab.favorite = !tab.favorite;
		tab.home = tab.favorite ? tab.url : undefined;
	}

	function cycle(delta: number, takeKeys = true) {
		const order = [...favorites, ...others];
		if (!order.length) return;
		const at = order.findIndex(t => t.id === active);
		const next = at < 0 ? (delta > 0 ? 0 : order.length - 1) : (at + delta + order.length) % order.length;
		activate(order[next].id, takeKeys);
	}

	// the tab last open in each column, to come back to when switching sides
	let lastIn: { favorites: number | null; others: number | null } = { favorites: null, others: null };
	$effect(() => {
		if (current) lastIn[current.favorite ? 'favorites' : 'others'] = current.id;
	});

	function toColumn(side: 'favorites' | 'others') {
		const list = side === 'favorites' ? favorites : others;
		if (!list.length) return;
		const tab = list.find(t => t.id === lastIn[side]) ?? list[0];
		activate(tab.id, false);
	}

	// the open tab is kept in sight when the column scrolls
	$effect(() => {
		if (active === null || mode !== 'page') return;
		tick().then(() => document.querySelector('.tab.active')?.scrollIntoView({ block: 'nearest' }));
	});

	function toggleFull() {
		full = !full;
	}

	// the pages' corners follow (lib.rs set_full): the window's in FULL, the card's otherwise
	// search results too: their own buttons (ALL, IMG, VID, PREV, NEXT …) take the sides' place
	let fullShown = $derived(full && mode === 'page');
	$effect(() => {
		api.setFull(fullShown);
		// the side buttons and the tabs go (html.full): the page alone, under it only the paper
		document.documentElement.classList.toggle('full', fullShown);
	});

	function toggleEink() {
		eink = !eink;
		api.setEink(eink);
	}

	// ── popups ──

	let target: Tab | null = $state(null);
	let selectedAction = $state(0);

	type Action = { label: string; run: () => unknown };

	let actions: Action[] = $derived.by(() => {
		const t = target;
		if (!t) return [];
		const done = (fn: () => unknown) => () => {
			popup = 'none';
			fn();
		};
		return [
			{ label: 'Open', run: done(() => activate(t.id)) },
			{ label: 'Copy link', run: done(() => api.copy(t.url)) },
			{ label: t.favorite ? 'Remove from favourites' : 'Add to favourites', run: done(() => toggleFavorite(t.id)) },
			{ label: 'Close', run: done(() => closeTab(t.id)) },
			...(t.favorite ? [{ label: 'Remove', run: done(() => closeTab(t.id, true)) }] : []),
		];
	});

	function openActions(tab: Tab) {
		target = tab;
		selectedAction = 0;
		popup = 'actions';
	}

	function command(id: string) {
		if (id === 'new') newTab();
		else if (id === 'address') editAddress();
		else if (id === 'close') closeTab(active);
		else if (id === 'favo') toggleFavorite(active);
		else if (id === 'next-tab') cycle(1);
		else if (id === 'prev-tab') cycle(-1);
		else if (id === 'back' && active !== null) api.back(active);
		else if (id === 'forward' && active !== null) api.forward(active);
		else if (id === 'reload' && active !== null) api.reload(active);
		else if (id === 'video' && active !== null) api.fillVideo(active);
		else if (id === 'eink') toggleEink();
		else if (id === 'full') toggleFull();
		else if (id === 'info') popup = popup === 'info' ? 'none' : 'info';
	}

	// keys that reach the UI (a page keeps its own; ⌘ shortcuts come from the menu)
	function handleKeydown(e: KeyboardEvent) {
		// ⌥ + arrows walk the tabs, only while the UI has the keys: on a page they stay the page's
		if (e.altKey && popup === 'none' && e.key.startsWith('Arrow')) {
			e.preventDefault();
			if (e.key === 'ArrowDown') cycle(1, false);
			else if (e.key === 'ArrowUp') cycle(-1, false);
			else toColumn(e.key === 'ArrowLeft' ? 'favorites' : 'others');
			return;
		}
		if (popup !== 'none') {
			if (e.key === 'Escape') {
				e.preventDefault();
				popup = 'none';
			} else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && popup === 'actions') {
				e.preventDefault();
				const d = e.key === 'ArrowDown' ? 1 : -1;
				selectedAction = (selectedAction + d + actions.length) % actions.length;
			} else if (e.key === 'Enter') {
				e.preventDefault();
				if (popup === 'actions') actions[selectedAction]?.run();
				else popup = 'none';
			}
			return;
		}
		if (e.target === searchInput) {
			if (e.key === 'Enter') {
				e.preventDefault();
				submit();
			} else if (e.key === 'Escape') {
				e.preventDefault();
				cancelSearch();
			} else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !query) {
				// an empty Search walks the tabs, as ⌥↑ / ⌥↓ do
				e.preventDefault();
				cycle(e.key === 'ArrowDown' ? 1 : -1, false);
			}
		}
	}

	onMount(() => {
		restore();
		const unlisten = [
			ui.listen<TabEvent>('tab', ({ payload: e }) => {
				const tab = tabs.find(t => t.id === e.id);
				if (!tab) return;
				if (e.url) tab.url = e.url;
				if (e.title !== undefined) tab.title = e.title;
				if (e.icon && e.icon !== tab.icon) {
					tab.icon = e.icon;
					delete brokenIcon[tab.id];
				}
				if (e.loading !== undefined) loading[tab.id] = e.loading;
			}),
			ui.listen<string>('open', ({ payload }) => openTab(payload)),
			ui.listen<string>('menu', ({ payload }) => command(payload)),
		];
		// pages that change the address without loading (history.pushState) send no event
		const timer = setInterval(async () => {
			if (!showing || !current) return;
			const tab = current;
			const url = await api.tabUrl(tab.id);
			if (url && url !== tab.url) tab.url = url;
		}, 1000);
		return () => {
			clearInterval(timer);
			unlisten.forEach(p => p.then(fn => fn()));
		};
	});

	const shortcuts = [
		['⌘ N', 'New window (its own tabs)'],
		['⌘ T', 'New tab'],
		['⌘ L', 'Edit address'],
		['⌘ W', 'Close tab'],
		['⌘ D', 'Favourite'],
		['⌘ [ / ⌘ ]', 'Back / forward'],
		['⌘ R', 'Reload'],
		['⌘ F', 'Video fills the page'],
		['⌥ ↑ / ⌥ ↓', 'Previous / next tab'],
		['⌥ ← / ⌥ →', 'Favourites / other tabs'],
		['⌘ ⇧ F', 'Page fills the window'],
		['⌘ E', 'E-ink'],
		['⌘ I', 'Info'],
		['Right click', 'Tab actions'],
	];
</script>

<svelte:window onkeydown={handleKeydown} oncontextmenu={e => {
	if ((e.target as HTMLElement)?.tagName !== 'INPUT') e.preventDefault();
}} />

<WindowControls hidden={fullShown} />

{#snippet icon(tab: Tab)}
	<button
		class="tab"
		class:active={tab.id === active && mode === 'page'}
		class:loading={loading[tab.id]}
		onclick={() => activate(tab.id)}
		oncontextmenu={() => openActions(tab)}
		title={tab.title || host(tab.url)}
	>
		{#if tab.icon && !brokenIcon[tab.id]}
			<img src={tab.icon} alt="" draggable="false" onerror={() => (brokenIcon[tab.id] = true)} />
		{:else}
			<span class="letter">{letter(tab.url)}</span>
		{/if}
	</button>
{/snippet}

<!-- left: new tab, favourites, info -->
<button class="side plain nav-new" onclick={newTab} title="New tab (⌘T)">NEW</button>
<nav class="column left scroll" use:scrollFade>
	<div class="icons">
		{#each favorites as tab (tab.id)}{@render icon(tab)}{/each}
	</div>
</nav>
<button class="side plain nav-info" onclick={() => (popup = 'info')} title="Info (⌘I)">INFO</button>

<!-- right: favourite switch, the other tabs, full -->
<button
	class="side switch nav-favo"
	class:ink-mark-v={current?.favorite}
	onclick={() => toggleFavorite(active)}
	disabled={!current}
	title="Favourite (⌘D)"
>FAVO</button>
<nav class="column right scroll" use:scrollFade>
	<div class="icons">
		{#each others as tab (tab.id)}{@render icon(tab)}{/each}
	</div>
</nav>
<button class="side switch nav-full" class:ink-mark-v={full} onclick={toggleFull} title="Page fills the window (⌘⇧F)">FULL</button>

<!-- a small window: no columns, tabs are walked with ⌥ ↑ / ⌥ ↓ -->
<button class="corner top-right" onclick={newTab} title="New tab (⌘T)">NEW</button>
<button class="corner bottom-left" onclick={() => (popup = 'info')} title="Info (⌘I)">INFO</button>
<button class="corner bottom-right" class:on={full} onclick={toggleFull} title="Page fills the window (⌘⇧F)">FULL</button>

<main>
	<!-- the page lies over this card; it shows as paper while the page is hidden -->
	<div class="card" class:eink class:full={fullShown} class:bare={results && mode === 'page'} class:hidden={mode !== 'page' || !current} bind:this={card}></div>

	{#if mode === 'page' && current}
		<button class="title" class:loading={loading[current.id]} onclick={editAddress} title={current.title || current.url}>
			{results ? searchQuery(current.url) : host(current.url)}
		</button>
		<div class="pager" class:gone={results}>
			<button class="turn" onclick={() => api.back(current!.id)} aria-label="Back" title="Back (⌘[)">←</button>
			<button class="path" onclick={editAddress} title={current.url}>{current.title || path(current.url)}</button>
			<button class="turn" onclick={() => api.forward(current!.id)} aria-label="Forward" title="Forward (⌘])">→</button>
		</div>
	{:else if ready}
		<input
			bind:this={searchInput}
			bind:value={query}
			class="search fade-in"
			type="text"
			placeholder="Search"
			autocomplete="off"
			autocapitalize="off"
		/>
	{/if}
</main>

{#if popup === 'actions' && target}
	<Popup onclose={() => (popup = 'none')}>
		<p class="pop-text">{host(target.url)}</p>
		<div class="pop-divider"></div>
		<div class="menu">
			{#each actions as action, i}
				<button class="menu-item" onclick={() => action.run()} onmouseenter={() => (selectedAction = i)}>
					<span class:ink-mark={i === selectedAction}>{action.label}</span>
				</button>
			{/each}
		</div>
	</Popup>
{:else if popup === 'info'}
	<Popup onclose={() => (popup = 'none')}>
		<p class="pop-heading">RE:SURF</p>
		<div class="pop-divider"></div>
		<p class="pop-text">
			{tabs.length} {tabs.length === 1 ? 'tab' : 'tabs'} · {favorites.length} {favorites.length === 1 ? 'favourite' : 'favourites'}
		</p>
		<div class="pop-divider"></div>
		<div class="shortcuts">
			{#each shortcuts as [key, desc]}
				<span class="key">{key}</span><span class="desc">{desc}</span>
			{/each}
		</div>
		<div class="pop-divider"></div>
		<p class="pop-footer">WebKit · Google Search · no history kept</p>
	</Popup>
{/if}

<style>
	/* ── side buttons ── */
	.nav-new { left: calc(6.25% - 28px); top: calc(6.25% + 8px); width: 42px; padding-top: 0.55em; }
	.nav-info { left: calc(6.25% - 28px); bottom: 6.25%; width: 42px; }
	.nav-favo { right: calc(6.25% - 28px); top: calc(6.25% + 8px); }
	.nav-full { right: calc(6.25% - 28px); bottom: 6.25%; }
	.side:disabled { opacity: 0.3; pointer-events: none; }

	/* FULL: no side buttons, no tabs, no corner buttons; on search results the page's own buttons stand there */
	:global(html.full) .side,
	:global(html.full) .column,
	:global(html.full) .corner { visibility: hidden; }

	/* ── tab icons, centred in each column; a long column scrolls ── */
	.column {
		position: fixed;
		top: calc(6.25% + 160px);
		bottom: calc(6.25% + 160px);
		width: 58px;
		display: flex;
		flex-direction: column;
		overflow-y: auto;
		overflow-x: hidden;
		z-index: 5;
	}

	.column.left { left: calc(6.25% - 36px); }
	.column.right { right: calc(6.25% - 36px); }

	.icons {
		margin: auto 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 22px;
		padding: 12px 0;
	}

	.tab {
		width: 42px;
		height: 42px;
		flex-shrink: 0;
		display: grid;
		place-items: center;
		background: transparent;
		border: 2px solid transparent;
		padding: 0;
		opacity: 0.6;
		cursor: pointer;
		transition: opacity 200ms ease, border-color 200ms ease;
	}

	.tab:hover { opacity: 1; }

	/* the open tab is ringed; a letter drops its own ring so there is only one */
	.tab.active {
		opacity: 1;
		border-color: var(--line);
		border-radius: 50%;
	}

	.tab.active .letter { border-color: transparent; }

	.tab.loading { animation: breathe 1.2s ease-in-out infinite; }

	.tab img {
		width: 24px;
		height: 24px;
		object-fit: contain;
		filter: grayscale(1) contrast(1.1);
		user-select: none;
	}

	/* a site without an icon (or not opened yet): its first letter in a ring */
	.letter {
		width: 26px;
		height: 26px;
		display: grid;
		place-items: center;
		border: 1.5px solid var(--line);
		border-radius: 50%;
		font-family: 'Kurale', serif;
		font-size: 15px;
		line-height: 1;
	}

	/* ── the page ── */
	.card {
		position: fixed;
		top: calc(6.25% + 24px);
		bottom: calc(6.25% + 24px);
		left: calc(6.25% + 80px);
		right: calc(6.25% + 80px);
		border-radius: 22px;
		background: var(--card);
		box-shadow: 0 1px 12px rgba(0, 0, 0, 0.08);
	}

	/* FULL: the page over nearly the whole window, a frame of paper around it */
	.card.full { top: 6px; bottom: 6px; left: 6px; right: 6px; border-radius: 12px; }

	/* in e-ink the page sits on the paper itself */
	.card.eink { background: var(--bg); }

	/* search results: the page is clear (lib.rs), the paper shows through */
	.card.bare { background: transparent; box-shadow: none; }

	.pager.gone { visibility: hidden; }

	/* kept in the layout so the webview always knows where to go */
	.card.hidden { visibility: hidden; }

	/* the site and the page's title sit halfway between the card and the window edge */
	.title,
	.pager {
		position: fixed;
		left: 50%;
		background: transparent;
		border: none;
	}

	.title {
		top: calc(3.125% + 12px);
		transform: translate(-50%, -50%);
		max-width: 60%;
		padding: 0;
		font-family: 'Kurale', serif;
		font-size: 24px;
		line-height: 32px;
		letter-spacing: 0.04em;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		cursor: pointer;
	}

	.title.loading { animation: breathe 1.2s ease-in-out infinite; }

	.pager {
		bottom: calc(3.125% + 12px);
		transform: translate(-50%, 50%);
		display: flex;
		align-items: center;
		gap: 4rem;
		max-width: 70%;
	}

	.path {
		min-width: 0;
		background: transparent;
		border: none;
		padding: 0;
		font-family: 'Kurale', serif;
		font-size: 24px;
		line-height: 32px;
		letter-spacing: 0.04em;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		cursor: pointer;
	}

	.turn {
		flex-shrink: 0;
		background: transparent;
		border: none;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 26px;
		line-height: 1;
		opacity: 0.6;
		cursor: pointer;
		transition: opacity 200ms ease;
	}

	.turn:hover { opacity: 1; }

	@keyframes breathe {
		0%, 100% { opacity: 1; }
		50% { opacity: 0.35; }
	}

	/* ── start page: just Search ── */
	.search {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(640px, calc(100% - 2 * (6.25% + 120px)));
		background: transparent;
		border: none;
		outline: none;
		font-family: 'Kurale', serif;
		font-size: 24px;
		line-height: 32px;
		text-align: center;
		color: var(--text);
	}

	.search::placeholder {
		color: var(--muted);
		opacity: 0.5;
	}

	/* ── a small window: the page takes it all, clear of the window controls ── */
	@media (max-width: 759px), (max-height: 559px) {
		.column { display: none; }

		.card {
			top: 44px;
			bottom: 44px;
			left: 36px;
			right: 36px;
			border-radius: 14px;
		}

		.title {
			top: 22px;
			max-width: calc(100% - 200px);
			font-size: 16px;
			line-height: 24px;
		}

		.pager {
			bottom: 22px;
			gap: 1.5rem;
			max-width: calc(100% - 200px);
		}

		.path {
			font-size: 16px;
			line-height: 24px;
		}

		.turn { font-size: 20px; }

		.search { width: calc(100% - 72px); }
	}

	/* ── popups ── */
	.menu {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 16px;
		padding: 0.3em 0.5em;
	}

	.menu-item {
		background: transparent;
		border: none;
		padding: 0;
		font-family: 'Kurale', serif;
		font-size: 16px;
		line-height: 1.2;
		text-align: left;
		cursor: pointer;
	}

	.shortcuts {
		display: grid;
		grid-template-columns: auto auto;
		gap: 8px 24px;
		font-size: 13px;
	}

	.shortcuts .key {
		font-family: 'Noto Sans JP', sans-serif;
		letter-spacing: 0.1em;
		text-align: right;
		opacity: 0.85;
	}

	.shortcuts .desc {
		font-family: 'Kurale', serif;
		opacity: 0.7;
	}

	.pop-footer {
		font-family: 'Kurale', serif;
		font-size: 13px;
		letter-spacing: 0.15em;
		opacity: 0.55;
	}
</style>
