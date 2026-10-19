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
      for (const name of ['data-sixvpn-display-before', 'data-sixvpn-blocked', 'data-sixvpn-yt-guide-checked']) node.removeAttribute(name);
    }
    for (const id of ['sixvpn-block-overlay', 'sixvpn-search-block-overlay', 'sixvpn-fg-quota-overlay']) {
      document.getElementById(id)?.remove();
    }
    const root = document.documentElement;
    if (root.hasAttribute('data-sixvpn-overflow-before')) {
      if (root.style.overflow === 'hidden') root.style.overflow = root.getAttribute('data-sixvpn-overflow-before');
      root.removeAttribute('data-sixvpn-overflow-before');
    }
    root.removeAttribute('data-sixvpn-yt-pending');
    root.removeAttribute('data-sixvpn-hide-img');
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

  P.youtubePageContextText = () => {
    const parts = [location.href, document.title || ""];
    const sel =
      'a[href*="/@"],a[href*="/channel/"],a[href*="/c/"],a[href*="/user/"],' +
      "ytd-channel-name a,#channel-name a,#owner a,.ytd-channel-name a," +
      "ytd-video-owner-renderer a,yt-content-metadata-view-model a," +
      "ytd-watch-metadata a,#upload-info a,yt-formatted-string.ytd-channel-name a," +
      "#owner-name a,#channel-container a,yt-attributed-string a";
    document.querySelectorAll(sel).forEach((el) => {
      const href = el.getAttribute?.("href") || "";
      if (href) parts.push(href);
      const t = el.textContent || "";
      if (t) parts.push(t);
    });
    P.youtubeBootSignals().forEach((s) => parts.push(s));
    try {
      const ld = document.querySelector(
        'script[type="application/ld+json"]'
      );
      if (ld && ld.textContent) parts.push(ld.textContent);
    } catch (_) {}
    return parts.join(" ").toLowerCase();
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
    if (!/\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""))) return null;
    const href = location.href.toLowerCase();
    const path = (location.pathname || "").toLowerCase();
    const ctx = P.youtubePageContextText();
    const urlKeys = P.youtubeBlockKeywords(state);
    const handles = P.blockedYoutubeHandles(state);
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
      for (const k of urlKeys) {
        if (P.hrefMatchesYoutubeKey("https://youtube.com/watch?v=" + pageVid, k)) {
          return k;
        }
      }
    }

    if (
      path === "/watch" ||
      path.startsWith("/shorts/") ||
      path.startsWith("/embed/")
    ) {
      if (P.contextReferencesBlockedChannel(ctx, handles, channelIds)) {
        return (
          handles[0] ? "youtube.com/@" + handles[0] : "youtube.com/channel/" + channelIds[0]
        );
      }
      // Legacy slug rules (youtube.com/뷰티풀너드) — match author in boot JSON.
      const boot = P.youtubeBootSignals().join(" ").toLowerCase();
      for (const k of urlKeys) {
        const slugM = String(k).match(/youtube\.com\/([^/?#\s@]+)/);
        if (!slugM) continue;
        const slug = decodeURIComponent(slugM[1]).toLowerCase();
        if (!slug || slug === "watch" || slug === "shorts") continue;
        if (ctx.includes(slug) || boot.includes(slug)) return k;
      }
    }

    for (const h of handles) {
      if (P.pathMatchesHandle(path, h)) {
        return "youtube.com/@" + h;
      }
    }

    for (const k of urlKeys) {
      const handle = P.extractHandleFromKeyword(k);
      if (handle && P.pathMatchesHandle(path, handle)) return k;
    }

    if (P.contextReferencesBlockedChannel(ctx, handles, channelIds)) {
      return handles[0]
        ? "@" + handles[0]
        : "channel:" + (channelIds[0] || "");
    }

    for (const k of urlKeys) {
      if (
        P.hrefMatchesYoutubeKey(href, k) ||
        P.hrefMatchesYoutubeKey(ctx, k) ||
        P.contextMatchesYoutubeKey(ctx, k)
      ) {
        return k;
      }
    }

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

  P.youtubeCardSelectors =
      "ytd-video-renderer,ytd-item-section-renderer,#contents ytd-video-renderer," +
      "ytd-rich-item-renderer,ytd-grid-video-renderer,ytd-compact-video-renderer," +
      "ytd-playlist-video-renderer,ytd-reel-item-renderer,ytm-rich-item-renderer," +
      "ytm-video-with-context-renderer,ytd-search-pyv-renderer,ytd-item-section-renderer," +
      "yt-lockup-view-model,ytm-video-list-renderer,grid-video-renderer," +
      "ytd-watch-metadata,ytd-comments-header";

  P.youtubeMutationRoots = (records) => {
    const roots=new Set();
    for(const record of records || []){
      const node=record.target?.nodeType===1?record.target:record.target?.parentElement;
      if(node?.closest?.('[data-focusfense-budget-notice]'))continue;
      const card=node?.closest?.(P.youtubeCardSelectors);
      if(card)roots.add(card);
      for(const added of record.addedNodes || []){
        if(added.nodeType===1)roots.add(added);
      }
    }
    return roots;
  };

  // Coalesce DOM-driven work, including continuous comment/chat mutations.
  // A hidden tab stores dirtiness without waking timers; navigation guards
  // stay outside this scheduler. No subprocess, API probe or periodic scan.
  P.createPageFilterScheduler = ({run,now=()=>Date.now(),schedule=setTimeout,cancel=clearTimeout,isHidden=()=>document.visibilityState==='hidden',delayMs=750}) => {
    let dirty=false,full=false,timer=null,last=now();
    const roots=new Set();
    function flush(){
      if(timer!==null){cancel(timer);timer=null;}
      if(!dirty||isHidden())return;
      const wait=Math.max(0,delayMs-(now()-last));
      if(wait){timer=schedule(flush,wait);return;}
      const selected=full?null:Array.from(roots);
      dirty=false;full=false;roots.clear();last=now();
      run(selected);
    }
    return {
      mark(changedRoots=null){
        dirty=true;
        if(changedRoots===null)full=true;
        else for(const root of changedRoots){roots.add(root);if(roots.size>256){full=true;roots.clear();break;}}
        if(!isHidden()&&timer===null)timer=schedule(flush,Math.max(0,delayMs-(now()-last)));
      },
      flush,
      cancel(){if(timer!==null)cancel(timer);timer=null;}
    };
  };

  P.filterYoutube = (state, changedRoots=null) => {
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
    const cards=new Set();
    if(changedRoots===null){for(const node of document.querySelectorAll(P.youtubeCardSelectors))cards.add(node);}
    else for(const root of changedRoots){
      if(root?.isConnected===false)continue;
      const card=root?.closest?.(P.youtubeCardSelectors);
      if(card)cards.add(card);
      for(const node of root?.querySelectorAll?.(P.youtubeCardSelectors)||[])cards.add(node);
    }
    cards.forEach((node) => {
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
      for (const key of ["q", "search_query", "query", "k", "p", "keyword", "text"]) {
        const v = u.searchParams.get(key);
        // URLSearchParams already decodes once; decoding again rejects literal
        // percent signs and lets a query such as "100% <blocked word>" bypass.
        if (v) out.push(v);
      }
    } catch (_) {}
    return out;
  };

  P.normalizeRuleText = (text, caseSensitive = false) => {
    const normalized = String(text || '').normalize('NFKC')
      .replace(/[\u200B-\u200D\uFEFF]/g, '').replace(/\s+/g, ' ').trim();
    return caseSensitive ? normalized : normalized.toLowerCase();
  };
  P.termMatchesRule = (query, term, match, caseSensitive = false) => {
    const q = P.normalizeRuleText(query, caseSensitive);
    const t = P.normalizeRuleText(term, caseSensitive);
    if (!t || !q) return false;
    const m = String(match || "contains").toLowerCase();
    if (m === "exact") return q === t;
    if (m === "prefix" || m === "starts_with") return q.startsWith(t);
    return q.includes(t);
  };

  P.pageKeywordMatch = (state, text) => {
    if (state.protectionEnabled === false) return null;
    const rules = (state.keywordRules || []).filter(rule => rule.action === 'block_page');
    if (!rules.length) return null;
    const preserved = P.normalizeRuleText(text, true);
    const folded = preserved.toLowerCase();
    for (const rule of rules) {
      const query = rule.caseSensitive ? preserved : folded;
      const term = P.normalizeRuleText(rule.pattern, rule.caseSensitive);
      if (!term) continue;
      const mode = rule.match || 'contains';
      const hit = mode === 'exact' ? query === term
        : mode === 'starts_with' || mode === 'prefix' ? query.startsWith(term)
        : query.includes(term);
      if (hit) return rule.pattern;
    }
    return null;
  };

  P.blockForbiddenSearch = (state) => {
    if (state.protectionEnabled === false) return false;
    const rules = state.searchQueries || [];
    if (!rules.length) return false;
    const href = location.href;
    const host = ((location.hostname || "").replace(/\.$/, "")).toLowerCase();
    const isGoogle =
      /(^|\.)google\.(?:com|[a-z]{2,3}|(?:co|com)\.[a-z]{2})$/.test(host) &&
      (location.pathname === "/search" || location.pathname === "/images");
    const isYoutube =
      /\.youtube\.com$/i.test(host) &&
      (location.pathname === "/results" || location.search.includes("search_query"));
    const isOtherSearch =
      (/(^|\.)bing\.com$/.test(host) && /^\/(search|images)/.test(location.pathname)) ||
      (/(^|\.)duckduckgo\.com$/.test(host)) ||
      (host === 'search.naver.com') || (host === 'search.yahoo.com');
    if (!isGoogle && !isYoutube && !isOtherSearch) return false;

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
      Object.assign(state, { blockedDomains: [], keywords: [], searchQueries: [],
        keywordRules: [],
        blockedYoutubeHandles: [], blockedYoutubeChannelIds: [], blockedYoutubeVideoIds: [],
        precisionContentFilter: false, hideSerp: false, hideYoutubeResults: false,
        hideYtHomeFeed: false, forceSafeSearch: false, focusLocked: false });
      P.restorePage();
      return;
    }
    if (Array.isArray(data.blockedDomains)) {
      state.blockedDomains = data.blockedDomains;
    }
    if (Array.isArray(data.keywords)) state.keywords = data.keywords;
    if (Array.isArray(data.keywordRules)) state.keywordRules = data.keywordRules;
    if (Array.isArray(data.blockedYoutubeHandles)) {
      state.blockedYoutubeHandles = data.blockedYoutubeHandles;
    }
    if (Array.isArray(data.blockedYoutubeChannelIds)) {
      state.blockedYoutubeChannelIds = data.blockedYoutubeChannelIds;
    }
    if (Array.isArray(data.blockedYoutubeVideoIds)) state.blockedYoutubeVideoIds = data.blockedYoutubeVideoIds;
    if (typeof data.forceSafeSearch === 'boolean') state.forceSafeSearch = data.forceSafeSearch;
    if (Array.isArray(data.searchQueries)) state.searchQueries = data.searchQueries;
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
