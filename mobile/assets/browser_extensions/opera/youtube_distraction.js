/**
 * YouTube 집중 모드 (distraction-free YouTube) — hides comments, sidebars,
 * end-screen suggestions, mixes, notifications, etc. based on user-chosen
 * toggles saved in chrome.storage.sync under "ytDistraction".
 *
 * Independent of the domain/keyword block pipeline in content.js /
 * precision_strike.js — this only ever hides YouTube chrome, never blocks
 * navigation, so it cannot trip the block-overlay / block-activity-log path.
 */
(() => {
  if (!/(^|\.)youtube\.com$/i.test((location.hostname || "").replace(/\.$/, "")) && !/(^|\.)youtu\.be$/i.test((location.hostname || "").replace(/\.$/, ""))) {
    return;
  }

  const STYLE_ID = "sixvpn-yt-distraction-style";

  const DEFAULT_YT_DISTRACTION = {
    blockShorts: false,
    hideHomeFeed: false,
    redirectHomeToSubscriptions: false,
    hideVideoSidebar: false,
    hideSidebarRecommended: false,
    hideSidebarLiveChat: false,
    hideSidebarPlaylist: false,
    hideSidebarFundraiser: false,
    hideEndScreenFeed: false,
    hideEndScreenCards: false,
    hideComments: false,
    hideMixes: false,
    hideMerchTicketsOffers: false,
    hideExploreTrending: false,
    hideNotifications: false,
    hideTopHeader: false,
    hideVideoInfo: false,
    hideSubscriptions: false,
    disableAutoplay: false,
    disableAnnotations: false,
  };

  // Each entry: one or more CSS selectors hidden with !important while the
  // matching toggle is on. Pure-CSS only — no navigation is ever blocked here.
  const CSS_RULES = {
    hideHomeFeed:
      'ytd-browse[page-subtype="home"] ytd-rich-grid-renderer,' +
      'ytd-browse[page-subtype="home"] #contents.ytd-two-column-browse-results-renderer',
    hideVideoSidebar: "#secondary.ytd-watch-flexy, #secondary-inner",
    hideSidebarRecommended:
      "ytd-watch-next-secondary-results-renderer, #related",
    hideSidebarLiveChat: "#chat, #chat-container, ytd-live-chat-frame",
    hideSidebarPlaylist: "ytd-playlist-panel-renderer",
    hideSidebarFundraiser:
      "ytd-donation-shelf-renderer, #donation-shelf",
    hideEndScreenFeed:
      ".html5-endscreen.ytp-player-content, .ytp-endscreen-content",
    hideEndScreenCards: ".ytp-ce-element",
    hideComments: "ytd-comments#comments, #comments",
    hideMixes: "ytd-radio-renderer, ytd-compact-radio-renderer",
    hideMerchTicketsOffers:
      "ytd-merch-shelf-renderer, ytd-ticket-shelf-renderer, ytd-offer-module-renderer, #ticket-shelf",
    hideNotifications:
      "ytd-notification-topbar-button-renderer, #notification-count",
    hideTopHeader: "#masthead-container, ytd-masthead#masthead",
    hideVideoInfo: "#above-the-fold, ytd-watch-metadata",
    disableAnnotations: ".ytp-ce-element, .annotation, .iv-branding",
  };

  // Shorts shelves (home/subscriptions feeds) — separate from the /shorts/
  // path redirect below, since blockShorts also removes the promo shelves.
  const SHORTS_SHELF_SELECTOR =
    "ytd-reel-shelf-renderer, ytd-rich-shelf-renderer[is-shorts], ytd-reel-item-renderer";

  const GUIDE_LABELS = {
    hideExploreTrending: ["탐색", "인기 급상승", "explore", "trending"],
    hideSubscriptions: ["구독", "subscriptions"],
  };

  // Forced during the app's lock-schedule window (see LockPolicyService /
  // lock_schedule_enforcement.dart on the Dart side) — every toggle on, no
  // exceptions. This is intentionally hardcoded, not user-editable: the whole
  // point of a lock schedule is that the in-the-moment self can't loosen it.
  const STRICT_LOCKED_PRESET = {
    blockShorts: true,
    hideHomeFeed: true,
    redirectHomeToSubscriptions: true,
    hideVideoSidebar: true,
    hideSidebarRecommended: true,
    hideSidebarLiveChat: true,
    hideSidebarPlaylist: true,
    hideSidebarFundraiser: true,
    hideEndScreenFeed: true,
    hideEndScreenCards: true,
    hideComments: true,
    hideMixes: true,
    hideMerchTicketsOffers: true,
    hideExploreTrending: true,
    hideNotifications: true,
    hideTopHeader: true,
    hideVideoInfo: true,
    hideSubscriptions: true,
    disableAutoplay: true,
    disableAnnotations: true,
  };

  // Local Dart app's loopback rules server — same port span content.js /
  // precision_strike.js already poll. Only used here to read the single
  // `focusLocked` boolean; the actual block rules are handled elsewhere.
  const RULES_PORTS = [17361, 17362, 17363, 17364, 17365, 17366, 17367, 17368, 17369, 17370, 17371, 17372];
  const FOCUS_LOCK_POLL_MS = 5000;
  let focusLocked = false;

  let state = { ...DEFAULT_YT_DISTRACTION };

  function effectiveState() {
    return focusLocked ? { ...state, ...STRICT_LOCKED_PRESET } : state;
  }

  function buildCSS() {
    const eff = effectiveState();
    const blocks = [];
    for (const key of Object.keys(CSS_RULES)) {
      if (eff[key]) {
        blocks.push(CSS_RULES[key] + "{display:none!important;}");
      }
    }
    if (eff.blockShorts) {
      blocks.push(SHORTS_SHELF_SELECTOR + "{display:none!important;}");
    }
    return blocks.join("\n");
  }

  function applyCSS() {
    let styleEl = document.getElementById(STYLE_ID);
    const css = buildCSS();
    if (!css) {
      if (styleEl) styleEl.textContent = "";
      return;
    }
    if (!styleEl) {
      styleEl = document.createElement("style");
      styleEl.id = STYLE_ID;
      (document.head || document.documentElement).appendChild(styleEl);
    }
    styleEl.textContent = css;
  }

  function hideGuideEntriesByLabel(labels) {
    if (!labels || !labels.length) return;
    const nodes = document.querySelectorAll(
      "ytd-guide-entry-renderer, ytd-mini-guide-entry-renderer"
    );
    nodes.forEach((node) => {
      if (node.getAttribute("data-sixvpn-yt-guide-checked") === "1") return;
      const text = (
        node.getAttribute("aria-label") ||
        node.getAttribute("title") ||
        node.innerText ||
        ""
      ).toLowerCase();
      if (!text) return;
      for (const label of labels) {
        if (text.includes(label)) {
          node.style.setProperty("display", "none", "important");
          node.setAttribute("data-sixvpn-yt-guide-checked", "1");
          return;
        }
      }
    });
  }

  function applyGuideFiltering() {
    const eff = effectiveState();
    if (eff.hideExploreTrending) {
      hideGuideEntriesByLabel(GUIDE_LABELS.hideExploreTrending);
    }
    if (eff.hideSubscriptions) {
      hideGuideEntriesByLabel(GUIDE_LABELS.hideSubscriptions);
    }
  }

  function enforceAutoplayOff() {
    if (!effectiveState().disableAutoplay) return;
    try {
      const toggle = document.querySelector(
        ".ytp-autonav-toggle-button[aria-checked='true'], #toggle[aria-checked='true'].ytp-autonav-toggle-button"
      );
      if (toggle) toggle.click();
    } catch (_) {}
  }

  function redirectIfNeeded() {
    const eff = effectiveState();
    const path = location.pathname || "";
    if (eff.blockShorts && /^\/shorts\//i.test(path)) {
      location.replace("https://www.youtube.com/");
      return true;
    }
    if (
      !eff.hideHomeFeed &&
      eff.redirectHomeToSubscriptions &&
      (path === "/" || path === "")
    ) {
      location.replace("https://www.youtube.com/feed/subscriptions");
      return true;
    }
    return false;
  }

  function pollFocusLocked() {
    (async () => {
      for (const port of RULES_PORTS) {
        try {
          const ctrl = new AbortController();
          const timer = setTimeout(() => ctrl.abort(), 3000);
          const res = await fetch(`http://127.0.0.1:${port}/rules`, {
            cache: "no-store",
            signal: ctrl.signal,
          });
          clearTimeout(timer);
          if (!res.ok) continue;
          const data = await res.json();
          const next = !!(data && data.focusLocked);
          if (next !== focusLocked) {
            focusLocked = next;
            applyAll();
          }
          return;
        } catch (_) {
          /* next port, or app isn't running — leave focusLocked as-is */
        }
      }
    })();
  }

  function applyAll() {
    if (redirectIfNeeded()) return;
    applyCSS();
    applyGuideFiltering();
    enforceAutoplayOff();
  }

  function load(cb) {
    try {
      chrome.storage.sync.get(
        { ytDistraction: DEFAULT_YT_DISTRACTION },
        (cfg) => {
          state = { ...DEFAULT_YT_DISTRACTION, ...(cfg.ytDistraction || {}) };
          if (typeof cb === "function") cb();
        }
      );
    } catch (_) {
      if (typeof cb === "function") cb();
    }
  }

  function boot() {
    applyAll();
    let pending = false;
    const mo = new MutationObserver(() => {
      if (pending) return;
      pending = true;
      requestAnimationFrame(() => {
        pending = false;
        applyAll();
      });
    });
    mo.observe(document.documentElement, { childList: true, subtree: true });

    let lastHref = location.href;
    setInterval(() => {
      if (location.href !== lastHref) {
        lastHref = location.href;
        applyAll();
      }
    }, 500);
  }

  load(boot);
  pollFocusLocked();
  setInterval(pollFocusLocked, FOCUS_LOCK_POLL_MS);

  try {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== "sync" || !changes.ytDistraction) return;
      load(applyAll);
    });
  } catch (_) {}
})();
