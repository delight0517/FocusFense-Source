/**
 * Same live rule sync as Chrome — Firefox 109+ declarativeNetRequest.
 */
let RULES_URL = "http://127.0.0.1:17361/rules?browser=firefox";
let SCHEDULES_URL = "http://127.0.0.1:17361/schedules/list";
let ADD_RULE_URL = "http://127.0.0.1:17361/add-rule";
const SYNC_MS = 5000;
const RULES_FETCH_TIMEOUT_MS = 1800;
const MENU_SYNC_MS = 60000;
let activeAppPort=17361;
async function fetchRules() {
 for(const port of [...new Set([activeAppPort,...Array.from({length:12},(_,i)=>17361+i)])]){
  const ctrl=new AbortController();const timer=setTimeout(()=>ctrl.abort(),RULES_FETCH_TIMEOUT_MS);
  try{
   const base=`http://127.0.0.1:${port}`;
   const response=await fetch(`${base}/rules?browser=firefox`,{cache:'no-store',signal:ctrl.signal});
   if(!response.ok)continue;
   const data=await response.json();activeAppPort=port;
   RULES_URL=`${base}/rules?browser=firefox`;SCHEDULES_URL=`${base}/schedules/list`;ADD_RULE_URL=`${base}/add-rule`;
   return data;
  }catch{}finally{clearTimeout(timer);}
 }
 return null;
}

function domainToRule(host, id) {
  const d = String(host || "")
    .trim()
    .toLowerCase()
    .replace(/^www\./, "");
  if (!d || d.includes(" ")) return null;
  return {
    id,
    priority: 1,
    action: { type: "block" },
    condition: {
      urlFilter: `||${d}^`,
      resourceTypes: ["main_frame", "sub_frame"],
    },
  };
}

