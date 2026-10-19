/**
 * Google / YouTube "precision strike" — SERP cards, YT results, forbidden queries.
 * Loaded before content.js; expects global `sixvpnPrecision` namespace.
 */
(() => {
  const P = (globalThis.sixvpnPrecision = globalThis.sixvpnPrecision || {});
  if (P.__ffPrecisionStarted) return;
  P.__ffPrecisionStarted = true;

  P.hideNode = (node) => {
    if (!node.hasAttribute('data-sixvpn-display-before')) {
      node.setAttribute('data-sixvpn-display-before', JSON.stringify([
        node.style.getPropertyValue('display'), node.style.getPropertyPriority('display'),
      ]));
    }
    if (node.style.getPropertyValue('display') !== 'none' || node.style.getPropertyPriority('display') !== 'important') {
      node.style.setProperty('display', 'none', 'important');
    }
  };

  P.lockPage = () => {
    const root = document.documentElement;
    if (!root.hasAttribute('data-sixvpn-overflow-before')) {
      root.setAttribute('data-sixvpn-overflow-before', root.style.overflow || '');
    }
    root.style.overflow = 'hidden';
  };

  P.restorePage = () => {
    for (const node of document.querySelectorAll('[data-sixvpn-display-before]')) {
      try {
        const [value, priority] = JSON.parse(node.getAttribute('data-sixvpn-display-before'));
        if (node.style.getPropertyValue('display') === 'none' &&
            node.style.getPropertyPriority('display') === 'important') {
          if (value) node.style.setProperty('display', value, priority);
          else node.style.removeProperty('display');
        }
      } catch (_) {}
      for (const name of [
        'data-sixvpn-display-before', 'data-sixvpn-blocked', 'data-sixvpn-yt-guide-checked',
      ]) node.removeAttribute(name);
    }
    for (const id of ['sixvpn-block-overlay', 'sixvpn-search-block-overlay', 'sixvpn-fg-quota-overlay']) {
      document.getElementById(id)?.remove();
    }
    const root = document.documentElement;
    if (root.hasAttribute('data-sixvpn-overflow-before')) {
      if (root.style.overflow === 'hidden') root.style.overflow = root.getAttribute('data-sixvpn-overflow-before');
      root.removeAttribute('data-sixvpn-overflow-before');
    }
    root.removeAttribute('data-sixvpn-hide-img');
    root.removeAttribute('data-sixvpn-yt-pending');
  };

  P.normList = (list) =>
    (list || [])
      .map((s) => String(s).trim().toLowerCase())
      .filter(Boolean);

  P.normDomain = (host) =>
    String(host || "")
      .trim()
      .toLowerCase()
      .replace(/^www\./, "");

  P.matchesBlockedDomain = (text, domains) => {
    if (!domains.length) return false;
    const t = String(text || "").toLowerCase();
    for (const d of domains) {
      if (d && t.includes(d)) return true;
    }
    return false;
  };

  /** Channel/video lines from the app — not bare words like "music". */
  P.extractHandleFromKeyword = (k) => {
    const s = String(k || "").trim().toLowerCase();
    let m = s.match(/youtube\.com\/@([^/?#\s]+)/);
    if (m) return decodeURIComponent(m[1]);
    m = s.match(/youtube\.com\/c\/([^/?#\s]+)/);
    if (m) return decodeURIComponent(m[1]);
    if (s.startsWith("@") && !s.includes("/")) return s.slice(1);
    if (s.startsWith("/@")) return s.slice(2).split("/")[0];
    m = s.match(/youtube\.com\/([^/?#\s@]+)/);
    if (m) {
      const slug = decodeURIComponent(m[1]);
      const reserved = new Set([
        "watch",
        "shorts",
        "feed",
        "results",
        "playlist",
        "gaming",
        "premium",
        "account",
        "channel",
        "c",
        "user",
        "post",
        "live",
      ]);
      if (slug && !reserved.has(slug)) return slug;
    }
    if (s.startsWith("/") && s.length > 2 && !s.includes("*")) {
      const slug = s.slice(1).split("/")[0];
      if (slug && !slug.startsWith("@")) return slug;
    }
    return "";
  };

  P.decodeSegment = (s) => {
    try {
      return decodeURIComponent(String(s || ""));
    } catch (_) {
      return String(s || "");
    }
  };

  /** Decoded + percent-encoded variants for Unicode handles (e.g. 뷰티풀너드). */
  P.handleUrlVariants = (handle) => {
    const raw = String(handle || "").trim().toLowerCase();
    if (!raw) return [];
    const out = new Set([raw]);
    try {
      const dec = P.decodeSegment(raw);
      if (dec) out.add(dec.toLowerCase());
    } catch (_) {}
    try {
      const enc = encodeURIComponent(raw).toLowerCase();
      if (enc) out.add(enc);
    } catch (_) {}
    if (raw !== P.decodeSegment(raw)) {
      try {
        out.add(encodeURIComponent(P.decodeSegment(raw)).toLowerCase());
      } catch (_) {}
    }
    return [...out];
  };

  P.pathMatchesHandle = (path, handle) => {
    const h = String(handle || "").trim().toLowerCase();
    if (!h || !path) return false;
    const variants = new Set();
    const raw = String(path);
    variants.add(raw.toLowerCase());
    try {
      variants.add(decodeURIComponent(raw).toLowerCase());
    } catch (_) {}
    for (const p of variants) {
      if (p === `/@${h}` || p.startsWith(`/@${h}/`)) return true;
      if (p === `/c/${h}` || p.startsWith(`/c/${h}/`)) return true;
      try {
        const enc = encodeURIComponent(h).toLowerCase();
        if (p === `/@${enc}` || p.startsWith(`/@${enc}/`)) return true;
      } catch (_) {}
    }
    return false;
  };

  P.blockedYoutubeHandles = (state) => {
    const set = new Set();
    const fromApi = state.blockedYoutubeHandles || [];
    for (const h of fromApi) {
      let v = String(h || "")
        .trim()
        .replace(/^@/, "");
      v = P.decodeSegment(v).toLowerCase();
      if (v) set.add(v);
    }
    for (const k of P.youtubeBlockKeywords(state)) {
      const h = P.extractHandleFromKeyword(k);
      if (h) set.add(h.toLowerCase());
    }
    return [...set];
  };

  P.blockedYoutubeChannelIds = (state) => {
    const set = new Set();
    for (const id of state.blockedYoutubeChannelIds || []) {
      const v = String(id || "").trim().toLowerCase();
      if (v) set.add(v);
    }
    for (const k of P.youtubeBlockKeywords(state)) {
      const m = String(k).match(/youtube\.com\/channel\/([^/?#\s]+)/i);
      if (m) set.add(m[1].toLowerCase());
    }
    return [...set];
  };

  /**
   * Lowercased set of blocked video IDs — from the app's explicit list AND
   * any watch/shorts/youtu.be URL the user added as a keyword. This is the
   * most reliable single-video block: it works on SPA navigation and in any
   * browser the extension loads in, with no enterprise policy / restart.
   */
  P.blockedYoutubeVideoIds = (state) => {
    const set = new Set();
    for (const id of state.blockedYoutubeVideoIds || []) {
      const v = String(id || "").trim().toLowerCase();
      if (v) set.add(v);
    }
    for (const k of P.youtubeBlockKeywords(state)) {
      const v = P.extractYoutubeVideoId(
        String(k).includes("://") ? k : "https://x/?" + String(k).replace(/^.*\?/, "")
      );
      if (v) set.add(v);
      const m = String(k).match(/(?:youtu\.be\/|\/shorts\/|\/embed\/|[?&]v=)([\w-]{6,})/i);
      if (m) set.add(m[1].toLowerCase());
    }
    return [...set];
  };

  P.hrefReferencesBlockedChannel = (href, handles, channelIds) => {
    const h = String(href || "").toLowerCase();
    if (!h) return false;
    for (const handle of handles) {
      if (!handle) continue;
      for (const hv of P.handleUrlVariants(handle)) {
        if (
          h.includes("/@" + hv) ||
          h.includes("/c/" + hv) ||
          h.includes("/user/" + hv)
        ) {
          return true;
        }
      }
    }
    for (const id of channelIds) {
      if (id && h.includes("/channel/" + id)) return true;
    }
    return false;
  };

  P.contextReferencesBlockedChannel = (ctx, handles, channelIds) => {
    const c = String(ctx || "").toLowerCase();
    if (!c) return false;
    for (const handle of handles) {
      if (!handle) continue;
      for (const hv of P.handleUrlVariants(handle)) {
        if (
          c.includes("/@" + hv) ||
          c.includes("@" + hv) ||
          c.includes("/c/" + hv) ||
          c.includes("/user/" + hv) ||
          c.includes('"' + hv + '"') ||
          (c.includes("vanitychannelurl") && c.includes(hv))
        ) {
          return true;
        }
      }
    }
    for (const id of channelIds) {
      if (id && (c.includes("/channel/" + id) || c.includes('"' + id + '"'))) {
        return true;
      }
    }
    return false;
  };

  P.cardReferencesBlockedChannel = (node, handles, channelIds) => {
    if (!node || (!handles.length && !channelIds.length)) return false;
    const channelNameEl = node.querySelector?.(
      "#text.ytd-channel-name, yt-formatted-string.ytd-channel-name, #channel-name"
    );
    if (channelNameEl) {
      const channelName = (channelNameEl.innerText || channelNameEl.textContent || "")
        .trim()
        .toLowerCase();
      if (channelName) {
        for (const h of handles) {
          const hl = String(h || "").toLowerCase();
          if (!hl) continue;
          if (channelName === hl || channelName.includes(hl)) return true;
        }
      }
    }
    const links = node.querySelectorAll?.('a[href*="/@"], a[href*="/c/"], a[href*="/channel/"], a[href*="/user/"]');
    if (links) {
      for (const a of links) {
        if (P.hrefReferencesBlockedChannel(a.getAttribute("href"), handles, channelIds)) {
          return true;
        }
      }
    }
    let text = node.innerText || "";
    node.querySelectorAll?.("a[href]").forEach((a) => {
      text += " " + (a.getAttribute("href") || "");
    });
    return P.contextReferencesBlockedChannel(text, handles, channelIds);
  };

  P.isYoutubeBlockPattern = (k) => {
    const s = String(k || "").trim().toLowerCase();
    if (!s) return false;
    if (s === "youtube.com" || s === "www.youtube.com" || s === "youtube") {
      return false;
    }
    if (s.includes("youtube.com") || s.includes("youtu.be")) return true;
    if (/^watch\?v=[\w-]{6,}/i.test(s)) return true;
    if (
      /^\/@[^/?#\s]+/.test(s) ||
      /^\/c\/[^/?#\s]+/.test(s) ||
      /^\/channel\//.test(s) ||
      /^\/user\//.test(s)
    ) {
      return true;
    }
    if (s.startsWith("/") && s.length > 2 && !/\s/.test(s) && !s.includes("*")) {
      return true;
    }
    return false;
  };

  P.youtubeBlockKeywords = (state) =>
    P.normList(state.keywords).filter((k) => P.isYoutubeBlockPattern(k));

  P.generalKeywords = (state) =>
    P.normList(state.keywords).filter((k) => !P.isYoutubeBlockPattern(k));

  P.extractYoutubeVideoId = (href) => {
    const preserved = P.extractYoutubeVideoIdPreserved(href);
    return preserved ? preserved.toLowerCase() : "";
  };

  /** Original-case id for oEmbed/API — YouTube 404s on wrongly lowercased ids. */
  P.extractYoutubeVideoIdPreserved = (href) => {
    try {
      const u = new URL(String(href || ""));
      const v = u.searchParams.get("v");
      if (v && /^[\w-]{6,}$/.test(v)) return v;
    } catch (_) {}
    const m = String(href || "").match(
      /(?:youtu\.be\/|\/shorts\/|\/embed\/|watch\?.*[?&]v=|\/v\/)([\w-]{6,})/i
    );
    return m ? m[1] : "";
  };

  P.hrefMatchesYoutubeKey = (href, key) => {
    const h = String(href || "").toLowerCase();
    const k = String(key || "").trim().toLowerCase();
    if (!k || !h) return false;
    if (h.includes(k)) return true;

    const keyVid = P.extractYoutubeVideoId(k.includes("://") ? k : "https://x/?" + k.replace(/^.*\?/, ""));
    const pageVid = P.extractYoutubeVideoId(href);
    if (keyVid && pageVid && keyVid === pageVid) return true;
    const keyVid2 = k.match(/(?:^|[?&]v=)([\w-]{6,})/i);
    if (keyVid2 && pageVid && keyVid2[1].toLowerCase() === pageVid) return true;

    if (k.startsWith("@") && !k.includes("/")) {
      return (
        h.includes("/" + k) ||
        h.includes("/" + k + "/") ||
        h.includes("/" + k + "?")
      );
    }
    if (k.startsWith("/@")) {
      const handle = k.slice(2);
      return (
        h.includes("/@" + handle) ||
        h.includes("/" + handle + "/") ||
        h.includes("/" + handle + "?")
      );
    }
    return false;
  };

  /** Pull channel handle / vanity URL from YouTube inline boot scripts (2024+ UI). */
  P.youtubeBootSignals = () => {
    const parts = [];
    const push = (s) => {
      const v = String(s || "").trim();
      if (v) parts.push(v);
    };
    try {
      for (const s of document.querySelectorAll("script")) {
        const t = s.textContent || "";
        if (!t || t.length < 40) continue;
        if (
          !t.includes("ownerChannelName") &&
          !t.includes("channelHandle") &&
          !t.includes("vanityChannelUrl") &&
          !t.includes("ytInitialPlayerResponse")
        ) {
          continue;
        }
        let m = t.match(/"vanityChannelUrl"\s*:\s*"([^"]+)"/i);
        if (m) push(m[1]);
        m = t.match(/"channelHandle"\s*:\s*"(@[^"]+)"/i);
        if (m) push(m[1]);
        m = t.match(/"externalChannelId"\s*:\s*"([^"]+)"/i);
        if (m) push(m[1]);
        m = t.match(/"browseId"\s*:\s*"(UC[^"]+)"/i);
        if (m) push(m[1]);
        m = t.match(/"channelId"\s*:\s*"(UC[^"]+)"/i);
        if (m) push(m[1]);
        m = t.match(/"ownerChannelName"\s*:\s*"([^"]+)"/i);
        if (m) push(m[1]);
        m = t.match(/"author"\s*:\s*"([^"]+)"/i);
        if (m) push(m[1]);
        const pr = t.match(/ytInitialPlayerResponse\s*=\s*(\{[\s\S]*?\});/);
        if (pr) {
          try {
            const j = JSON.parse(pr[1]);
            const vd = j && j.videoDetails;
            if (vd) {
              push(vd.author);
              push(vd.channelId);
            }
            const owner =
              j &&
              j.microformat &&
              j.microformat.playerMicroformatRenderer &&
              j.microformat.playerMicroformatRenderer.ownerChannelName;
            push(owner);
          } catch (_) {}
        }
      }
    } catch (_) {}
    return parts;
  };

  // @incident: unrelated_video_channel_overlay — recommendations and old SPA
  // bootstrap data are not evidence of the current video's owner.
  P.youtubeChannelIdentity = (value) => {
    let raw = String(value || '').trim();
    if (!raw) return null;
    if (raw.startsWith('@')) raw = '/' + raw;
    if (/^(?:www\.|m\.)?(?:youtube\.com|youtu\.be)\//i.test(raw)) raw = 'https://' + raw;
    try {
      const url = new URL(raw, 'https://www.youtube.com');
      if (!(url.hostname === 'youtube.com' || url.hostname.endsWith('.youtube.com'))) return null;
      const parts = url.pathname.split('/').filter(Boolean).map(P.decodeSegment);
      if (!parts.length) return null;
      const norm = v => String(v).normalize('NFKC').toLowerCase();
      if (parts[0] === 'channel' && parts[1]) return {channelId:norm(parts[1])};
      if (parts[0].startsWith('@') && parts[0].length > 1) return {handle:norm(parts[0].slice(1))};
      if (['c','user'].includes(parts[0]) && parts[1]) return {handle:norm(parts[1])};
      const reserved = new Set(['watch','shorts','embed','feed','results','playlist','gaming','premium','account','channel','c','user','post','live']);
      if (!reserved.has(parts[0]) && !parts[0].includes('.')) return {handle:norm(parts[0])};
    } catch (_) {}
    return null;
  };

  P.currentYoutubeOwner = () => {
    const videoId = P.extractYoutubeVideoIdPreserved(location.href);
    const identities = [];
    const add = value => {const identity=P.youtubeChannelIdentity(value);if(identity)identities.push(identity);};
    const result = {identities,title:''};
    if (!videoId) return result;
    const watch = document.querySelector('ytd-watch-flexy[video-id]');
    if (watch?.getAttribute('video-id') === videoId) {
      watch.querySelectorAll('#owner a[href], ytd-video-owner-renderer a[href]').forEach(a=>add(a.getAttribute('href')));
      result.title = watch.querySelector('h1.ytd-watch-metadata yt-formatted-string, #title h1 yt-formatted-string')?.textContent || '';
      if (identities.length) return result;
    }
    // JSON only: never evaluate page scripts. Balance braces so nested objects
    // and strings containing semicolons/braces do not truncate the response.
    for (const script of document.querySelectorAll('script')) {
      const text = script.textContent || '';
      const assignment = /(?:var\s+)?ytInitialPlayerResponse\s*=\s*\{/.exec(text);
      if (!assignment) continue;
      const start = assignment.index + assignment[0].length - 1;
      let depth=0,quoted=false,escape=false;
      for(let i=start;i<text.length;i++) {
        const ch=text[i];
        if(quoted){if(escape)escape=false;else if(ch==='\\')escape=true;else if(ch==='"')quoted=false;continue;}
        if(ch==='"'){quoted=true;continue;}
        if(ch==='{')depth++;
        if(ch!=='}'||--depth!==0)continue;
        try {
          const data=JSON.parse(text.slice(start,i+1));
          if(data.videoDetails?.videoId!==videoId)break;
          if(data.videoDetails.channelId)identities.push({channelId:String(data.videoDetails.channelId).toLowerCase()});
          add(data.microformat?.playerMicroformatRenderer?.ownerProfileUrl);
          result.title = data.videoDetails.title || result.title;
        } catch (_) {}
        break;
      }
    }
    return result;
  };

  P.youtubePageContextText = () => {
    const owner=P.currentYoutubeOwner();
    return [location.href,owner.title].join(' ').toLowerCase();
  };

  /** True when page context matches a blocked channel keyword (handles legacy /name paths). */
  P.contextMatchesYoutubeKey = (ctx, key) => {
    const c = String(ctx || "").toLowerCase();
    const k = String(key || "").trim().toLowerCase();
    if (!k || !c) return false;
    if (c.includes(k)) return true;
    const slug = k.match(/youtube\.com\/(?:@|c\/)?([^/?#\s]+)/);
    if (slug && slug[1] && c.includes(slug[1])) return true;
    if (k.startsWith("/") && k.length > 2 && c.includes(k)) return true;
  };

  /** Returns matched rule text or null — blocks channel pages + watch pages from that channel. */
  P.blockYoutubeNavigation = (state) => {
    const host=(location.hostname || '').replace(/\.$/,'').toLowerCase();
    if (!(host==='youtube.com'||host.endsWith('.youtube.com'))) return null;
    const urlKeys = P.youtubeBlockKeywords(state);
    const handles = (state.blockedYoutubeHandles || []).map(h=>P.decodeSegment(String(h||'').trim().replace(/^@/,'')));
    const channelIds = P.blockedYoutubeChannelIds(state);

    const pageVid = P.extractYoutubeVideoId(location.href);
    if (pageVid) {
      // Strongest, most direct check: is this exact video on the block list?
      // Both sides are lowercased by extractYoutubeVideoId / the getter, so
      // case never breaks the match (the old bug). Works on direct nav AND
      // SPA navigation because content.js re-runs this on URL changes.
      const blockedVids = P.blockedYoutubeVideoIds(state);
      if (blockedVids.includes(pageVid)) {
        return "youtube.com/watch?v=" + pageVid;
      }
    }
    const norm = v => P.decodeSegment(String(v || '')).normalize('NFKC').toLowerCase();
    const blocked = [];
    for (const k of urlKeys) {const id=P.youtubeChannelIdentity(k);if(id)blocked.push({...id,rule:k});}
    for (const h of handles) blocked.push({handle:norm(h),rule:'youtube.com/@'+h});
    for (const id of channelIds) blocked.push({channelId:norm(id),rule:'youtube.com/channel/'+id});
    const current=P.currentYoutubeOwner();
    const direct=P.youtubeChannelIdentity(location.href);
    const identities=direct?[direct]:current.identities;
    for(const rule of blocked) {
      if(identities.some(id=>(rule.handle&&id.handle===rule.handle)||(rule.channelId&&id.channelId===rule.channelId)))return rule.rule;
    }
    const ctx=[location.href,current.title].join(' ').toLowerCase();
    const general = P.generalKeywords(state);
    for (const k of general) {
      if (!k || k.length < 2) continue;
      if (ctx.includes(k)) return k;
    }
    return null;
  };

  P.hideMatch = (text, el, keys, doms, removeNode) => {
    const t = (text || "").toLowerCase();
    if (keys.length) {
      for (const k of keys) {
        if (k && t.includes(k)) {
          P.hideNode(el);
          return true;
        }
      }
    }
    if (doms.length && P.matchesBlockedDomain(t, doms)) {
      P.hideNode(el);
      return true;
    }
    return false;
  };

  P.collectText = (node) => {
    let allText = node.innerText || "";
    node.querySelectorAll("a[href]").forEach((a) => {
      allText += " " + (a.getAttribute("href") || "");
    });
    return allText;
  };

  P.filterSerp = (state) => {
    if (!state.hideSerp && !state.precisionContentFilter) return;
    const compiled = P.compiledRules(state);
    const keys = compiled.keywords;
    const doms = compiled.domains;
    if (!keys.length && !doms.length) return;

    const selectors = [
      "motion div.g",
      "motion div[data-hveid]",
      "motion div[data-sokoban-container]",
      "div.g",
      "motion div[data-hveid]",
      "div[data-hveid]",
      "div[data-sokoban-container]",
      "article[data-testid='result']",
      ".result",
      "li.b_algo",
    ];
    document.querySelectorAll(selectors.join(",")).forEach((node) => {
      if (node.closest("#sixvpn-block-overlay")) return;
      P.hideMatch(P.collectText(node), node, keys, doms, true);
    });

    document
      .querySelectorAll(
        "div[data-id][jsname], div.isv-r, div.isv-r-am, div[jscontroller][data-tbnid], g-img"
      )
      .forEach((node) => {
        const imgs = node.querySelectorAll("img");
        const links = node.querySelectorAll("a[href]");
        let allText = "";
        imgs.forEach((i) => {
          allText += " " + (i.getAttribute("alt") || "");
          allText += " " + (i.getAttribute("data-iurl") || "");
        });
        links.forEach((a) => {
          allText += " " + (a.getAttribute("href") || "");
        });
        const parent =
          node.closest("motion div[data-hveid]") ||
          node.closest("div[data-hveid]") ||
          node.closest("motion div.isv-r") ||
          node.closest("div.isv-r") ||
          node;
        P.hideMatch(allText, parent, keys, doms, true);
      });

    document.querySelectorAll("a.iusc, div.imgpt").forEach((node) => {
      const allText =
        (node.getAttribute("m") || "") +
        " " +
        (node.getAttribute("href") || "") +
        " " +
        (node.innerText || "");
      P.hideMatch(allText, node, keys, doms, true);
    });
  };

  P.cardMatchesYoutubeRules = (allText, state, node, prepared) => {
    const compiled = prepared || P.compiledRules(state);
    const handles = compiled.handles;
    const channelIds = compiled.channelIds;
    if (node && P.cardReferencesBlockedChannel(node, handles, channelIds)) {
      return handles[0] ? "@" + handles[0] : "channel:" + (channelIds[0] || "");
    }
    const t = String(allText || "").toLowerCase();
    if (P.contextReferencesBlockedChannel(t, handles, channelIds)) {
      return handles[0] ? "@" + handles[0] : "channel:" + (channelIds[0] || "");
    }
    for (const k of compiled.youtube) {
      if (k && (t.includes(k) || P.hrefMatchesYoutubeKey(t, k))) return k;
    }
    for (const k of compiled.general) {
      if (k && k.length >= 2 && t.includes(k)) return k;
    }
    return null;
  };

  P.filterYoutube = (state) => {
    if (!/\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""))) return;
    if (state.hideYoutubeResults === false) return;
    const compiled = P.compiledRules(state);
    const urlKeys = compiled.youtube;
    const general = compiled.general;
    const handles = compiled.handles;
    const channelIds = compiled.channelIds;
    if (!urlKeys.length && !general.length && !handles.length && !channelIds.length) {
      return;
    }
    const selectors =
      "ytd-video-renderer,ytd-item-section-renderer,#contents ytd-video-renderer," +
      "ytd-rich-item-renderer,ytd-grid-video-renderer,ytd-compact-video-renderer," +
      "ytd-playlist-video-renderer,ytd-reel-item-renderer,ytm-rich-item-renderer," +
      "ytm-video-with-context-renderer,ytd-search-pyv-renderer,ytd-item-section-renderer," +
      "yt-lockup-view-model,ytm-video-list-renderer,grid-video-renderer," +
      "ytd-watch-metadata,ytd-comments-header";
    document.querySelectorAll(selectors).forEach((node) => {
      if (node.getAttribute("data-sixvpn-blocked") === "1") return;
      let allText = node.innerText || "";
      node.querySelectorAll("a[href]").forEach((a) => {
        allText += " " + (a.getAttribute("href") || "");
      });
      node.querySelectorAll("yt-formatted-string,#video-title").forEach((el) => {
        allText += " " + (el.textContent || "");
      });
      if (P.cardMatchesYoutubeRules(allText, state, node, compiled)) {
          P.hideNode(node);
        node.setAttribute("data-sixvpn-blocked", "1");
      }
    });
  };

  P.queryParamValues = (href) => {
    const out = [];
    try {
      const u = new URL(href);
      for (const key of ["q", "search_query", "query", "k"]) {
        const v = u.searchParams.get(key);
        if (v) out.push(decodeURIComponent(v).toLowerCase());
      }
    } catch (_) {}
    return out;
  };

  P.termMatchesRule = (query, term, match) => {
    const q = String(query || "").toLowerCase();
    const t = String(term || "").toLowerCase().trim();
    if (!t || !q) return false;
    const m = String(match || "contains").toLowerCase();
    if (m === "exact") return q === t;
    if (m === "prefix") return q.startsWith(t);
    return q.includes(t);
  };

  P.blockForbiddenSearch = (state) => {
    const rules = state.searchQueries || [];
    if (!rules.length) return false;
    const href = location.href;
    const host = ((location.hostname || "").replace(/\.$/, "")).toLowerCase();
    const isGoogle =
      host.includes("google.") &&
      (location.pathname === "/search" || location.pathname === "/images");
    const isYoutube =
      /\.youtube\.com$/i.test(host) &&
      (location.pathname === "/results" || location.search.includes("search_query"));
    if (!isGoogle && !isYoutube) return false;

    for (const q of P.queryParamValues(href)) {
      for (const rule of rules) {
        const term = rule.term || rule;
        const match = rule.match || "contains";
        if (P.termMatchesRule(q, term, match)) {
          if (document.getElementById("sixvpn-search-block-overlay")) return true;
          const el = document.createElement("div");
          el.id = "sixvpn-search-block-overlay";
          el.setAttribute("role", "alertdialog");
          el.style.cssText =
            "position:fixed;inset:0;z-index:2147483647;background:#12121c;color:#f5f5f7;" +
            "display:flex;flex-direction:column;align-items:center;justify-content:center;" +
            "font:16px system-ui,sans-serif;padding:32px;text-align:center;box-sizing:border-box";
          el.innerHTML =
            '<div style="max-width:420px"><h2 style="margin:0 0 12px;font-size:22px">FocusFense</h2>' +
            "<p style=\"margin:0 0 8px;line-height:1.5\">이 검색어는 스케줄·규칙에 의해 차단되었습니다.</p>" +
            '<p style="margin:0;font-size:13px;opacity:.65">' +
            String(term).replace(/</g, "&lt;") +
            "</p></div>";
          document.documentElement.appendChild(el);
          P.lockPage();
          return true;
        }
      }
    }
    return false;
  };

  P.applyRulesPayload = (state, data) => {
    if (!data) return;
    state.protectionEnabled = data.protectionEnabled !== false;
    if (!state.protectionEnabled) {
      Object.assign(state, {
        blockedDomains: [], keywords: [], keywordRules: [], searchQueries: [],
        blockedYoutubeHandles: [], blockedYoutubeChannelIds: [], blockedYoutubeVideoIds: [],
        precisionContentFilter: false, hideSerp: false, hideYoutubeResults: false,
        hideImages: false, hideYtHomeFeed: false, hideImagesOnYoutube: false,
        hideGoogleHomeFeed: false, forceSafeSearch: false, focusLocked: false,
      });
      P.restorePage();
      return;
    }
    if (Array.isArray(data.blockedDomains)) state.blockedDomains = data.blockedDomains;
    if (Array.isArray(data.keywords)) state.keywords = data.keywords;
    if (Array.isArray(data.keywordRules)) state.keywordRules = data.keywordRules;
    if (Array.isArray(data.blockedYoutubeHandles)) {
      state.blockedYoutubeHandles = data.blockedYoutubeHandles;
    }
    if (Array.isArray(data.blockedYoutubeChannelIds)) {
      state.blockedYoutubeChannelIds = data.blockedYoutubeChannelIds;
    }
    if (Array.isArray(data.searchQueries)) state.searchQueries = data.searchQueries;
    if (Array.isArray(data.blockedYoutubeVideoIds)) state.blockedYoutubeVideoIds = data.blockedYoutubeVideoIds;
    if (typeof data.hideImages === 'boolean') state.hideImages = data.hideImages;
    if (typeof data.hideGoogleHomeFeed === 'boolean') state.hideGoogleHomeFeed = data.hideGoogleHomeFeed;
    if (typeof data.forceSafeSearch === 'boolean') state.forceSafeSearch = data.forceSafeSearch;
    if (typeof data.focusLocked === 'boolean') state.focusLocked = data.focusLocked;
    if (typeof data.precisionContentFilter === "boolean") {
      state.precisionContentFilter = data.precisionContentFilter;
    }
    if (typeof data.hideSerp === "boolean") state.hideSerp = data.hideSerp;
    if (typeof data.hideYoutubeResults === "boolean") {
      state.hideYoutubeResults = data.hideYoutubeResults;
    }
    if (typeof data.hideYtHomeFeed === "boolean") {
      state.hideYtHomeFeed = data.hideYtHomeFeed;
    }
    if (typeof data.hideImagesOnYoutube === "boolean") {
      state.hideImagesOnYoutube = data.hideImagesOnYoutube;
    }
  };
  // Snapshot raw rule values once per filtering pass. Compare values, not just
  // object identity: app payloads and callers can mutate an existing array.
  const compileFields = ['keywords','blockedDomains','blockedYoutubeHandles','blockedYoutubeChannelIds','blockedYoutubeVideoIds'];
  const ruleCache = new WeakMap();
  const compiling = new WeakSet();
  const rawRuleGetters = {
    youtube: P.youtubeBlockKeywords, general: P.generalKeywords,
    handles: P.blockedYoutubeHandles, channelIds: P.blockedYoutubeChannelIds,
    videoIds: P.blockedYoutubeVideoIds,
  };
  P.compiledRules = state => {
    const snapshots = compileFields.map(key => Array.from(state[key] || [], value => String(value)));
    const previous = ruleCache.get(state);
    if (previous && snapshots.every((list,index) => list.length === previous.snapshots[index].length && list.every((value,i) => value === previous.snapshots[index][i]))) return previous.result;
    compiling.add(state);
    try {
      const result = {keywords: P.normList(state.keywords), domains: P.normList(state.blockedDomains).map(P.normDomain)};
      for (const [name,getter] of Object.entries(rawRuleGetters)) result[name] = getter(state);
      for (const list of Object.values(result)) Object.freeze(list);
      Object.freeze(result);
      ruleCache.set(state,{snapshots,result});
      return result;
    } finally { compiling.delete(state); }
  };
  for (const [name,getter] of Object.entries(rawRuleGetters)) {
    const method = {youtube:'youtubeBlockKeywords',general:'generalKeywords',handles:'blockedYoutubeHandles',channelIds:'blockedYoutubeChannelIds',videoIds:'blockedYoutubeVideoIds'}[name];
    P[method] = state => compiling.has(state) ? getter(state) : P.compiledRules(state)[name];
  }
})();
