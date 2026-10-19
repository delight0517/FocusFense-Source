const DEFAULT_BLOCKED_DOMAINS = [];

const DEFAULTS = {
  hideImages: false,
  hideSerp: false,
  keywords: [],
  blockedDomains: DEFAULT_BLOCKED_DOMAINS,
  hideYtHomeFeed: false,
  hideImagesOnYoutube: false,
  hideGoogleHomeFeed: false,
  forceSafeSearch: false,
};

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

const RULES_PORTS = [17361, 17362, 17363, 17364, 17365, 17366, 17367, 17368, 17369, 17370, 17371, 17372];

function checkFocusLocked(cb) {
  (async () => {
    for (const port of RULES_PORTS) {
      try {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 2500);
        const res = await fetch(`http://127.0.0.1:${port}/rules`, {
          cache: "no-store",
          signal: ctrl.signal,
        });
        clearTimeout(timer);
        if (!res.ok) continue;
        const data = await res.json();
        cb(!!(data && data.focusLocked));
        return;
      } catch (_) {
        /* next port, or app isn't running */
      }
    }
    cb(false);
  })();
}

let ytLocked = false;

function applyLockUi(locked) {
  ytLocked = locked;
  const notice = document.getElementById("ytLockNotice");
  if (notice) {
    notice.style.display = locked ? "block" : "none";
    notice.textContent = locked
      ? "지금은 잠금 스케줄 시간대입니다 — YouTube 집중 모드는 엄격 프리셋으로 강제 적용되며 여기서 바꿀 수 없습니다."
      : "";
  }
  const row = document.getElementById("ytDistractionRow");
  if (row) {
    row.querySelectorAll("input[type=checkbox]").forEach((el) => {
      el.disabled = locked;
      // Reflect what's actually being enforced right now, not the (frozen)
      // saved preference — otherwise the page looks like nothing is on
      // while the content script is actually forcing everything.
      if (locked) el.checked = true;
    });
  }
}

function formatYtHandles(handles) {
  return (handles || [])
    .map((h) => {
      const s = String(h || "").trim();
      if (!s) return "";
      return s.startsWith("@") ? s : `@${s}`;
    })
    .filter(Boolean)
    .join("\n");
}

function load() {
  chrome.storage.sync.get(
    {
      ...DEFAULTS,
      blockedYoutubeHandles: [],
      blockedYoutubeChannelIds: [],
      blockedYoutubeVideoIds: [],
      ytDistraction: DEFAULT_YT_DISTRACTION,
    },
    (cfg) => {
      document.getElementById("hideImages").checked = !!cfg.hideImages;
      document.getElementById("hideSerp").checked = !!cfg.hideSerp;
      document.getElementById("hideYtHomeFeed").checked = !!cfg.hideYtHomeFeed;
      const ytImg = document.getElementById("hideImagesOnYoutube");
      if (ytImg) ytImg.checked = !!cfg.hideImagesOnYoutube;
      document.getElementById("hideGoogleHomeFeed").checked =
        !!cfg.hideGoogleHomeFeed;
      document.getElementById("forceSafeSearch").checked = !!cfg.forceSafeSearch;
      document.getElementById("kw").value = (cfg.keywords || []).join("\n");
      document.getElementById("dom").value = (
        cfg.blockedDomains || DEFAULT_BLOCKED_DOMAINS
      ).join("\n");
      const ytEl = document.getElementById("ytHandles");
      if (ytEl) {
        ytEl.value = formatYtHandles(cfg.blockedYoutubeHandles);
      }
      const ytd = { ...DEFAULT_YT_DISTRACTION, ...(cfg.ytDistraction || {}) };
      for (const key of Object.keys(DEFAULT_YT_DISTRACTION)) {
        const el = document.getElementById("yt_" + key);
        if (el) el.checked = !!ytd[key];
      }
      checkFocusLocked(applyLockUi);
    }
  );
}

document.getElementById("save").addEventListener("click", () => {
  const hideImages = document.getElementById("hideImages").checked;
  const hideSerp = document.getElementById("hideSerp").checked;
  const hideYtHomeFeed = document.getElementById("hideYtHomeFeed").checked;
  const hideImagesOnYoutube = document.getElementById("hideImagesOnYoutube")
    ? document.getElementById("hideImagesOnYoutube").checked
    : false;
  const hideGoogleHomeFeed = document.getElementById(
    "hideGoogleHomeFeed"
  ).checked;
  const forceSafeSearch = document.getElementById("forceSafeSearch").checked;
  const rawKw = document.getElementById("kw").value || "";
  const keywords = rawKw
    .split(/\r?\n/)
    .map((s) => s.trim())
    .filter(Boolean);
  const rawDom = document.getElementById("dom").value || "";
  const blockedDomains = rawDom
    .split(/\r?\n/)
    .map((s) => s.trim().toLowerCase().replace(/^www\./, ""))
    .filter(Boolean);
  const toSave = {
    hideImages,
    hideSerp,
    hideYtHomeFeed,
    hideImagesOnYoutube,
    hideGoogleHomeFeed,
    forceSafeSearch,
    keywords,
    blockedDomains,
  };
  // While a lock schedule is active, the checkboxes above show the forced
  // strict preset (not the user's real saved preference) — never persist
  // that, or we'd permanently overwrite their preference just because they
  // opened this page during a locked window.
  if (!ytLocked) {
    const ytDistraction = {};
    for (const key of Object.keys(DEFAULT_YT_DISTRACTION)) {
      const el = document.getElementById("yt_" + key);
      ytDistraction[key] = el ? !!el.checked : DEFAULT_YT_DISTRACTION[key];
    }
    toSave.ytDistraction = ytDistraction;
  }
  chrome.storage.sync.set(
    toSave,
    () => {
      const el = document.getElementById("msg");
      el.textContent = "저장됨 — 탭을 새로고침하세요.";
      setTimeout(() => (el.textContent = ""), 2500);
    }
  );
});

load();