function regexEscape(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function extractYoutubeHandles(keywords) {
  const handles = new Set();
  for (const raw of keywords || []) {
    const k = String(raw || "").trim().toLowerCase();
    if (!k) continue;
    let m = k.match(/youtube\.com\/@([^/?#\s]+)/);
    if (m) {
      handles.add(decodeURIComponent(m[1]));
      continue;
    }
    m = k.match(/youtube\.com\/c\/([^/?#\s]+)/);
    if (m) {
      handles.add(decodeURIComponent(m[1]));
      continue;
    }
    if (k.startsWith("@") && !k.includes("/")) {
      handles.add(k.slice(1));
      continue;
    }
    if (k.startsWith("/@")) {
      handles.add(k.slice(2).split("/")[0]);
    }
  }
  return [...handles];
}

function extractYoutubeChannelRules(keywords) {
  const rules = [];
  const seen = new Set();
  const add = (urlFilter) => {
    const f = encodeURI(String(urlFilter || "").trim());
    if (!f || seen.has(f)) return;
    seen.add(f);
    rules.push(f);
  };

  for (const raw of keywords || []) {
    const k = String(raw || "").trim().toLowerCase();
    if (!k) continue;
    let m = k.match(/youtube\.com\/@([^/?#\s]+)/);
    if (m) {
      const h = decodeURIComponent(m[1]);
      add(`||youtube.com/@${h}^`);
      add(`||youtube.com/c/${h}^`);
      continue;
    }
    m = k.match(/youtube\.com\/c\/([^/?#\s]+)/);
    if (m) {
      const h = decodeURIComponent(m[1]);
      add(`||youtube.com/c/${h}^`);
      add(`||youtube.com/@${h}^`);
      continue;
    }
    m = k.match(/youtube\.com\/(?:user\/)?([^/?#\s@]+)$/);
    if (m && m[1] !== "watch" && m[1] !== "shorts" && m[1] !== "feed") {
      add(`||youtube.com/${m[1]}^`);
      add(`||youtube.com/c/${m[1]}^`);
      add(`||youtube.com/@${m[1]}^`);
    }
    if (k.startsWith("/@")) add(`||youtube.com${k}^`);
    else if (k.startsWith("@")) add(`||youtube.com/${k}^`);
    else if (k.startsWith("/c/")) add(`||youtube.com${k}^`);
    else if (k.startsWith("/") && k.length > 2 && !k.includes("*")) {
      add(`||youtube.com${k}^`);
      add(`||youtube.com/@${k.slice(1)}^`);
    }
  }
  return rules;
}

function youtubeHandleRegexRule(handle, id) {
  const h = regexEscape(encodeURIComponent(handle));
  return {
    id,
    priority: 20,
    action: { type: "block" },
    condition: {
      regexFilter: `^https?:\\/\\/(www\\.|m\\.)?youtube\\.com\\/(?:@${h}|c\\/${h})(?:\\/|$|\\?)`,
      resourceTypes: ["main_frame", "sub_frame"],
    },
  };
}

function extractYoutubeVideoIds(keywords) {
  const ids = new Set();
  for (const raw of keywords || []) {
    const k = String(raw || "").trim();
    if (!k) continue;
    let m = k.match(/(?:^|[?&]v=)([\w-]{6,})/i);
    if (m) ids.add(m[1].toLowerCase());
    m = k.match(/youtu\.be\/([\w-]{6,})/i);
    if (m) ids.add(m[1].toLowerCase());
    m = k.match(/\/shorts\/([\w-]{6,})/i);
    if (m) ids.add(m[1].toLowerCase());
  }
  return [...ids];
}

function youtubeWatchRule(videoId, id) {
  const v = regexEscape(videoId);
  return {
    id,
    priority: 25,
    action: { type: "block" },
    condition: {
      regexFilter:
        `^https?:\\/\\/(www\\.|m\\.)?youtube\\.com\\/watch\\?(?:[^#]*&)?v=${v}(?:&|$|#)`,
      resourceTypes: ["main_frame", "sub_frame"],
    },
  };
}

function youtubeShortsRule(videoId, id) {
  const v = regexEscape(videoId);
  return {
    id,
    priority: 25,
    action: { type: "block" },
    condition: {
      regexFilter: `^https?:\\/\\/(www\\.|m\\.)?youtube\\.com\\/shorts\\/${v}(?:\\/|$|\\?)`,
      resourceTypes: ["main_frame", "sub_frame"],
    },
  };
}

function mergeVideoIds(keywords, explicitIds) {
  const ids = new Set(extractYoutubeVideoIds(keywords));
  for (const raw of explicitIds || []) {
    const v = String(raw || "").trim().toLowerCase();
    if (v.length >= 6) ids.add(v);
  }
  return [...ids];
}

async function applyDynamicRules(domains, keywords, explicitVideoIds) {
  const rules = [];
  let id = 1;
  for (const h of domains || []) {
    const d = String(h || "")
      .trim()
      .toLowerCase()
      .replace(/^www\./, "");
    if (!d || d.includes(" ")) continue;
    if (d === "youtube.com" || d === "youtu.be") continue;
    const r = domainToRule(h, id++);
    if (r) rules.push(r);
    if (id > 4800) break;
  }
  for (const filter of extractYoutubeChannelRules(keywords)) {
    rules.push({
      id: id++,
      priority: 2,
      action: { type: "block" },
      condition: {
        urlFilter: filter,
        resourceTypes: ["main_frame", "sub_frame"],
      },
    });
    if (id > 4800) break;
  }
  for (const handle of extractYoutubeHandles(keywords)) {
    rules.push(youtubeHandleRegexRule(handle, id++));
    if (id > 4800) break;
  }
  for (const vid of mergeVideoIds(keywords, explicitVideoIds)) {
    rules.push(youtubeWatchRule(vid, id++));
    rules.push(youtubeShortsRule(vid, id++));
    rules.push({
      id: id++,
      priority: 25,
      action: { type: "block" },
      condition: {
        urlFilter: `||youtu.be/${vid}^`,
        resourceTypes: ["main_frame", "sub_frame"],
      },
    });
    if (id > 4800) break;
  }
  // Per-channel/video rules must not block the shared YouTube media CDN.
  const existing = await chrome.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = existing.map((r) => r.id);
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds,
    addRules: rules,
  });
}

let appSyncInFlight;
function syncFromApp() {
  return appSyncInFlight ||= syncFromAppOnce().finally(() => {appSyncInFlight=null;});
}
async function syncFromAppOnce() {
  await globalThis.ffFirefoxLocalStorageReady;
  let data = await fetchRules();
  if (!data) return;
  if (data.protectionEnabled === false) data = {
    ...data,
    blockedDomains: [], keywords: [], blockedYoutubeHandles: [],
    keywordRules: [], blockedYoutubeChannelIds: [], blockedYoutubeVideoIds: [],
    searchQueries: [], hideSerp: false, hideYoutubeResults: false,
    hideYtHomeFeed: false, precisionContentFilter: false,
    hideImages: false, hideGoogleHomeFeed: false, forceSafeSearch: false,
    focusLocked: false,
  };
  await applyDynamicRules(
    data.blockedDomains || [],
    data.keywords || [],
    data.blockedYoutubeVideoIds || [],
  );
  await chrome.storage.local.set({
    youtubeBudgetExemptions: Array.isArray(data.youtubeBudgetExemptions) ? data.youtubeBudgetExemptions : [],
    focusfenseLocale: ['en','ja','zh','ko','he','ar'].includes(data.focusfenseLocale) ? data.focusfenseLocale : 'en',
    protectionEnabled: data.protectionEnabled !== false,
    keywords: data.keywords || [],
    blockedDomains: data.blockedDomains || [],
    blockedYoutubeHandles: data.blockedYoutubeHandles || [],
    blockedYoutubeChannelIds: data.blockedYoutubeChannelIds || [],
    blockedYoutubeVideoIds: data.blockedYoutubeVideoIds || [],
    searchQueries: data.searchQueries || [],
    hideSerp: data.hideSerp !== false,
    hideYoutubeResults: data.hideYoutubeResults !== false,
    hideYtHomeFeed: data.hideYtHomeFeed === true,
    precisionContentFilter: data.precisionContentFilter !== false,
  });
  await chrome.storage.local.set({
    sixvpn_rules_snapshot: data,
    sixvpn_rules_at: Date.now(),
  });
}

chrome.runtime.onStartup.addListener(() => {
  syncFromApp();
});
chrome.runtime.onInstalled.addListener(() => {
  syncFromApp();
});
setInterval(syncFromApp, SYNC_MS);
syncFromApp();

// ── "차단 목록에 추가" context menu ─────────────────────────────────
// Lets the user right-click a page/link and add its site or YouTube
// channel straight into an existing schedule (or "always block"),
// instead of switching to the app and typing it in by hand.

const MENU_ROOT = "sixvpn-root";
const MENU_ADD_SITE = "sixvpn-add-site";
const MENU_ADD_YT = "sixvpn-add-yt";
const MENU_ALWAYS_SUFFIX = "always";

async function fetchSchedules() {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), RULES_FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(SCHEDULES_URL, { cache: "no-store", signal: ctrl.signal });
    if (!res.ok) return [];
    const data = await res.json();
    return Array.isArray(data && data.schedules) ? data.schedules : [];
  } catch {
    return [];
  } finally {
    clearTimeout(timer);
  }
}

function hostnameFromUrl(url) {
  try {
    return new URL(url).hostname.replace(/\.$/, "").replace(/^www\./, "").toLowerCase();
  } catch {
    return null;
  }
}

function youtubeHandleFromUrl(url) {
  try {
    const u = new URL(url);
    if (!/(^|\.)youtube\.com$/.test(u.hostname.toLowerCase())) return null;
    let m = u.pathname.match(/^\/@([^/?#]+)/);
    if (m) return `@${decodeURIComponent(m[1])}`;
    m = u.pathname.match(/^\/c\/([^/?#]+)/);
    if (m) return decodeURIComponent(m[1]);
    m = u.pathname.match(/^\/channel\/([^/?#]+)/);
    if (m) return decodeURIComponent(m[1]);
    return null;
  } catch {
    return null;
  }
}

async function rebuildContextMenus() {
  const schedules = await fetchSchedules();
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({
    id: MENU_ROOT,
    title: "FocusFense 차단에 추가",
    contexts: ["page", "link"],
  });
  chrome.contextMenus.create({
    id: MENU_ADD_SITE,
    parentId: MENU_ROOT,
    title: "이 사이트 차단하기",
    contexts: ["page", "link"],
  });
  chrome.contextMenus.create({
    id: MENU_ADD_YT,
    parentId: MENU_ROOT,
    title: "이 유튜브 채널 차단하기",
    contexts: ["page", "link"],
    documentUrlPatterns: ["*://*.youtube.com/*"],
    targetUrlPatterns: ["*://*.youtube.com/*"],
  });
  for (const group of [MENU_ADD_SITE, MENU_ADD_YT]) {
    for (const s of schedules) {
      if (!s || !s.id) continue;
      chrome.contextMenus.create({
        id: `${group}:${s.id}`,
        parentId: group,
        title: String(s.name || s.id),
        contexts: ["page", "link"],
      });
    }
    chrome.contextMenus.create({
      id: `${group}:${MENU_ALWAYS_SUFFIX}`,
      parentId: group,
      title: "즉시 차단 (스케줄 없음, 항상 적용)",
      contexts: ["page", "link"],
    });
  }
}

function showPageToast(tabId, message, ok) {
  try {
    chrome.scripting.executeScript({
      target: { tabId },
      func: (msg, isOk) => {
        const el = document.createElement("div");
        el.textContent = msg;
        el.style.cssText =
          "position:fixed;top:16px;right:16px;z-index:2147483647;" +
          "background:" + (isOk ? "#1b8a3a" : "#b3261e") + ";color:#fff;" +
          "padding:10px 14px;border-radius:8px;font:14px/1.4 sans-serif;" +
          "box-shadow:0 2px 8px rgba(0,0,0,.3);";
        document.documentElement.appendChild(el);
        setTimeout(() => el.remove(), 3000);
      },
      args: [message, ok],
    });
  } catch {
    // Best-effort only; some pages (e.g. about: pages) disallow injection.
  }
}

async function submitAddRule(type, value, scheduleId, tabId) {
  try {
    const res = await fetch(ADD_RULE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type, value, scheduleId }),
    });
    const data = await res.json().catch(() => null);
    if (res.ok && data && data.ok) {
      showPageToast(tabId, `FocusFense: 차단 목록에 추가됨 — ${value}`, true);
    } else {
      showPageToast(tabId, "FocusFense: 추가 실패 (앱 실행 중인지 확인)", false);
    }
  } catch {
    showPageToast(tabId, "FocusFense: 앱에 연결할 수 없습니다", false);
  }
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const id = String(info.menuItemId || "");
  const [group, scheduleKey] = id.split(":");
  if (group !== MENU_ADD_SITE && group !== MENU_ADD_YT) return;
  const scheduleId = scheduleKey === MENU_ALWAYS_SUFFIX ? null : scheduleKey;
  const targetUrl = info.linkUrl || info.pageUrl;
  if (!targetUrl) return;

  if (group === MENU_ADD_SITE) {
    const host = hostnameFromUrl(targetUrl);
    if (!host) return;
    submitAddRule("domain", host, scheduleId, tab && tab.id);
  } else {
    const handle = youtubeHandleFromUrl(targetUrl);
    if (!handle) {
      showPageToast(tab && tab.id, "FocusFense: 채널 URL을 인식하지 못했습니다", false);
      return;
    }
    const pattern = `youtube.com/${handle.startsWith("@") ? handle : "c/" + handle}`;
    submitAddRule("keyword", pattern, scheduleId, tab && tab.id);
  }
});

chrome.runtime.onStartup.addListener(rebuildContextMenus);
chrome.runtime.onInstalled.addListener(rebuildContextMenus);
setInterval(rebuildContextMenus, MENU_SYNC_MS);
rebuildContextMenus();
