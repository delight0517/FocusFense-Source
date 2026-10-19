(() => {
  if (globalThis.__ffLegacyContentStarted) return;
  globalThis.__ffLegacyContentStarted = true;
  const P = globalThis.sixvpnPrecision;
  const state = {
    protectionEnabled: false,
    hideImages: false,
    hideSerp: false,
    hideYoutubeResults: false,
    precisionContentFilter: false,
    keywords: [],
    blockedYoutubeHandles: [],
    blockedYoutubeChannelIds: [],
    blockedYoutubeVideoIds: [],
    searchQueries: [],
    blockedDomains: [],
    hideYtHomeFeed: false,
    hideImagesOnYoutube: false,
    hideGoogleHomeFeed: false,
    forceSafeSearch: false,
  };

  const DEFAULT_BLOCKED_DOMAINS = [];

  function pull(cb) {
    chrome.storage.local.get(
      {
        protectionEnabled: false,
        hideImages: false,
        hideSerp: false,
        keywords: [],
        blockedDomains: DEFAULT_BLOCKED_DOMAINS,
        blockedYoutubeHandles: [],
        blockedYoutubeChannelIds: [],
        blockedYoutubeVideoIds: [],
        hideYtHomeFeed: false,
        hideImagesOnYoutube: false,
        hideGoogleHomeFeed: false,
        forceSafeSearch: false,
      },
      (cfg) => {
        Object.assign(state, cfg);
        if (typeof cb === "function") cb();
      }
    );
  }

  function applyImages() {
    if (!state.protectionEnabled) {
      document.documentElement.removeAttribute('data-sixvpn-hide-img');
      return;
    }
    const onYoutube = /\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""));
    const hideOnYt = state.hideImagesOnYoutube === true;
    const hide =
      !!state.hideImages && !(onYoutube && !hideOnYt);
    const value = hide ? "1" : "0";
    if (document.documentElement.getAttribute("data-sixvpn-hide-img") !== value) {
      document.documentElement.setAttribute("data-sixvpn-hide-img", value);
    }
  }

  function normList(list) {
    return (list || [])
      .map((s) => String(s).trim().toLowerCase())
      .filter(Boolean);
  }

  function normDomain(host) {
    return String(host || "")
      .trim()
      .toLowerCase()
      .replace(/\.$/, "")
      .replace(/^www\./, "");
  }

  function matchesBlockedDomain(text, domains) {
    if (!domains.length) return false;
    const t = String(text || "").toLowerCase();
    for (const d of domains) {
      if (!d) continue;
      if (t.includes(d)) return true;
    }
    return false;
  }

  /** Cold Turkey–style host glob (e.g. youtube.*, *.*). */
  function coldTurkeyGlobRegex(pattern) {
    const pat = String(pattern || "").trim().toLowerCase();
    let out = "";
    for (let i = 0; i < pat.length; i++) {
      const ch = pat[i];
      if (ch === "*") {
        out += ".*";
        continue;
      }
      if (ch === "[") {
        const close = pat.indexOf("]", i + 1);
        if (close > i + 1) {
          const chars = pat.slice(i + 1, close);
          if (/^[a-z0-9?&*_\-]+$/i.test(chars)) {
            out += "[" + chars + "]";
            i = close;
            continue;
          }
        }
      }
      if (ch === "(" || ch === ")" || ch === "|") {
        const open = ch === "(" ? i : pat.lastIndexOf("(", i - 1);
        const close = open < 0 ? -1 : pat.indexOf(")", open + 1);
        const group = open < 0 || close < 0 ? "" : pat.slice(open + 1, close);
        const supported = group.includes("|") && !/[()]/.test(group);
        const inSupportedGroup = supported &&
          (i === open || i === close || (ch === "|" && i > open && i < close));
        out += inSupportedGroup ? ch : ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        continue;
      }
      if (ch === "?" && i > 0 && (pat[i - 1] === "]" || pat[i - 1] === ")")) {
        out += "?";
        continue;
      }
      out += ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }
    return out;
  }

  function hostPatternMatches(host, pattern) {
    const h = String(host || "")
      .toLowerCase()
      .replace(/\.$/, "")
      .replace(/^www\./, "");
    const pat = String(pattern || "").trim().toLowerCase();
    if (!pat || pat === "*" || pat === "*.*") return true;
    if (pat.endsWith(".*")) {
      const stem = pat.slice(0, -2);
      if (!stem) return true;
      return h === stem || h.endsWith("." + stem) || h.includes(stem);
    }
    const re = new RegExp("^" + coldTurkeyGlobRegex(pat) + "$", "i");
    return re.test(h);
  }

  function pathGlobMatches(pathQuery, pattern) {
    const pq = String(pathQuery || "").toLowerCase();
    const pat = String(pattern || "").trim().toLowerCase();
    if (!pat) return true;
    const re = new RegExp(coldTurkeyGlobRegex(pat), "i");
    return re.test(pq);
  }

  /** Full URL match for imported path / query rules (mirrors app url_rule_matcher.dart). */
  function urlMatchesColdTurkeyPattern(href, pattern) {
    const p = String(pattern || "").trim().toLowerCase();
    if (!p) return false;
    let url = String(href || "").trim().toLowerCase();
    if (!url) return false;
    try {
      const u = new URL(url.includes("://") ? url : "https://" + url);
      let host = (u.hostname || "").toLowerCase().replace(/\.$/, "").replace(/^www\./, "");
      const encodedPathQuery = u.pathname + (u.search || "");
      let decodedPathQuery = encodedPathQuery;
      try {
        decodedPathQuery = decodeURIComponent(encodedPathQuery.replace(/\+/g, "%20"));
      } catch (_) {}
      const pathQueries = [encodedPathQuery, decodedPathQuery].map((value) =>
        value.toLowerCase()
      );
      const slash = p.indexOf("/");
      const hostPat = slash >= 0 ? p.substring(0, slash) : p;
      const pathPat = slash >= 0 ? p.substring(slash) : "";
      const hostMatches = hostPat.includes("*")
        ? hostPatternMatches(host, hostPat)
        : host === hostPat || host.endsWith("." + hostPat);
      if (!hostMatches) return false;
      if (pathPat) return pathQueries.some((pathQuery) =>
        pathGlobMatches(pathQuery, pathPat)
      );
      return hostMatches;
    } catch (_) {
      return url.includes(p.replace(/\*/g, ""));
    }
  }

  function hostBlockedByDomainList(host, domains) {
    const h = String(host || "")
      .toLowerCase()
      .replace(/^www\./, "");
    const onYoutube = /\.youtube\.com$/i.test(h) || h === "youtu.be";
    for (const d of domains) {
      if (!d) continue;
      const dom = String(d).toLowerCase().replace(/\.$/, "").replace(/^www\./, "");
      if (onYoutube && (dom === "youtube.com" || dom === "youtu.be")) continue;
      if (h === dom || h.endsWith("." + dom)) return dom;
    }
    return null;
  }

  function showBlockOverlay(matchedRule) {
    if (document.getElementById("sixvpn-block-overlay")) return;
    reportBlock(matchedRule, "navigation");
    try {
      document.querySelectorAll("video,audio").forEach((m) => {
        m.pause();
        m.removeAttribute("src");
        m.load && m.load();
      });
    } catch (_) {}
    const el = document.createElement("div");
    el.id = "sixvpn-block-overlay";
    el.setAttribute("role", "alertdialog");
    el.style.cssText =
      "position:fixed;inset:0;z-index:2147483647;background:#12121c;color:#f5f5f7;" +
      "display:flex;flex-direction:column;align-items:center;justify-content:center;" +
      "font:16px system-ui,-apple-system,sans-serif;padding:32px;text-align:center;box-sizing:border-box";
    el.innerHTML =
      '<div style="max-width:420px">' +
      '<h2 style="margin:0 0 12px;font-size:22px;font-weight:700">FocusFense</h2>' +
      '<p style="margin:0 0 8px;line-height:1.5;opacity:.92">설정된 차단 규칙과 일치해 이 페이지를 차단했습니다.</p>' +
      '<p style="margin:0;font-size:13px;opacity:.65;word-break:break-all">' +
      '적용된 규칙: ' + String(matchedRule || "").replace(/&/g, "&amp;").replace(/</g, "&lt;") +
      "</p></div>";
    document.documentElement.appendChild(el);
    P?.lockPage();
  }

  const RULES_PORTS = [17361, 17362, 17363, 17364, 17365, 17366, 17367, 17368, 17369, 17370, 17371, 17372];
  let rulesBase = "http://127.0.0.1:17361";
  const RULES_PULL_MS = 4000;

  const BROWSER_TAG =
    typeof browser !== "undefined" && browser.runtime && !chrome.runtime?.getManifest
      ? "firefox"
      : "chrome";

  function isYoutubeWatchPage() {
    return (
      /\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, "")) &&
      /^\/watch/.test(location.pathname || "")
    );
  }

  function setYoutubePending(on) {
    if (on) document.documentElement.setAttribute("data-sixvpn-yt-pending", "1");
    else document.documentElement.removeAttribute("data-sixvpn-yt-pending");
  }

  if (isYoutubeWatchPage()) setYoutubePending(true);

  const _ytApiChecked = new Set();
  let _ytApiInflight = "";
  const _channelApiChecked = new Set();
  let _channelApiInflight = "";

  async function blockViaAppChannelCheck() {
    if (!state.protectionEnabled) return false;
    if (!/\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""))) return false;
    const path = location.pathname || "";
    if (!/^\/@|^\/c\//i.test(path)) return false;
    const cacheKey = path.toLowerCase();
    if (_channelApiChecked.has(cacheKey)) return false;
    if (_channelApiInflight === cacheKey) return false;
    _channelApiInflight = cacheKey;
    try {
      for (const port of RULES_PORTS) {
        try {
          const ctrl = new AbortController();
          const timer = setTimeout(() => ctrl.abort(), 5000);
          const res = await fetch(
            `http://127.0.0.1:${port}/youtube/channel-check?path=${encodeURIComponent(path)}`,
            { cache: "no-store", signal: ctrl.signal }
          );
          clearTimeout(timer);
          if (!res.ok) continue;
          rulesBase = `http://127.0.0.1:${port}`;
          const data = await res.json();
          _channelApiChecked.add(cacheKey);
          if (data && data.blocked) {
            showBlockOverlay(
              data.rule || data.matched || `youtube.com${path}`
            );
            reportBlock(data.rule || data.matched, "youtube_channel_api");
            return true;
          }
          return false;
        } catch (_) {
          /* next port */
        }
      }
      return false;
    } finally {
      if (_channelApiInflight === cacheKey) _channelApiInflight = "";
    }
  }

  async function blockViaAppYoutubeCheck(force) {
    if (!state.protectionEnabled) return false;
    if (!P || !isYoutubeWatchPage()) return false;
    const vid = P.extractYoutubeVideoIdPreserved(location.href);
    if (!vid) {
      setYoutubePending(false);
      return false;
    }
    if (!force && _ytApiChecked.has(vid)) return false;
    if (_ytApiInflight === vid) return false;
    _ytApiInflight = vid;
    try {
      for (const port of RULES_PORTS) {
        try {
          const ctrl = new AbortController();
          const timer = setTimeout(() => ctrl.abort(), 7000);
          const res = await fetch(
            `http://127.0.0.1:${port}/youtube/check?v=${encodeURIComponent(vid)}`,
            { cache: "no-store", signal: ctrl.signal }
          );
          clearTimeout(timer);
          if (!res.ok) continue;
          rulesBase = `http://127.0.0.1:${port}`;
          const data = await res.json();
          _ytApiChecked.add(vid);
          if (data && data.blocked) {
            setYoutubePending(true);
            showBlockOverlay(
              data.rule || data.matched || `youtube.com/watch?v=${vid}`
            );
            reportBlock(data.rule || data.matched, "youtube_api");
            return true;
          }
          setYoutubePending(false);
          return false;
        } catch (_) {
          /* try next port */
        }
      }
      setYoutubePending(false);
      return false;
    } finally {
      if (_ytApiInflight === vid) _ytApiInflight = "";
    }
  }

  async function applyAllAsync() {
    if (!state.protectionEnabled) {
      P?.restorePage();
      return;
    }
    if (blockNavigationIfNeeded()) return;
    if (await blockViaAppChannelCheck()) return;
    if (await blockViaAppYoutubeCheck(false)) return;
    if (blockForbiddenSearch()) return;
    applyImages();
    filterSerp();
    filterYoutubeFeed();
    hideFeeds();
    enforceSafeSearch();
  }

  /** Layer 1–3: block navigation when URL matches domain list or keyword/pattern rows. */
  function blockNavigationIfNeeded() {
    if (!state.protectionEnabled) return false;
    if (/\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""))) {
      if (P) {
        const ytRule = P.blockYoutubeNavigation(state);
        if (ytRule) {
          showBlockOverlay(ytRule);
          return true;
        }
      }
    }

    const href = location.href;
    const doms = normList(state.blockedDomains).map(normDomain);
    const keys = normList(state.keywords);

    const hostHit = hostBlockedByDomainList(location.hostname, doms);
    if (hostHit) {
      showBlockOverlay(hostHit);
      return true;
    }

    const onYoutube = /\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""));
    for (const k of keys) {
      if (!k) continue;
      if (onYoutube && P && !P.isYoutubeBlockPattern(k)) continue;
      if (onYoutube && !P) {
        const kl = k.toLowerCase();
        if (
          !kl.includes("youtube.com") &&
          !kl.includes("youtu.be") &&
          !kl.startsWith("watch?v=") &&
          !(kl.startsWith("/") && kl.length > 2)
        ) {
          continue;
        }
      }
      if (k.includes("*") || k.includes("/")) {
        if (urlMatchesColdTurkeyPattern(href, k)) {
          showBlockOverlay(k);
          return true;
        }
      } else if (href.toLowerCase().includes(k)) {
        showBlockOverlay(k);
        return true;
      }
    }
    return false;
  }

  function hideIfMatch(text, el, keys, doms) {
    const t = (text || "").toLowerCase();
    if (keys.length) {
      for (const k of keys) {
        if (t.includes(k)) {
          P?.hideNode(el);
          return true;
        }
      }
    }
    if (doms.length && matchesBlockedDomain(t, doms)) {
      P?.hideNode(el);
      return true;
    }
    return false;
  }

  function filterSerp() {
    if (!state.protectionEnabled) return;
    if (P) {
      P.filterSerp(state);
      return;
    }
    if (!state.hideSerp) return;
    const keys = normList(state.keywords);
    const doms = normList(state.blockedDomains).map(normDomain);
    if (!keys.length && !doms.length) return;

    // Google web SERP organic results
    document
      .querySelectorAll("div.g, div[data-hveid], div[data-sokoban-container]")
      .forEach((node) => {
        const txt = node.innerText || "";
        // Also include hrefs in the search text so a result that only shows
        // the page title (with a domain in the URL) still gets caught.
        const links = node.querySelectorAll("a[href]");
        let allText = txt;
        links.forEach((a) => {
          allText += " " + (a.getAttribute("href") || "");
        });
        hideIfMatch(allText, node, keys, doms);
      });

    // DuckDuckGo
    document
      .querySelectorAll("article[data-testid='result'], .result")
      .forEach((node) => {
        const txt = node.innerText || "";
        const links = node.querySelectorAll("a[href]");
        let allText = txt;
        links.forEach((a) => {
          allText += " " + (a.getAttribute("href") || "");
        });
        hideIfMatch(allText, node, keys, doms);
      });

    // Bing
    document.querySelectorAll("li.b_algo").forEach((node) => {
      const txt = node.innerText || "";
      const links = node.querySelectorAll("a[href]");
      let allText = txt;
      links.forEach((a) => {
        allText += " " + (a.getAttribute("href") || "");
      });
      hideIfMatch(allText, node, keys, doms);
    });

    // Google Images results (dedicated image search and the inline image strip
    // on web SERP). Selectors are layout-specific but cover the common cases
    // Google has been shipping in 2025–2026.
    document
      .querySelectorAll(
        "div[data-id][jsname], div.isv-r, div.isv-r-am, div[jscontroller][data-tbnid], g-img"
      )
      .forEach((node) => {
        // For images, we have no text — match the alt/text from nested <img>
        // and the host of any link inside.
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
          node.closest("div[data-hveid]") ||
          node.closest("div.isv-r") ||
          node;
        hideIfMatch(allText, parent, keys, doms);
      });

    // Bing Images cell
    document.querySelectorAll("a.iusc, div.imgpt").forEach((node) => {
      const allText =
        (node.getAttribute("m") || "") +
        " " +
        (node.getAttribute("href") || "") +
        " " +
        (node.innerText || "");
      hideIfMatch(allText, node, keys, doms);
    });
  }

  function filterYoutubeFeed() {
    if (!state.protectionEnabled) return;
    if (P) {
      P.filterYoutube(state);
      return;
    }
    if (!/\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""))) return;
    if (state.hideYoutubeResults === false) return;
    const keys = normList(state.keywords).filter((k) => {
      const s = String(k).toLowerCase();
      return (
        s.includes("youtube.com") ||
        s.includes("youtu.be") ||
        s.startsWith("watch?v=") ||
        (s.startsWith("/") && s.length > 2)
      );
    });
    if (!keys.length) return;
    const selectors =
      "ytd-rich-item-renderer,ytd-video-renderer,ytd-grid-video-renderer," +
      "ytd-compact-video-renderer,ytd-playlist-video-renderer,ytd-reel-item-renderer," +
      "ytm-rich-item-renderer,ytm-video-with-context-renderer";
    document.querySelectorAll(selectors).forEach((node) => {
      if (node.getAttribute("data-sixvpn-blocked") === "1") return;
      let allText = node.innerText || "";
      node.querySelectorAll("a[href]").forEach((a) => {
        allText += " " + (a.getAttribute("href") || "");
      });
      node.querySelectorAll("yt-formatted-string,#video-title").forEach((el) => {
        allText += " " + (el.textContent || "");
      });
      if (hideIfMatch(allText, node, keys, [])) {
        node.setAttribute("data-sixvpn-blocked", "1");
      }
    });
  }

  function blockForbiddenSearch() {
    if (!state.protectionEnabled) return false;
    if (P) return P.blockForbiddenSearch(state);
    return false;
  }

  function hideFeeds() {
    if (!state.protectionEnabled) return;
    const h = (location.hostname || "").replace(/\.$/, "");
    const p = location.pathname || "";
    if (state.hideYtHomeFeed && /\.youtube\.com$/i.test(h)) {
      if (p === "/" || /^\/feed(\/|$)/.test(p)) {
        document
          .querySelectorAll(
            "ytd-rich-grid-renderer,ytd-rich-grid-renderer-root"
          )
          .forEach((el) => {
            P?.hideNode(el);
          });
      }
    }
    if (state.hideGoogleHomeFeed && /^www\.google\./i.test(h) && p === "/") {
      document.querySelectorAll('[role="feed"]').forEach((el) => {
        P?.hideNode(el);
      });
    }
  }

  function enforceSafeSearch() {
    if (!state.protectionEnabled) return;
    if (!state.forceSafeSearch) return;
    try {
      const h = (location.hostname || "").replace(/\.$/, "");
      const path = location.pathname || "";
      if (h.includes("google.") && (path === "/search" || path === "/images")) {
        const u = new URL(location.href);
        const cur = (u.searchParams.get("safe") || "").toLowerCase();
        if (cur !== "active" && cur !== "strict") {
          u.searchParams.set("safe", "active");
          location.replace(u.toString());
          return;
        }
      }
      if (h.startsWith("images.google.")) {
        const u = new URL(location.href);
        const cur = (u.searchParams.get("safe") || "").toLowerCase();
        if (cur !== "active" && cur !== "strict") {
          u.searchParams.set("safe", "active");
          location.replace(u.toString());
          return;
        }
      }
      if (/\.bing\.com$/i.test(h) && /^\/(search|images)/.test(path)) {
        const u = new URL(location.href);
        if (u.searchParams.get("adlt") !== "strict") {
          u.searchParams.set("adlt", "strict");
          location.replace(u.toString());
        }
      }
      if (/(^|\.)duckduckgo\.com$/i.test(h)) {
        const u = new URL(location.href);
        // DDG uses kp=1 for strict; -2 = off, -1 = moderate
        if (u.searchParams.get("kp") !== "1") {
          u.searchParams.set("kp", "1");
          location.replace(u.toString());
        }
      }
    } catch (_) {}
  }

  function applyAll() {
    void applyAllAsync();
  }

  function reportBlock(rule, kind) {
    try {
      fetch(`${rulesBase}/block`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          rule: String(rule || ""),
          kind: kind || "navigation",
          url: location.href,
          browser: BROWSER_TAG,
        }),
      }).catch(() => {});
    } catch (_) {}
  }

  function applyRulesData(data) {
    if (!data) return;
    if (P) P.applyRulesPayload(state, data);
    else {
      if (Array.isArray(data.blockedDomains) && data.blockedDomains.length) {
        state.blockedDomains = data.blockedDomains;
      }
      if (Array.isArray(data.keywords)) state.keywords = data.keywords;
    }
  }

  function pullRulesFromApp(done) {
    (async () => {
      for (const port of RULES_PORTS) {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 1800);
        try {
          const res = await fetch(`http://127.0.0.1:${port}/rules`, {
            cache: "no-store",
            signal: ctrl.signal,
          });
          clearTimeout(timer);
          if (!res.ok) continue;
          const data = await res.json();
          rulesBase = `http://127.0.0.1:${port}`;
          applyRulesData(data);
          return;
        } catch {
          /* next port */
        } finally {
          clearTimeout(timer);
        }
      }
      try {
        const cached = await chrome.storage.local.get(["sixvpn_rules_snapshot"]);
        applyRulesData(cached.sixvpn_rules_snapshot);
      } catch (_) {}
      try {
        const res = await fetch(chrome.runtime.getURL("rules_snapshot.json"), {
          cache: "no-store",
        });
        if (res.ok) applyRulesData(await res.json());
      } catch (_) {}
    })().finally(() => {
      if (typeof done === "function") done();
    });
  }

  let booted = false;
  function boot() {
    if (booted) return;
    booted = true;
      pull(() => {
      void applyAllAsync();
      let moPending = false;
      const mo = new MutationObserver((records) => {
        // A one-second budget countdown changes only its own notice text.
        // Other page mutations must still reach the blocking/filter pipeline.
        if (records?.length && records.every(record => {
          const target = record.target?.nodeType === 1 ? record.target : record.target?.parentElement;
          return !!target?.closest?.('[data-focusfense-budget-notice]');
        })) return;
        if (moPending) return;
        moPending = true;
        requestAnimationFrame(() => {
          moPending = false;
          if (blockNavigationIfNeeded()) return;
          void blockViaAppChannelCheck();
          void blockViaAppYoutubeCheck(false);
          blockForbiddenSearch();
          filterSerp();
          filterYoutubeFeed();
          hideFeeds();
        });
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
      const ytTickMs =
        /\/watch|\/shorts|\/results|\/feed/.test(location.pathname || "")
          ? 400
          : 1200;
      setInterval(() => {
        if (/\.youtube\.com$/i.test((location.hostname || "").replace(/\.$/, ""))) {
          if (blockNavigationIfNeeded()) return;
          void blockViaAppChannelCheck();
          void blockViaAppYoutubeCheck(false);
          filterYoutubeFeed();
        }
      }, ytTickMs);
    });
  }

  pullRulesFromApp(boot);
  setInterval(() => pullRulesFromApp(applyAll), RULES_PULL_MS);

  let lastHref = location.href;
  setInterval(() => {
    if (location.href !== lastHref) {
      lastHref = location.href;
      if (isYoutubeWatchPage()) setYoutubePending(true);
      if (blockNavigationIfNeeded()) return;
      void blockViaAppChannelCheck();
      void blockViaAppYoutubeCheck(true);
    }
  }, 400);

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !Object.keys(changes).some(key => key in state)) return;
    pull(applyAll);
  });

  setInterval(enforceSafeSearch, 1200);

  const USAGE_INGEST_MS = 20000;
  const USAGE_INGEST_URL = () => `${rulesBase}/ingest`;

  function mediaPlayingInBackground() {
    const el = document.querySelector("video,audio");
    return (
      el &&
      !el.paused &&
      !el.ended &&
      document.visibilityState !== "visible"
    );
  }

  function usagePhase() {
    if (document.visibilityState === "visible") return "foreground";
    if (mediaPlayingInBackground()) return "background";
    return null;
  }

  function postUsageTick() {
    // Accounting exemption only; navigation/site/channel enforcement is separate.
    if (globalThis.FocusFenseYoutubeBudgetCurrentExemption?.()) return;
    const phase = usagePhase();
    if (!phase) return;
    const host = String((location.hostname || "").replace(/\.$/, ""))
      .trim()
      .toLowerCase();
    if (!host || host === "localhost" || host === "127.0.0.1") return;
    const seconds = Math.min(
      120,
      Math.max(1, Math.round(USAGE_INGEST_MS / 1000))
    );
    fetch(USAGE_INGEST_URL(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host, seconds, phase, documentUrl: location.href, youtubeBudgetMetadata: globalThis.FocusFenseYoutubeBudgetCurrentMetadata?.() }),
      mode: "cors",
    }).catch(() => {});
  }

  setInterval(postUsageTick, USAGE_INGEST_MS);
  document.addEventListener("visibilitychange", () => postUsageTick());

  /**
   * Nightly foreground-only quota (e.g. YouTube Music 23:00–11:00, 15분/시간).
   * Only blocks the *visible* tab/window — background/minimized playback is
   * never affected, since the app's enforcer never DNS-blocks this host for
   * this quota mode. Polled independently of the usage-ingest tick above.
   */
  const FG_LOCK_POLL_MS = 5000;

  function showFgLockOverlay() {
    if (document.getElementById("sixvpn-fg-quota-overlay")) return;
    try {
      document.querySelectorAll("video,audio").forEach((m) => m.pause());
    } catch (_) {}
    const el = document.createElement("div");
    el.id = "sixvpn-fg-quota-overlay";
    el.setAttribute("role", "alertdialog");
    el.style.cssText =
      "position:fixed;inset:0;z-index:2147483647;background:#12121c;color:#f5f5f7;" +
      "display:flex;flex-direction:column;align-items:center;justify-content:center;" +
      "font:16px system-ui,-apple-system,sans-serif;padding:32px;text-align:center;box-sizing:border-box";
    el.innerHTML =
      '<div style="max-width:420px">' +
      '<h2 style="margin:0 0 12px;font-size:22px;font-weight:700">FocusFense</h2>' +
      '<p style="margin:0 0 8px;line-height:1.5;opacity:.92">이번 시간 화면 시청 한도(15분)를 다 썼습니다.</p>' +
      '<p style="margin:0;font-size:13px;opacity:.65">백그라운드에서는 계속 재생할 수 있어요. 다음 정시에 다시 열립니다.</p>' +
      "</div>";
    document.documentElement.appendChild(el);
  }

  function hideFgLockOverlay() {
    const el = document.getElementById("sixvpn-fg-quota-overlay");
    if (el) el.remove();
  }

  async function pollFgLockStatus() {
    if (globalThis.FocusFenseYoutubeBudgetCurrentExemption?.()) { hideFgLockOverlay(); return; }
    if (document.visibilityState !== "visible") {
      hideFgLockOverlay();
      return;
    }
    const host = String((location.hostname || "").replace(/\.$/, "")).trim().toLowerCase();
    if (!host) return;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 3000);
    try {
      const res = await fetch(
        `${rulesBase}/usage/lock-status?host=${encodeURIComponent(host)}`,
        { cache: "no-store", signal: ctrl.signal }
      );
      clearTimeout(timer);
      if (!res.ok) return;
      const data = await res.json();
      if (data && data.locked && !globalThis.FocusFenseYoutubeBudgetCurrentExemption?.()) showFgLockOverlay();
      else hideFgLockOverlay();
    } catch (_) {
      /* app not reachable — don't block on a transient failure */
    } finally {
      clearTimeout(timer);
    }
  }

  setInterval(pollFgLockStatus, FG_LOCK_POLL_MS);
  document.addEventListener("visibilitychange", pollFgLockStatus);
})();
