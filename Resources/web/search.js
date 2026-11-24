// Google's results in the ReSurf look: a quiet list (title, site, a line; ReSurf shows the query above), on the
// paper, without the ads, the panels and Google's own header. ↑ / ↓ choose one, Enter opens it, ← / → turn the
// page. Google's markup changes often and its class names mean nothing, so the results are found by what they
// are (a link out of Google with a heading in it), and when too few turn up the page is left as Google made it.
(() => {
	if (window.__resurfSearch) return;
	window.__resurfSearch = true;

	const isGoogle = /(^|\.)google\.[a-z.]+$/.test(location.hostname) && location.pathname === '/search';
	if (!isGoogle) return;
	const params = new URLSearchParams(location.search);
	const query = params.get('q') || '';
	if (!query) return;

	// the "Web" filter (udm=14): just the links, no AI answer or panels; Google's other tabs (tbm) are left alone
	if (isGoogle && !params.has('udm') && !params.has('tbm')) {
		params.set('udm', '14');
		location.replace(location.pathname + '?' + params.toString());
		return;
	}
	// the web's pages only (Google's pictures and videos are left as Google made them)
	if (params.get('udm') !== '14') return;
	const kind = 'all';

	const svg = (s) => `url("data:image/svg+xml,${encodeURIComponent(s)}")`;
	const left = svg(`__BRUSH_LEFT__`);
	const mid = svg(`__BRUSH_MID__`);
	const right = svg(`__BRUSH_RIGHT__`);
	const darkLeft = svg(`__DARK_LEFT__`);
	const darkMid = svg(`__DARK_MID__`);
	const darkRight = svg(`__DARK_RIGHT__`);
	const top = svg(`__BRUSH_TOP__`);
	const midV = svg(`__BRUSH_MID_V__`);
	const bottom = svg(`__BRUSH_BOTTOM__`);

	const css = `
		@import url('https://fonts.googleapis.com/css2?family=Kurale&family=Noto+Sans+JP:wght@300;400&family=M+PLUS+1p:wght@300;400&display=swap');
		/* held while the results are found: Google's page hidden, and see-through too, as some of its bits
		   (the ⋮ menus) make themselves visible again inside a hidden part; opacity can't be undone from inside.
		   The buttons at the sides stay, so they don't blink away while another kind or page loads. */
		html.resurf-hold, html.resurf-hold body { background: transparent !important; }
		html.resurf-hold body > :not(#resurf-kinds) { visibility: hidden !important; opacity: 0 !important; }
		html.resurf-search, html.resurf-hold {
			--bg: #F4F4F4; --text: #474747; --line: #57585A; --ink: #4a4a4a; color-scheme: light;
			--mark-left: ${left}; --mark-mid: ${mid}; --mark-right: ${right};
		}
		@media (prefers-color-scheme: dark) {
			html.resurf-search, html.resurf-hold {
				--bg: #1d1d1d; --text: #808080; --line: #747474; --ink: #767676; color-scheme: dark;
				--mark-left: ${darkLeft}; --mark-mid: ${darkMid}; --mark-right: ${darkRight};
			}
		}
		/* clear: the page lies on ReSurf's own paper (no card around it, see App.svelte) */
		html.resurf-search, html.resurf-search body {
			margin: 0 !important; padding: 0 !important; height: 100% !important; overflow: hidden !important;
			background: transparent !important; color: var(--text) !important;
		}
		html.resurf-search body > :not(#resurf-search):not(#resurf-kinds) { display: none !important; }
		/* the list scrolls in a box that fades out at its top and bottom, as the lists in the Re apps do */
		#resurf-search {
			position: fixed; inset: 0 24px; overflow-y: auto; scrollbar-width: none;
			-webkit-mask-image: linear-gradient(to bottom, transparent, #000 40px, #000 calc(100% - 40px), transparent);
			font-family: 'Kurale', Georgia, serif; -webkit-font-smoothing: antialiased;
		}
		#resurf-search::-webkit-scrollbar { display: none; }
		/* room at the sides for the chosen title's brushstroke, which reaches past its letters */
		#resurf-search > div { max-width: 1040px; margin: 0 auto; padding: 48px 16px 64px; }
		#resurf-search ol { list-style: none; margin: 0; padding: 0; }
		#resurf-search li { margin: 0 0 28px; }
		/* the results come in one after another, each rising a little as it shows (as on getrespace.app) */
		@keyframes re-rise { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
		#resurf-search li { animation: re-rise 0.8s ease both; animation-delay: calc(var(--i, 0) * 0.26s); }
		@media (prefers-reduced-motion: reduce) { #resurf-search li { animation: none; } }
		#resurf-search a.re-result { display: block; color: inherit; text-decoration: none; outline: none; }
		#resurf-search .re-title {
			font-size: 20px; line-height: 30px; padding: 0.15em 0.45em; margin: -0.15em -0.45em;
			-webkit-box-decoration-break: clone; box-decoration-break: clone;
		}
		#resurf-search .re-site {
			display: block; margin-top: 4px; font: 300 12px/18px 'Noto Sans JP', sans-serif;
			letter-spacing: 0.08em; opacity: 0.6; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
		}
		#resurf-search .re-line { margin: 6px 0 0; font-size: 15px; line-height: 23px; opacity: 0.8; }
		#resurf-search a.re-result:hover .re-title { text-decoration: underline; text-underline-offset: 4px; text-decoration-thickness: 1px; }
		/* the chosen one: the ink brushstroke over its title, the letters cut out of it in the paper's colour;
		   drawn as the Re apps draw it (.ink-mark), so a title on two lines gets a stroke on each */
		#resurf-search li.re-on .re-title {
			color: var(--bg); text-decoration: none;
			background: var(--mark-left) left center / auto 100% no-repeat, var(--mark-right) right center / auto 100% no-repeat,
				var(--mark-mid) 0.65em center / calc(100% - 1.3em) 100% no-repeat;
		}
		#resurf-search .re-more { margin: 8px 0 40px; text-align: center; font-size: 18px; letter-spacing: 0.3em; opacity: 0.5; }
		#resurf-search .re-none { margin: 40px 0; text-align: center; font-size: 18px; opacity: 0.6; }
		html.resurf-full #resurf-search { top: calc(3.125vh + 30px); left: calc(6.25vw + 40px); right: calc(6.25vw + 40px); }
		/* a small window (ReSurf's, less its margins): closer to the edges */
		@media (max-width: 687px), (max-height: 471px) {
			#resurf-kinds { display: none; }
			#resurf-search { inset: 0 16px; }
		}
		/* glass (html.resurf-glass, from lib.rs): written on it as ReSurf's own page is, in the desk's white
		   ink and M PLUS 1p; no brush: the chosen title underlined */
		html.resurf-glass.resurf-search, html.resurf-glass.resurf-hold {
			--bg: #1f2023; --text: rgba(255, 255, 255, 0.8); --line: rgba(255, 255, 255, 0.5);
			--ink: rgba(255, 255, 255, 0.8); color-scheme: dark;
		}
		html.resurf-glass #resurf-search, html.resurf-glass #resurf-search .re-site { font-family: 'M PLUS 1p', sans-serif; }
		html.resurf-glass #resurf-search li.re-on .re-title {
			background: none; color: var(--text); text-decoration: underline;
			text-decoration-thickness: 1.5px; text-underline-offset: 0.3em;
		}
	`;
	const style = document.createElement('style');
	style.textContent = css;
	document.documentElement.appendChild(style);
	document.documentElement.classList.add('resurf-hold');

	const isOut = (href) => {
		try {
			const u = new URL(href);
			return /^https?:$/.test(u.protocol) && !/(^|\.)google\.[a-z.]+$/.test(u.hostname) && !/(^|\.)(googleusercontent|gstatic)\.com$/.test(u.hostname);
		} catch {
			return false;
		}
	};
	// Google's own redirects (/url?q=…, /imgres?imgrefurl=…) → the page itself
	const target = (a) => {
		try {
			const u = new URL(a.href);
			if (/(^|\.)google\./.test(u.hostname)) {
				if (u.pathname === '/url') return u.searchParams.get('q') || u.searchParams.get('url') || '';
				if (u.pathname === '/imgres') return u.searchParams.get('imgrefurl') || '';
			}
		} catch {}
		return a.href;
	};
	// textContent: innerText is empty while the page is held hidden
	const text = (el) => (el?.textContent || '').replace(/\s+/g, ' ').trim();
	const resultsRoot = (doc = document) => doc.querySelector('#rso') || doc.querySelector('#search') || doc.querySelector('#main') || doc.body;

	/** the results in a page: this one, or one fetched (the next ten, as the list scrolls) */
	function findPages(doc = document) {
		const root = resultsRoot(doc);
		const heads = [...root.querySelectorAll('h3, [role="heading"][aria-level="3"]')];
		const seen = new Set();
		const found = [];
		for (const heading of heads) {
			const title = text(heading);
			// its link: the one around it, or else the first one out of Google in the block it sits in
			let a = heading.closest('a[href]');
			for (let up = heading.parentElement; !a && up && up !== root; up = up.parentElement) {
				a = [...up.querySelectorAll('a[href]')].find((l) => isOut(target(l))) || null;
			}
			if (!a || !title) continue;
			const href = target(a);
			if (!isOut(href) || seen.has(href)) continue;
			// the result: the biggest block around it that holds no other result's heading
			let box = a.contains(heading) ? a : heading;
			while (box.parentElement && box.parentElement !== root && heads.filter((h) => box.parentElement.contains(h)).length <= 1) {
				box = box.parentElement;
			}
			// its line: the longest piece of text in it that isn't the link or the heading
			let line = '';
			for (const el of box.querySelectorAll('div, span')) {
				if (el.contains(heading) || a.contains(el) || heading.contains(el) || el.querySelector('div, style, script')) continue;
				if (el.closest('[aria-hidden="true"]')) continue;
				try {
					if ((doc.defaultView || window).getComputedStyle(el).display === 'none') continue;
				} catch {}
				const t = text(el);
				if (t.length > line.length && t !== title && !/^https?:\/\//.test(t)) line = t;
			}
			seen.add(href);
			found.push({ href, title, line });
		}
		return found;
	}


	// pictures: Google's thumbnails (inline data or encrypted-tbn), each with the page it comes from

	// Marginalia's, as lib.rs got them

	const find = findPages;
	const enough = 3;

	function site(href) {
		const u = new URL(href);
		const parts = u.pathname.split('/').filter(Boolean).map((p) => {
			try {
				return decodeURIComponent(p);
			} catch {
				return p;
			}
		});
		return [u.hostname.replace(/^www\./, ''), ...parts].join(' › ');
	}

	/** no buttons at the sides: an empty place for them (the page lays itself out the same) */
	function kinds() {
		const box = document.createElement('div');
		box.id = 'resurf-kinds';
		return box;
	}
	function list(results) {
		const ol = document.createElement('ol');
		for (const [i, r] of results.entries()) {
			const li = document.createElement('li');
			// the first ones one after another, the rest (out of sight below) with the last of them
			li.style.setProperty('--i', String(Math.min(i, 8)));
			const a = document.createElement('a');
			a.className = 're-result';
			a.href = r.href;
			const title = document.createElement('span');
			title.className = 're-title';
			title.textContent = r.title;
			const where = document.createElement('span');
			where.className = 're-site';
			where.textContent = site(r.href);
			const words = document.createElement('span');
			words.className = 're-words';
			words.append(title, where);
			if (r.line) {
				const p = document.createElement('p');
				p.className = 're-line';
				p.textContent = r.line;
				words.append(p);
			}
			a.append(words);
			li.append(a);
			ol.append(li);
		}
		return ol;
	}


	function render(results) {
		const main = document.createElement('main');
		main.id = 'resurf-search';
		const items = list(results);
		const column = document.createElement('div');
		column.append(items);
		if (!results.length) {
			const none = document.createElement('p');
			none.className = 're-none';
			none.textContent = 'Nothing found.';
			column.append(none);
		}

		main.append(column);
		const { side, prevAt, nextAt } = sides(results.length);
		// the early buttons give way to these (in the same moment, nothing blinks)
		early?.remove();
		early = null;
		document.body.append(main, side);
		// Google's scripts may redraw the body later: ours stays
		new MutationObserver(() => {
			if (!main.isConnected) document.body.append(main);
			if (!side.isConnected) document.body.append(side);
		}).observe(document.documentElement, { childList: true, subtree: true });
		finishRender(main, items, prevAt, nextAt);
		endless(main, items, results);
	}

	/** Google's page at `url`, opened out of sight (an iframe of the same site: Google draws its results with
	 * its scripts, so a page only fetched has none), its results read once they stop coming; then it goes.
	 * Sandboxed: it can't take the tab away. */
	function readPage(url) {
		return new Promise((resolve) => {
			const f = document.createElement('iframe');
			f.setAttribute('sandbox', 'allow-scripts allow-same-origin');
			f.setAttribute('aria-hidden', 'true');
			f.tabIndex = -1;
			f.style.cssText = 'position:fixed;left:-10000px;top:0;width:1000px;height:2400px;border:0;visibility:hidden;pointer-events:none';
			f.src = url;
			const begun = Date.now();
			let last = -1;
			let still = 0;
			const look = () => {
				let found = [];
				try {
					if (f.contentDocument?.body) found = findPages(f.contentDocument);
				} catch {}
				still = found.length >= enough && found.length === last ? still + 1 : 0;
				last = found.length;
				if (still >= 2 || Date.now() - begun > 8000) {
					f.remove();
					return resolve(found);
				}
				setTimeout(look, 250);
			};
			document.documentElement.append(f);
			setTimeout(look, 500);
		});
	}

	/** Scrolled near the list's end, the next ten come in under it (Google's next page, read as this one
	 * was, the ones already shown left out); until a few pages in a row bring nothing new. */
	function endless(main, items, results) {
		const shown = new Set(results.map((r) => r.href));
		let next = (Number(params.get('start')) || 0) + 10;
		let loading = false;
		let ended = !results.length;
		let empty = 0;
		const more = document.createElement('p');
		more.className = 're-more';
		more.textContent = '⋯';
		more.hidden = true;
		items.after(more);
		const near = () => main.scrollTop + main.clientHeight > main.scrollHeight - 900;
		// the next page read ahead, while this one is looked at: there when the list is scrolled to its end
		const ahead = () => {
			const p = new URLSearchParams(params);
			p.set('start', String(next));
			next += 10;
			return readPage(location.href.split('?')[0] + '?' + p.toString());
		};
		let coming = ended ? null : ahead();
		async function load() {
			if (loading || ended || !coming || !near()) return;
			loading = true;
			more.hidden = false;
			try {
				const found = (await coming).filter((r) => !shown.has(r.href));
				empty = found.length ? 0 : empty + 1;
				if (empty >= 2 || next > 400) ended = true;
				coming = ended ? null : ahead();
				found.forEach((r) => shown.add(r.href));
				// they rise one after another, as the first ones did
				const ol = list(found);
				[...ol.children].forEach((li, k) => {
					li.style.setProperty('--i', String(Math.min(k, 8) * 0.4));
					items.append(li);
				});
			} catch {
				ended = true;
			}
			loading = false;
			more.hidden = true;
			// a list still too short to scroll: the next ten too
			setTimeout(load, 60);
		}
		main.addEventListener('scroll', load, { passive: true });
		// and now and then besides (a scroll the page wasn't told of: the window out of sight, a key held)
		const every = setInterval(() => (main.isConnected && !ended ? load() : ended && clearInterval(every)), 700);
		setTimeout(load, 60);
	}

	/** The buttons at the sides: the kinds; and where the pages before and after are (← / →). Pages: Google's counted by start= (ten results
	 * at a time, or as many pictures as came), Marginalia's by page= (from 1, and it says how many there are). */
	function sides(found) {
		const side = kinds();
		let prevAt = null;
		let nextAt = null;
		const at = (key, n, first) => {
			const p = new URLSearchParams(params);
			n > first ? p.set(key, String(n)) : p.delete(key);
			// (not location.origin: a resurf: address has none)
			return location.href.split('?')[0] + '?' + p.toString();
		};
		const start = Number(params.get('start')) || 0;
		if (start > 0) prevAt = at('start', Math.max(0, start - 10), 0);
		nextAt = at('start', start + 10, 0);
		// the pages turn with ← / → (no buttons)
		return { side, prevAt, nextAt };
	}

	function finishRender(main, items, prevAt, nextAt) {
		document.documentElement.classList.add('resurf-search');
		document.title = query;
		// Google puts the cursor in its search box, now hidden: out of it, so the keys reach the page
		if (document.activeElement && document.activeElement !== document.body && !main.contains(document.activeElement)) {
			document.activeElement.blur();
		}

		// (the list grows as it scrolls: its items counted each time)
		let all = [...items.children];
		let chosen = -1;
		const choose = (i) => {
			all = [...items.children];
			all[chosen]?.classList.remove('re-on');
			chosen = Math.max(0, Math.min(all.length - 1, i));
			all[chosen].classList.add('re-on');
			all[chosen].scrollIntoView({ block: 'nearest' });
		};
		addEventListener('keydown', (e) => {
			// Google's own (hidden) search box may hold the focus: only a field of ours would keep the keys
			if (e.metaKey || e.ctrlKey || e.altKey) return;
			const field = document.activeElement;
			if (/^(INPUT|TEXTAREA)$/.test(field?.tagName) && main.contains(field)) return;
			// ↑ / ↓ a result, ← / → a page
			if (e.key === 'ArrowDown') choose(chosen + 1);
			else if (e.key === 'ArrowUp') choose(chosen - 1);
			else if (e.key === 'Enter' && chosen >= 0) location.href = all[chosen].querySelector('a').href;
			else if (e.key === 'ArrowLeft' && prevAt) location.href = prevAt;
			else if (e.key === 'ArrowRight' && nextAt) location.href = nextAt;
			else return;
			e.preventDefault();
			// and not Google's: it would put them into its hidden search box
			e.stopImmediatePropagation();
		}, true);
	}

	// Google draws its results with scripts, some after the page has loaded: look each time the page
	// changes, and draw ours once there are enough and no new ones for a moment
	let done = false;
	let count = 0;
	// the buttons at the sides from the start, while the results are still coming
	let early = null;
	function showEarly() {
		if (early || done || !document.body) return;
		early = sides(0).side;
		document.body.append(early);
	}
	let settle = 0;
	function finish() {
		if (done) return;
		done = true;
		watch.disconnect();
		const results = find();
		if (results.length >= enough) render(results);
		// Google's own page after all: no buttons of ours
		early?.remove();
		early = null;
		document.documentElement.classList.remove('resurf-hold');
	}
	function look() {
		if (done || !document.body) return;
		showEarly();
		const n = find().length;
		if (n !== count) {
			count = n;
			clearTimeout(settle);
			if (n >= enough) settle = setTimeout(finish, 300);
		}
	}
	let queued = false;
	const watch = new MutationObserver(() => {
		if (queued) return;
		queued = true;
		setTimeout(() => ((queued = false), look()), 50);
	});
	watch.observe(document.documentElement, { childList: true, subtree: true });
	// the focus page has all it holds as soon as it is read
	addEventListener('DOMContentLoaded', look);
	addEventListener('load', () => setTimeout(look, 100));
	// never a blank page for long, whatever Google sends
	setTimeout(finish, 4000);
})();
