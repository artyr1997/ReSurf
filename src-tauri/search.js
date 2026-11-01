// Google's results in the ReSurf look: the query, then the results as a quiet list (title, site, a line),
// on the paper, without the ads, the panels and Google's own header. ↑ / ↓ choose one (inked), Enter opens it.
// Google's markup changes often and its class names mean nothing, so the results are found by what they
// are (a link out of Google with a heading in it), and when fewer than three turn up the page is left as
// Google made it. lib.rs puts the brush shapes in for __BRUSH_LEFT__ / __BRUSH_MID__ / __BRUSH_RIGHT__.
(() => {
	if (window.__resurfSearch) return;
	window.__resurfSearch = true;

	const isGoogle = /(^|\.)google\.[a-z.]+$/.test(location.hostname);
	if (!isGoogle || location.pathname !== '/search') return;
	const params = new URLSearchParams(location.search);
	const query = params.get('q') || '';
	if (!query) return;

	// the "Web" filter (udm=14): just the links, no AI answer or panels; images, news… (tbm / udm) are left alone
	if (!params.has('udm') && !params.has('tbm')) {
		params.set('udm', '14');
		location.replace(location.pathname + '?' + params.toString());
		return;
	}
	if (params.get('udm') !== '14') return;

	const svg = (s) => `url("data:image/svg+xml,${encodeURIComponent(s)}")`;
	const noise = svg(
		'<svg xmlns="http://www.w3.org/2000/svg" width="240" height="240"><filter id="n"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 0.5 0 0 0 0 0.5 0 0 0 0 0.5 0 0 0 0.09 0"/></filter><rect width="100%" height="100%" filter="url(#n)"/></svg>'
	);
	const left = svg(`__BRUSH_LEFT__`);
	const mid = svg(`__BRUSH_MID__`);
	const right = svg(`__BRUSH_RIGHT__`);

	const css = `
		@import url('https://fonts.googleapis.com/css2?family=Kurale&family=Noto+Sans+JP:wght@300;400&display=swap');
		html.resurf-hold { visibility: hidden !important; }
		html.resurf-search { --bg: #F4F4F4; --text: #474747; --ink: #4a4a4a; color-scheme: light; }
		@media (prefers-color-scheme: dark) {
			html.resurf-search { --bg: #1d1d1d; --text: #808080; --ink: #767676; color-scheme: dark; }
		}
		html.resurf-search, html.resurf-search body {
			margin: 0 !important; padding: 0 !important; min-height: 100% !important;
			background: var(--bg) ${noise} repeat !important; color: var(--text) !important;
		}
		html.resurf-search body > :not(#resurf-search) { display: none !important; }
		#resurf-search {
			max-width: 680px; margin: 0 auto; padding: 56px 32px 72px;
			font-family: 'Kurale', Georgia, serif; -webkit-font-smoothing: antialiased;
		}
		#resurf-search h1 {
			margin: 0 0 40px; font: 400 24px/32px 'Kurale', Georgia, serif; text-align: center;
		}
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
		#resurf-search a.re-result:hover .re-title { text-decoration: underline; text-underline-offset: 4px; text-decoration-thickness: 1px; }
		/* the chosen one: the ink brushstroke over its title, the letters cut out of it in the paper's colour */
		#resurf-search li.re-on .re-title {
			color: var(--bg); text-decoration: none; background: var(--ink);
			-webkit-mask: ${left} left center / auto 100% no-repeat, ${right} right center / auto 100% no-repeat,
				${mid} 0.65em center / calc(100% - 1.3em) 100% no-repeat;
		}
		#resurf-search nav { display: flex; justify-content: space-between; margin-top: 48px; }
		#resurf-search nav a {
			font: 400 14px/20px 'Noto Sans JP', sans-serif; letter-spacing: 0.6em; color: inherit;
			text-decoration: none; opacity: 0.75;
		}
		#resurf-search nav a:hover { opacity: 1; }
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
	// Google's own redirect (/url?q=…) → the page itself
	const target = (a) => {
		try {
			const u = new URL(a.href);
			if (/(^|\.)google\./.test(u.hostname) && u.pathname === '/url') return u.searchParams.get('q') || u.searchParams.get('url') || '';
		} catch {}
		return a.href;
	};
	const text = (el) => (el?.innerText || '').replace(/\s+/g, ' ').trim();

	function find() {
		const root = document.querySelector('#search, #rso, #main') || document.body;
		const seen = new Set();
		const found = [];
		for (const a of root.querySelectorAll('a[href]')) {
			const href = target(a);
			const heading = a.querySelector('h3, [role="heading"]');
			if (!heading || !isOut(href) || seen.has(href)) continue;
			const title = text(heading);
			if (!title) continue;
			// the result: the biggest block around the link that holds no other result's heading
			let box = a;
			while (box.parentElement && box.parentElement !== root && box.parentElement.querySelectorAll('a h3, a [role="heading"]').length <= 1) {
				box = box.parentElement;
			}
			// its line: the longest piece of text in it that isn't the link
			let line = '';
			for (const el of box.querySelectorAll('div, span')) {
				if (el.contains(a) || a.contains(el) || el.querySelector('div')) continue;
				const t = text(el);
				if (t.length > line.length && t !== title) line = t;
			}
			seen.add(href);
			found.push({ href, title, line });
		}
		return found;
	}

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

	function render(results) {
		const main = document.createElement('main');
		main.id = 'resurf-search';
		const h1 = document.createElement('h1');
		h1.textContent = query;
		const list = document.createElement('ol');
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
			a.append(title, where);
			if (r.line) {
				const p = document.createElement('p');
				p.className = 're-line';
				p.textContent = r.line;
				a.append(p);
			}
			li.append(a);
			list.append(li);
		}
		// pages: ten at a time, counted by Google's start=
		const start = Number(params.get('start')) || 0;
		const page = (n) => {
			const p = new URLSearchParams(params);
			n > 0 ? p.set('start', String(n)) : p.delete('start');
			return location.pathname + '?' + p.toString();
		};
		const nav = document.createElement('nav');
		const prev = document.createElement('a');
		prev.textContent = 'PREV';
		if (start > 0) prev.href = page(Math.max(0, start - 10));
		else prev.style.visibility = 'hidden';
		const next = document.createElement('a');
		next.textContent = 'NEXT';
		next.href = page(start + 10);
		nav.append(prev, next);

		main.append(h1, list, nav);
		document.body.append(main);
		document.documentElement.classList.add('resurf-search');
		document.title = query;

		const items = [...list.children];
		let chosen = -1;
		const choose = (i) => {
			items[chosen]?.classList.remove('re-on');
			chosen = Math.max(0, Math.min(items.length - 1, i));
			items[chosen].classList.add('re-on');
			items[chosen].scrollIntoView({ block: 'nearest' });
		};
		addEventListener('keydown', (e) => {
			if (e.metaKey || e.ctrlKey || e.altKey || /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName)) return;
			if (e.key === 'ArrowDown') choose(chosen + 1);
			else if (e.key === 'ArrowUp') choose(chosen - 1);
			else if (e.key === 'Enter' && chosen >= 0) location.href = items[chosen].querySelector('a').href;
			else return;
			e.preventDefault();
		}, true);
	}

	let done = false;
	function finish() {
		if (done) return;
		done = true;
		const results = find();
		if (results.length >= 3) render(results);
		document.documentElement.classList.remove('resurf-hold');
	}
	if (document.readyState === 'loading') addEventListener('DOMContentLoaded', finish);
	else finish();
	// never a blank page for long, whatever Google sends
	setTimeout(finish, 3000);
})();
