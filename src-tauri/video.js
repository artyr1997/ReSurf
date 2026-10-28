// ⌘F: the page's video fills the whole page (not the screen: the window stays as it is).
// The video is taken with its player, so the controls come along; ⌘F again or Esc puts it back.
// Rust calls window.__resurfVideo() in the tab (see fill_video in lib.rs).
(() => {
	if (window.__resurfVideo) return;

	const MARK = 'data-resurf-video';
	const PATH = 'data-resurf-video-path';
	const INNER = 'data-resurf-video-inner';
	const css = `
		[${MARK}] {
			position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
			max-width: none !important; max-height: none !important; margin: 0 !important;
			z-index: 2147483647 !important; background: #000 !important; transform: none !important;
		}
		/* inside the player, the video and what holds it fill it too (players size them for the old box) */
		[${INNER}] {
			position: absolute !important; inset: 0 !important; width: 100% !important; height: 100% !important;
			max-width: none !important; max-height: none !important; min-height: 0 !important;
			margin: 0 !important; padding: 0 !important; transform: none !important;
		}
		video[${MARK}], video[${INNER}] { object-fit: contain !important; }
		/* what would hold a fixed element inside its parent, or under the page */
		[${PATH}] {
			transform: none !important; filter: none !important; perspective: none !important;
			contain: none !important; will-change: auto !important; backdrop-filter: none !important;
			z-index: 2147483647 !important; overflow: visible !important;
		}
		html:has([${MARK}]), html:has([${MARK}]) body { overflow: hidden !important; }
	`;
	let style = null;

	const area = (el) => {
		const r = el.getBoundingClientRect();
		return r.width > 0 && r.height > 0 ? r.width * r.height : 0;
	};

	// the playing video, else the biggest one; else a big embedded player (YouTube on another site)
	function pick() {
		const videos = [...document.querySelectorAll('video')].filter((v) => area(v) > 0);
		const playing = videos.filter((v) => !v.paused && !v.ended);
		const pool = playing.length ? playing : videos;
		if (pool.length) return pool.sort((a, b) => area(b) - area(a))[0];
		const frames = [...document.querySelectorAll('iframe')].filter(
			(f) => area(f) >= 200 * 150 && /youtube|vimeo|player|video|embed|twitch|dailymotion/i.test(f.src)
		);
		return frames.sort((a, b) => area(b) - area(a))[0] ?? null;
	}

	// a video sits in its player: the outermost box still about its size (that one has the controls)
	function player(el) {
		const own = el.getBoundingClientRect();
		let box = el;
		for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
			const r = p.getBoundingClientRect();
			if (r.width > own.width * 1.15 + 8 || r.height > own.height * 1.15 + 8) break;
			if (r.width >= own.width - 2 && r.height >= own.height - 2) box = p;
		}
		return box;
	}

	function on() {
		const video = pick();
		if (!video) return;
		const box = video.tagName === 'IFRAME' ? video : player(video);
		if (!style) {
			style = document.createElement('style');
			style.textContent = css;
		}
		(document.head || document.documentElement).appendChild(style);
		box.setAttribute(MARK, '');
		for (let p = video; p && p !== box; p = p.parentElement) p.setAttribute(INNER, '');
		for (let p = box.parentElement; p && p !== document.documentElement; p = p.parentElement) p.setAttribute(PATH, '');
		// players lay their video out again when the window changes
		window.dispatchEvent(new Event('resize'));
	}

	function off() {
		for (const el of document.querySelectorAll(`[${MARK}], [${PATH}], [${INNER}]`)) {
			for (const name of [MARK, PATH, INNER]) el.removeAttribute(name);
		}
		style?.remove();
		window.dispatchEvent(new Event('resize'));
	}

	const filling = () => !!document.querySelector(`[${MARK}]`);

	window.__resurfVideo = () => (filling() ? off() : on());

	document.addEventListener(
		'keydown',
		(e) => {
			if (e.key === 'Escape' && filling()) {
				e.preventDefault();
				e.stopImmediatePropagation();
				off();
			}
		},
		true
	);
})();
