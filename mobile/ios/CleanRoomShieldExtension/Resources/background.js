/**
 * Loads rules JSON from native (App Group via SafariWebExtensionHandler) and
 * maps domainRules to declarativeNetRequest dynamic rules.
 */
const ext = typeof browser !== "undefined" ? browser : chrome;
const NATIVE_APP_ID = "com.sixcleanroom.sixCleanRoom";
const RULE_ID_BASE = 100000;

async function fetchRulesFromNative() {
  try {
    const reply = await ext.runtime.sendNativeMessage(NATIVE_APP_ID, {
      cmd: "getRulesJson",
    });
    if (typeof reply === "string") {
      return JSON.parse(reply);
    }
    if (reply && typeof reply.rulesJson === "string") {
      return JSON.parse(reply.rulesJson);
    }
  } catch (e) {
    console.warn("native rules fetch failed", e);
  }
  return { domainRules: [], schemaVersion: 0 };
}

function hostToUrlFilter(host) {
  const h = host.replace(/^\.+/, "").toLowerCase();
  if (!h) {
    return "*";
  }
  return `||${h}^`;
}

async function applyDomainRules(bundle) {
  const domains = (bundle.domainRules || []).filter((r) => r && r.enabled && r.host);
  const addRules = domains.map((r, index) => ({
    id: RULE_ID_BASE + index,
    priority: 1,
    action: { type: "block" },
    condition: {
      urlFilter: hostToUrlFilter(r.host),
      resourceTypes: ["main_frame", "sub_frame"],
    },
  }));

  const existing = await ext.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = existing.map((rule) => rule.id);

  await ext.declarativeNetRequest.updateDynamicRules({
    removeRuleIds,
    addRules,
  });
}

ext.runtime.onInstalled.addListener(async () => {
  const bundle = await fetchRulesFromNative();
  await applyDomainRules(bundle);
});

ext.runtime.onStartup.addListener(async () => {
  const bundle = await fetchRulesFromNative();
  await applyDomainRules(bundle);
});
