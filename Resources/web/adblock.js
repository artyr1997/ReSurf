// ReSurf's own ad blocker, for the ads the rule list (adblock.json) can't reach: those a site
// serves from its own servers, like YouTube's. Runs in every frame before the page's own scripts,
// in the page's world, so it can take the ads out of the site's data before the site sees them.
(() => {
	if (window.__resurfAds) return;
	window.__resurfAds = true;

	const sites = [{ match: /(^|\.)youtube(-nocookie)?\.com$/, run: youtube }];
	for (const site of sites) if (site.match.test(location.hostname)) site.run();

	function style(css) {
		const add = () => {
			const s = document.createElement('style');
			s.textContent = css;
			(document.head || document.documentElement).appendChild(s);
		};
		document.documentElement ? add() : document.addEventListener('DOMContentLoaded', add);
	}

	// A function swapped for a Proxy still reads as native code, so the page can't tell.
	function wrap(owner, name, after) {
		const original = owner[name];
		if (typeof original !== 'function') return;
		owner[name] = new Proxy(original, {
			apply: (target, self, args) => after(Reflect.apply(target, self, args)),
		});
	}

	function youtube() {
		// 1. The player's ads come in its data: the page's ytInitialPlayerResponse and the answers
		// to /youtubei/v1/player. Without these fields the player has no ads to play.
		const AD_FIELDS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams', 'adBreakParams'];
		const prune = (data, depth = 0) => {
			if (!data || typeof data !== 'object' || depth > 4) return data;
			for (const field of AD_FIELDS) if (field in data) delete data[field];
			// "Ad blockers are not allowed on YouTube"
			const messages = data.auxiliaryUi?.messageRenderers;
			if (messages?.enforcementMessageViewModel) delete messages.enforcementMessageViewModel;
			for (const inner of ['playerResponse', 'response']) prune(data[inner], depth + 1);
			if (Array.isArray(data)) data.forEach((d) => prune(d, depth + 1));
			return data;
		};
		wrap(JSON, 'parse', prune);
		wrap(Response.prototype, 'json', (promise) => promise.then(prune));
		let initial;
		Object.defineProperty(window, 'ytInitialPlayerResponse', {
			configurable: true,
			get: () => initial,
			set: (value) => (initial = prune(value)),
		});

		// 2. Ads in the feed, beside and under the video, banners, and the anti-adblock popup.
		style(`
			#masthead-ad, #player-ads, ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer,
			ytd-rich-item-renderer:has(ytd-ad-slot-renderer), ytd-rich-section-renderer:has(ytd-statement-banner-renderer),
			ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-promoted-sparkles-web-renderer,
			ytd-promoted-video-renderer, ytd-display-ad-renderer, ytd-compact-promoted-video-renderer,
			ytd-search-pyv-renderer, ytd-merch-shelf-renderer, ytd-player-legacy-desktop-watch-ads-renderer,
			ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"],
			.ytp-ad-overlay-container, .ytp-ad-image-overlay, .ytp-featured-product,
			ytd-enforcement-message-view-model, tp-yt-paper-dialog:has(ytd-enforcement-message-view-model),
			ytm-promoted-sparkles-web-renderer, ad-slot-renderer, ytm-companion-ad-renderer
			{ display: none !important; }
		`);

		// 3. If an ad plays all the same (served inside the video, or from a new kind of field):
		// silent, to its end, and Skip pressed. The sound and the speed are given back after it.
		let ad = false;
		let muted = false;
		let rate = 1;
		setInterval(() => {
			const player = document.querySelector('#movie_player, .html5-video-player');
			if (!player) return;
			const video = player.querySelector('video');
			const showing = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
			for (const button of document.querySelectorAll(
				'.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button'
			))
				button.click();
			if (showing && video) {
				if (!ad) [muted, rate] = [video.muted, video.playbackRate];
				ad = true;
				video.muted = true;
				video.playbackRate = 16;
				if (Number.isFinite(video.duration) && video.duration > 0) video.currentTime = video.duration;
			} else if (ad) {
				ad = false;
				if (video) {
					video.muted = muted;
					video.playbackRate = rate;
				}
			}
		}, 250);
	}
})();
