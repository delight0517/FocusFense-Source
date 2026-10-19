/**
 * Pulls live rules from 6 VPN Blocker (127.0.0.1:17361–17372/rules) and blocks
 * main-frame navigation. Falls back to bundled rules_snapshot.json when the app
 * is closed or the API port moved.
 */
const RULES_PORTS = [17361, 17362, 17363, 17364, 17365, 17366, 17367, 17368, 17369, 17370, 17371, 17372];
const SYNC_MS = 4000;
const RULES_FETCH_TIMEOUT_MS = 1800;

async function fetchWithTimeout(url) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), RULES_FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { cache: "no-store", signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function fetchRulesFromPorts() {
  for (const port of RULES_PORTS) {
    try {
      const res = await fetchWithTimeout(`http://127.0.0.1:${port}/rules`);
      if (!res.ok) continue;
      const data = await res.json();
      if (data && typeof data === "object") {
        data._rulesPort = port;
        return data;
      }
    } catch {
      /* try next port */
    }
  }
  return null;
}

async function fetchBundledSnapshot() {
  try {
    const url = chrome.runtime.getURL("rules_snapshot.json");
    const res = await fetch(url, { cache: "no-store" });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

async function loadCachedSnapshot() {
  const stored = await chrome.storage.local.get(["sixvpn_rules_snapshot"]);
  return stored.sixvpn_rules_snapshot || null;
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

/** Unique @handles /c/ slugs for regex network block (handles redirects off /@url). */
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
    const f = String(urlFilter || "").trim();
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
  const h = regexEscape(handle);
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
  if (mergeVideoIds(keywords, explicitVideoIds).length > 0 || extractYoutubeHandles(keywords).length > 0) {
    const mediaTypes = [
      "main_frame",
      "sub_frame",
      "media",
      "xmlhttprequest",
      "other",
      "websocket",
    ];
    rules.push({
      id: id++,
      priority: 30,
      action: { type: "block" },
      condition: {
        urlFilter: "||googlevideo.com^",
        resourceTypes: mediaTypes,
      },
    });
    rules.push({
      id: id++,
      priority: 30,
      action: { type: "block" },
      condition: {
        urlFilter: "||youtube.googleapis.com^",
        resourceTypes: mediaTypes,
      },
    });
  }
  const existing = await chrome.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = existing.map((r) => r.id);
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds,
    addRules: rules,
  });
}

async function applyRulesPayload(data, source) {
  if (!data || typeof data !== "object") return false;
  const domains = data.blockedDomains || [];
  const keywords = data.keywords || [];
  await applyDynamicRules(domains, keywords, data.blockedYoutubeVideoIds || []);
  await chrome.storage.sync.set({
    keywords,
    blockedDomains: domains,
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
    sixvpn_rules_source: source || "unknown",
  });
  return domains.length > 0 || keywords.length > 0;
}

async function syncFromApp() {
  let data = await fetchRulesFromPorts();
  let source = data ? "api" : "";
  if (!data) {
    data = await loadCachedSnapshot();
    source = data ? "cache" : "";
  }
  if (!data) {
    data = await fetchBundledSnapshot();
    source = data ? "bundled" : "";
  }
  if (data) {
    await applyRulesPayload(data, source);
  }
}

chrome.runtime.onStartup.addListener(() => {
  syncFromApp();
});
chrome.runtime.onInstalled.addListener(() => {
  syncFromApp();
});
setInterval(syncFromApp, SYNC_MS);
syncFromApp();
