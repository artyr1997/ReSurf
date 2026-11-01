// Google's results in the ReSurf look: the results as a quiet list (title, site, a line; ReSurf shows the query above),
// or the pictures as a grid, on the paper, without the ads, the panels and Google's own header. Four
// buttons at the sides switch what is searched: ALL (web pages), IMG, VID, and FCS, the focus search:
// the same query in Marginalia, the small, text web (resurf://localhost/focus, made by lib.rs with the
// results in window.__resurfFocus). ↑ / ↓ choose one (inked), Enter opens it.
// Google's markup changes often and its class names mean nothing, so the results are found by what they
// are (a link out of Google with a heading in it; a picture that points out of Google), and when too few
// turn up the page is left as Google made it. lib.rs puts the brush shapes in for the __BRUSH_…__ marks.
(() => {
	if (window.__resurfSearch) return;
	window.__resurfSearch = true;

	const isGoogle = /(^|\.)google\.[a-z.]+$/.test(location.hostname) && location.pathname === '/search';
	const isFocus = location.protocol === 'resurf:' && location.pathname === '/focus';
	if (!isGoogle && !isFocus) return;
	const params = new URLSearchParams(location.search);
	const query = params.get('q') || '';
	if (!query) return;

	// the "Web" filter (udm=14): just the links, no AI answer or panels; Google's other tabs (tbm) are left alone
	if (isGoogle && !params.has('udm') && !params.has('tbm')) {
		params.set('udm', '14');
		location.replace(location.pathname + '?' + params.toString());
		return;
	}
	const KINDS = { 14: 'all', 2: 'img', 7: 'vid' };
	const kind = isFocus ? 'fcs' : KINDS[params.get('udm')];
	if (!kind) return;

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
		@import url('https://fonts.googleapis.com/css2?family=Kurale&family=Noto+Sans+JP:wght@300;400&display=swap');
		html.resurf-hold { visibility: hidden !important; }
		html.resurf-search {
			--bg: #F4F4F4; --text: #474747; --line: #57585A; --ink: #4a4a4a; color-scheme: light;
			--mark-left: ${left}; --mark-mid: ${mid}; --mark-right: ${right};
		}
		@media (prefers-color-scheme: dark) {
			html.resurf-search {
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
			position: fixed; inset: 0 110px; overflow-y: auto; scrollbar-width: none;
			-webkit-mask-image: linear-gradient(to bottom, transparent, #000 40px, #000 calc(100% - 40px), transparent);
			font-family: 'Kurale', Georgia, serif; -webkit-font-smoothing: antialiased;
		}
		#resurf-search::-webkit-scrollbar { display: none; }
		#resurf-search > div { max-width: 680px; margin: 0 auto; padding: 48px 0 64px; }
		#resurf-search.re-pictures > div { max-width: none; }
		#resurf-search ol { list-style: none; margin: 0; padding: 0; }
		#resurf-search li { margin: 0 0 28px; }
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
		#resurf-search .re-words { display: block; min-width: 0; }
		#resurf-search a.re-result:has(.re-still) { display: flex; gap: 20px; align-items: flex-start; }
		#resurf-search .re-still { flex: none; width: 176px; height: 99px; object-fit: cover; border-radius: 8px; margin-top: 4px; }
		#resurf-search a.re-result:hover .re-title { text-decoration: underline; text-underline-offset: 4px; text-decoration-thickness: 1px; }
		/* the chosen one: the ink brushstroke over its title, the letters cut out of it in the paper's colour;
		   drawn as the Re apps draw it (.ink-mark), so a title on two lines gets a stroke on each */
		#resurf-search li.re-on .re-title {
			color: var(--bg); text-decoration: none;
			background: var(--mark-left) left center / auto 100% no-repeat, var(--mark-right) right center / auto 100% no-repeat,
				var(--mark-mid) 0.65em center / calc(100% - 1.3em) 100% no-repeat;
		}
		/* pictures: rows of the same height, as many as fit */
		#resurf-search .re-grid { display: flex; flex-wrap: wrap; gap: 14px; justify-content: center; margin: 0; padding: 0; list-style: none; }
		#resurf-search .re-grid li { margin: 0; }
		#resurf-search .re-grid a { display: block; outline: none; border-radius: 8px; transition: opacity 200ms ease; }
		#resurf-search .re-grid img { display: block; height: 150px; width: auto; max-width: 320px; object-fit: cover; border-radius: 8px; }
		#resurf-search .re-grid a:hover { opacity: 0.8; }
		#resurf-search .re-grid li.re-on a { box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px var(--ink); }
		/* ALL / IMG / VID / FCS: vertical words at the sides, as the switches in the Re apps (.side.switch) */
		#resurf-kinds a {
			/* border-box, as everything in the Re apps (Google's page has its own idea) */
			box-sizing: border-box; margin: 0;
			position: fixed; z-index: 1; width: 42px; padding: 0.55em 0 0;
			font: 400 20px/32px 'Noto Sans JP', sans-serif; letter-spacing: 0.6em;
			writing-mode: vertical-rl; text-orientation: upright; display: flex; align-items: center;
			color: var(--text); text-decoration: none; opacity: 0.75; transition: opacity 200ms ease;
			-webkit-font-smoothing: antialiased;
		}
		#resurf-kinds a:hover { opacity: 1; }
		#resurf-kinds a.re-all { left: 44px; top: 40px; }
		#resurf-kinds a.re-img { left: 44px; bottom: 40px; }
		#resurf-kinds a.re-vid { right: 44px; top: 40px; }
		#resurf-kinds a.re-fcs { right: 44px; bottom: 40px; }
		#resurf-search .re-none { margin: 40px 0; text-align: center; font-size: 18px; opacity: 0.6; }
		/* PREV / NEXT: boxes halfway down the sides, as the Re apps' (.side.boxed) */
		#resurf-kinds a.re-box {
			top: 50%; transform: translateY(-50%); min-height: 164px; padding: 18px 0 calc(18px - 0.6em);
			justify-content: center; border: 2px solid var(--line); opacity: 1;
			transition: background 200ms ease, color 200ms ease;
		}
		#resurf-kinds a.re-box:hover { background: var(--text); border-color: var(--text); color: var(--bg); }
		#resurf-kinds a.re-box:not([href]) { opacity: 0.3; pointer-events: none; }
		#resurf-kinds a.re-prev { left: 44px; }
		#resurf-kinds a.re-next { right: 44px; }
		/* the one shown: inked with the brushstroke drawn top to bottom */
		#resurf-kinds a.re-on {
			opacity: 1; color: var(--bg); background: var(--ink);
			-webkit-mask: ${top} center top / 100% auto no-repeat, ${bottom} center bottom / 100% auto no-repeat,
				${midV} center 0.65em / 100% calc(100% - 1.3em) no-repeat;
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
	const resultsRoot = () => document.querySelector('#rso') || document.querySelector('#search') || document.querySelector('#main') || document.body;

	function findPages() {
		const root = resultsRoot();
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
				if (el.closest('[aria-hidden="true"]') || getComputedStyle(el).display === 'none') continue;
				const t = text(el);
				if (t.length > line.length && t !== title && !/^https?:\/\//.test(t)) line = t;
			}
			seen.add(href);
			found.push({ href, title, line, still: kind === 'vid' ? still(href, box) : '' });
		}
		return found;
	}

	// a video's picture: YouTube's own from its address, or else the biggest thumbnail Google shows with it
	function still(href, box) {
		try {
			const u = new URL(href);
			const id = /(^|\.)youtube\.com$/.test(u.hostname) ? u.searchParams.get('v') || u.pathname.match(/^\/(?:shorts|embed|live)\/([\w-]{6,})/)?.[1]
				: u.hostname === 'youtu.be' ? u.pathname.slice(1) : null;
			if (id) return `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;
		} catch {}
		let best = '';
		let size = 0;
		for (const img of box.querySelectorAll('img')) {
			const src = img.currentSrc || img.src || '';
			const w = Math.max(img.getBoundingClientRect().width, img.naturalWidth || 0);
			if (/^(data:image\/(jpeg|png|webp)|https:)/.test(src) && w >= 60 && w > size) [best, size] = [src, w];
		}
		return best;
	}

	// pictures: Google's thumbnails (inline data or encrypted-tbn), each with the page it comes from
	function findPictures() {
		const root = resultsRoot();
		const seen = new Set();
		const found = [];
		for (const img of root.querySelectorAll('img')) {
			const src = img.currentSrc || img.src || '';
			if (!/^(data:image\/(jpeg|png|webp|gif)|https:\/\/encrypted-tbn)/.test(src) || seen.has(src)) continue;
			// not the sites' little icons
			if (img.getBoundingClientRect().width < 60 && (img.naturalWidth || 0) < 60) continue;
			const box = img.closest('[data-lpage]');
			let href = box?.getAttribute('data-lpage') || '';
			if (!href) {
				const a = img.closest('a[href]');
				href = a ? target(a) : '';
			}
			if (!isOut(href)) continue;
			seen.add(src);
			found.push({ href, src, title: img.alt || text(box) || '' });
		}
		return found;
	}

	// Marginalia's, as lib.rs got them
	function findFocus() {
		const data = window.__resurfFocus || {};
		return (data.results || []).filter((r) => isOut(r.url)).map((r) => ({ href: r.url, title: r.title || r.url, line: r.description || '' }));
	}

	const find = { img: findPictures, fcs: findFocus }[kind] || findPages;
	// the focus page comes with its results (or none): drawn whatever it holds
	const enough = { img: 6, fcs: 0 }[kind] ?? 3;

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

	// the same search as another kind, from its first page
	function as(other) {
		const q = encodeURIComponent(query);
		if (other === 'fcs') return `resurf://localhost/focus?q=${q}`;
		const udm = { all: '14', img: '2', vid: '7' }[other];
		return isGoogle ? `${location.origin}/search?udm=${udm}&q=${q}` : `https://www.google.com/search?udm=${udm}&q=${q}`;
	}

	function kinds() {
		const box = document.createElement('div');
		box.id = 'resurf-kinds';
		for (const k of ['all', 'img', 'vid', 'fcs']) {
			const a = document.createElement('a');
			a.className = 're-' + k + (k === kind ? ' re-on' : '');
			a.href = as(k);
			a.textContent = k.toUpperCase();
			a.title = { all: 'All', img: 'Images', vid: 'Videos', fcs: 'Focus: the small, text web (Marginalia Search)' }[k];
			box.append(a);
		}
		return box;
	}

	function list(results) {
		const ol = document.createElement('ol');
		for (const r of results) {
			const li = document.createElement('li');
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
			// videos: the picture to the left of the words
			if (r.still) {
				const img = document.createElement('img');
				img.className = 're-still';
				img.src = r.still;
				img.alt = '';
				img.onerror = () => img.remove();
				a.append(img);
			}
			a.append(words);
			li.append(a);
			ol.append(li);
		}
		return ol;
	}

	function grid(results) {
		const ul = document.createElement('ul');
		ul.className = 're-grid';
		for (const r of results) {
			const li = document.createElement('li');
			const a = document.createElement('a');
			a.href = r.href;
			a.title = r.title ? `${r.title} — ${site(r.href).split(' › ')[0]}` : site(r.href);
			const img = document.createElement('img');
			img.src = r.src;
			img.alt = r.title;
			a.append(img);
			li.append(a);
			ul.append(li);
		}
		return ul;
	}

	function render(results) {
		const main = document.createElement('main');
		main.id = 'resurf-search';
		if (kind === 'img') main.className = 're-pictures';
		const items = kind === 'img' ? grid(results) : list(results);
		const column = document.createElement('div');
		column.append(items);
		if (!results.length) {
			const none = document.createElement('p');
			none.className = 're-none';
			none.textContent = window.__resurfFocus?.error || 'Nothing found.';
			column.append(none);
		}

		main.append(column);
		const side = kinds();
		// pages: Google's counted by start= (ten results at a time, or as many pictures as came),
		// Marginalia's by page= (from 1, and it says how many there are)
		let prevAt = null;
		let nextAt = null;
		const at = (key, n, first) => {
			const p = new URLSearchParams(params);
			n > first ? p.set(key, String(n)) : p.delete(key);
			// (not location.origin: a resurf: address has none)
			return location.href.split('?')[0] + '?' + p.toString();
		};
		if (kind === 'fcs') {
			const page = Number(params.get('page')) || 1;
			const pages = Number(window.__resurfFocus?.pages) || 0;
			if (page > 1) prevAt = at('page', page - 1, 1);
			if (page < pages) nextAt = at('page', page + 1, 1);
		} else {
			const step = kind === 'img' ? Math.max(10, results.length) : 10;
			const start = Number(params.get('start')) || 0;
			if (start > 0) prevAt = at('start', Math.max(0, start - step), 0);
			nextAt = at('start', start + step, 0);
		}
		const prev = document.createElement('a');
		prev.className = 're-box re-prev';
		prev.textContent = 'PREV';
		prev.title = 'Previous page';
		if (prevAt) prev.href = prevAt;
		const next = document.createElement('a');
		next.className = 're-box re-next';
		next.textContent = 'NEXT';
		next.title = 'Next page';
		if (nextAt) next.href = nextAt;
		side.append(prev, next);
		document.body.append(main, side);
		// Google's scripts may redraw the body later: ours stays
		new MutationObserver(() => {
			if (!main.isConnected) document.body.append(main);
			if (!side.isConnected) document.body.append(side);
		}).observe(document.documentElement, { childList: true, subtree: true });
		document.documentElement.classList.add('resurf-search');
		document.title = query;

		const all = [...items.children];
		let chosen = -1;
		const choose = (i) => {
			all[chosen]?.classList.remove('re-on');
			chosen = Math.max(0, Math.min(all.length - 1, i));
			all[chosen].classList.add('re-on');
			all[chosen].scrollIntoView({ block: 'nearest' });
		};
		addEventListener('keydown', (e) => {
			if (e.metaKey || e.ctrlKey || e.altKey || /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName)) return;
			const sideways = kind === 'img';
			if (e.key === 'ArrowDown' || (sideways && e.key === 'ArrowRight')) choose(chosen + 1);
			else if (e.key === 'ArrowUp' || (sideways && e.key === 'ArrowLeft')) choose(chosen - 1);
			else if (e.key === 'Enter' && chosen >= 0) location.href = all[chosen].querySelector('a').href;
			else return;
			e.preventDefault();
		}, true);
	}

	// Google draws its results with scripts, some after the page has loaded: look each time the page
	// changes, and draw ours once there are enough and no new ones for a moment
	let done = false;
	let count = 0;
	let settle = 0;
	function finish() {
		if (done) return;
		done = true;
		watch.disconnect();
		const results = find();
		if (results.length >= enough) render(results);
		document.documentElement.classList.remove('resurf-hold');
	}
	function look() {
		if (done || !document.body) return;
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
	addEventListener('DOMContentLoaded', kind === 'fcs' ? finish : look);
	addEventListener('load', () => setTimeout(look, 100));
	// never a blank page for long, whatever Google sends
	setTimeout(finish, 4000);
})();
