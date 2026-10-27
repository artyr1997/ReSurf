<script lang="ts">
	// The browser. Favourites run down the left edge, the other open tabs down the
	// right one. The page sits in the card in the middle: it is a native webview
	// that Rust lays over the card (show_tab), so whenever the UI needs that space
	// (Search, popups) the webview is hidden and the card is plain paper.
	import { onMount, tick, untrack } from 'svelte';
	import { listen } from '@tauri-apps/api/event';
	import WindowControls from './lib/WindowControls.svelte';
	import Popup from './lib/Popup.svelte';
	import { scrollFade } from './lib/scrollFade';
	import { api, toUrl, host, path, letter, type Tab, type Saved, type Bounds } from './lib/web';

	type Mode = 'page' | 'search';
	type PopupKind = 'none' | 'actions' | 'info';
	type TabEvent = { id: number; url?: string; title?: string; loading?: boolean; icon?: string };

	let tabs: Tab[] = $state([]);
	let active: number | null = $state(null);
	let eink = $state(false);
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

	$effect(() => {
		const b = bounds;
		const tab = current;
		if (showing && tab && b) {
			// the address only matters the first time, when the webview is created
			api.showTab(tab.id, untrack(() => tab.url), b);
		} else {
			api.hideTabs().then(() => {
				if (mode === 'search') searchInput?.focus();
			});
		}
	});

	// ── saving: tabs, favourites and e-ink survive a restart ──

	let saveTimer: ReturnType<typeof setTimeout> | null = null;
	$effect(() => {
		const json = JSON.stringify({ tabs, active, eink, nextId } satisfies Saved);
		if (!ready) return;
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(() => api.saveState(json), 300);
	});

	async function restore() {
		const text = await api.loadState().catch(() => null);
		if (text) {
			try {
				const saved = JSON.parse(text) as Saved;
				tabs = saved.tabs ?? [];
				nextId = saved.nextId ?? tabs.reduce((m, t) => Math.max(m, t.id + 1), 1);
				eink = !!saved.eink;
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

	function activate(id: number) {
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

	function cycle(delta: number) {
		const order = [...favorites, ...others];
		if (!order.length) return;
		const at = order.findIndex(t => t.id === active);
		const next = at < 0 ? (delta > 0 ? 0 : order.length - 1) : (at + delta + order.length) % order.length;
		activate(order[next].id);
	}

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
		else if (id === 'eink') toggleEink();
		else if (id === 'info') popup = popup === 'info' ? 'none' : 'info';
	}

	// keys that reach the UI (a page keeps its own; ⌘ shortcuts come from the menu)
	function handleKeydown(e: KeyboardEvent) {
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
			}
		}
	}

	onMount(() => {
		restore();
		const unlisten = [
			listen<TabEvent>('tab', ({ payload: e }) => {
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
			listen<string>('open', ({ payload }) => openTab(payload)),
			listen<string>('menu', ({ payload }) => command(payload)),
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
		['⌘ T', 'New tab'],
		['⌘ L', 'Edit address'],
		['⌘ W', 'Close tab'],
		['⌘ D', 'Favourite'],
		['⌘ [ / ⌘ ]', 'Back / forward'],
		['⌘ R', 'Reload'],
		['⌃ Tab', 'Next tab'],
		['⌘ E', 'E-ink'],
		['⌘ I', 'Info'],
		['Right click', 'Tab actions'],
	];
</script>

<svelte:window onkeydown={handleKeydown} oncontextmenu={e => {
	if ((e.target as HTMLElement)?.tagName !== 'INPUT') e.preventDefault();
}} />

<WindowControls />

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

<!-- right: favourite switch, the other tabs, e-ink -->
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
<button class="side switch nav-eink" class:ink-mark-v={eink} onclick={toggleEink} title="E-ink (⌘E)">EINK</button>

<main>
	<!-- the page lies over this card; it shows as paper while the page is hidden -->
	<div class="card" class:hidden={mode !== 'page' || !current} bind:this={card}></div>

	{#if mode === 'page' && current}
		<button class="title" class:loading={loading[current.id]} onclick={editAddress} title={current.title || current.url}>
			{host(current.url)}
		</button>
		<div class="pager">
			<button class="turn" onclick={() => api.back(current!.id)} aria-label="Back" title="Back (⌘[)">←</button>
			<button class="path" onclick={editAddress} title={current.url}>{path(current.url)}</button>
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
		<p class="pop-footer">WebKit · DuckDuckGo · no history kept</p>
	</Popup>
{/if}

<style>
	/* ── side buttons ── */
	.nav-new { left: calc(6.25% - 28px); top: calc(6.25% + 8px); width: 42px; }
	.nav-info { left: calc(6.25% - 28px); bottom: 6.25%; width: 42px; }
	.nav-favo { right: calc(6.25% - 28px); top: calc(6.25% + 8px); }
	.nav-eink { right: calc(6.25% - 28px); bottom: 6.25%; }
	.side:disabled { opacity: 0.3; pointer-events: none; }

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
		padding: 8px 0;
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
		cursor: url('/ink/hand.svg'), pointer;
		transition: opacity 200ms ease, border-color 200ms ease;
	}

	.tab:hover { opacity: 1; }

	/* the open tab gets the box of the boxed buttons */
	.tab.active {
		opacity: 1;
		border-color: var(--line);
	}

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
		background: #fff;
		box-shadow: 0 1px 12px rgba(0, 0, 0, 0.08);
	}

	/* kept in the layout so the webview always knows where to go */
	.card.hidden { visibility: hidden; }

	/* the title and the path sit halfway between the card and the window edge */
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
		cursor: url('/ink/hand.svg'), pointer;
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
		cursor: url('/ink/hand.svg'), pointer;
	}

	.turn {
		flex-shrink: 0;
		background: transparent;
		border: none;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 26px;
		line-height: 1;
		opacity: 0.6;
		cursor: url('/ink/hand.svg'), pointer;
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
		cursor: url('/ink/hand.svg'), pointer;
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
