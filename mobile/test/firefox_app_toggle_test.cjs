// Exercise the production Firefox rule-state transitions without touching a browser profile.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const precisionSource = fs.readFileSync(
  path.join(__dirname, '../assets/browser_extensions/firefox/precision_strike.js'),
  'utf8',
);
const backgroundSource = fs.readFileSync(
  path.join(__dirname, '../assets/browser_extensions/firefox/background.js'),
  'utf8',
);
const youtubeSource = fs.readFileSync(
  path.join(__dirname, '../assets/browser_extensions/firefox/youtube_distraction.js'),
  'utf8',
);
const chromeBackgroundSource = fs.readFileSync(
  path.join(__dirname, '../assets/browser_extensions/chrome/background.js'),
  'utf8',
);

function fakeElement() {
  const attrs = new Map();
  const properties = new Map();
  return {
    style: {
      overflow: '',
      getPropertyValue: (name) => properties.get(name)?.value || '',
      getPropertyPriority: (name) => properties.get(name)?.priority || '',
      setProperty: (name, value, priority = '') => properties.set(name, { value, priority }),
      removeProperty: (name) => properties.delete(name),
    },
    hasAttribute: (name) => attrs.has(name),
    getAttribute: (name) => attrs.get(name) ?? null,
    setAttribute: (name, value) => attrs.set(name, String(value)),
    removeAttribute: (name) => attrs.delete(name),
    remove: () => {},
  };
}

function createPrecision() {
  const hidden = fakeElement();
  hidden.style.setProperty('display', 'grid', '');
  const root = fakeElement();
  root.setAttribute('data-sixvpn-hide-img', '1');
  root.setAttribute('data-sixvpn-overflow-before', '');
  root.style.overflow = 'hidden';
  const document = {
    documentElement: root,
    querySelectorAll: () => [hidden],
    getElementById: () => null,
  };
  const context = vm.createContext({ document });
  vm.runInContext(precisionSource, context);
  return { precision: context.sixvpnPrecision, hidden, root };
}

test('Firefox app OFF clears stale rules and restores page elements; ON replaces with current rules', () => {
  const { precision, hidden, root } = createPrecision();
  const state = {
    protectionEnabled: true,
    blockedDomains: ['blocked.example'],
    keywords: ['trigger'],
    keywordRules: [{ term: 'trigger' }],
    searchQueries: [{ term: 'trigger' }],
    blockedYoutubeHandles: ['@chosen'],
    blockedYoutubeChannelIds: ['UCfixture'],
    blockedYoutubeVideoIds: ['videoFixture'],
    hideImages: true,
    hideSerp: true,
    hideYoutubeResults: true,
    hideYtHomeFeed: true,
    forceSafeSearch: true,
    precisionContentFilter: true,
  };

  precision.hideNode(hidden);
  assert.equal(hidden.style.getPropertyValue('display'), 'none');
  precision.applyRulesPayload(state, { protectionEnabled: false, blockedDomains: [] });
  assert.equal(state.protectionEnabled, false);
  for (const key of [
    'blockedDomains', 'keywords', 'keywordRules', 'searchQueries',
    'blockedYoutubeHandles', 'blockedYoutubeChannelIds', 'blockedYoutubeVideoIds',
  ]) assert.deepEqual(Array.from(state[key]), [], key);
  for (const key of [
    'hideImages', 'hideSerp', 'hideYoutubeResults', 'hideYtHomeFeed',
    'forceSafeSearch', 'precisionContentFilter',
  ]) assert.equal(state[key], false, key);
  assert.equal(hidden.style.getPropertyValue('display'), 'grid');
  assert.equal(hidden.hasAttribute('data-sixvpn-display-before'), false);
  assert.equal(root.hasAttribute('data-sixvpn-hide-img'), false);

  precision.applyRulesPayload(state, {
    protectionEnabled: true,
    blockedDomains: ['allowed-rule.example'],
    keywords: [],
    keywordRules: [],
    searchQueries: [],
    blockedYoutubeHandles: [],
    blockedYoutubeChannelIds: [],
    blockedYoutubeVideoIds: [],
  });
  assert.equal(state.protectionEnabled, true);
  assert.deepEqual(Array.from(state.blockedDomains), ['allowed-rule.example']);
  assert.deepEqual(Array.from(state.keywords), []);
});

test('Firefox background replaces persistent DNR rules and sync settings on app OFF', async () => {
  const dynamicRules = [];
  const sync = {};
  let snapshot;
  const context = vm.createContext({
    AbortController,
    URL,
    TextEncoder,
    setTimeout,
    clearTimeout,
    fetch: async () => ({ ok: true, json: async () => context.payload }),
    chrome: {
      runtime: { getManifest: () => ({ name: 'FocusFense for Firefox' }) },
      declarativeNetRequest: {
        getDynamicRules: async () => dynamicRules,
        updateDynamicRules: async ({ removeRuleIds, addRules }) => {
          for (let i = dynamicRules.length - 1; i >= 0; i--) {
            if (removeRuleIds.includes(dynamicRules[i].id)) dynamicRules.splice(i, 1);
          }
          dynamicRules.push(...addRules);
        },
      },
      storage: {
        sync: { set: async (values) => Object.assign(sync, values) },
        local: { set: async (values) => { snapshot = values.sixvpn_rules_snapshot; } },
      },
    },
  });
  vm.runInContext(backgroundSource.slice(0, backgroundSource.indexOf('chrome.runtime.onStartup')), context);

  context.payload = {
    protectionEnabled: true,
    blockedDomains: ['blocked.example'],
    keywords: [],
    blockedYoutubeVideoIds: [],
  };
  await context.syncFromApp();
  assert.equal(dynamicRules.length, 1);
  assert.equal(sync.protectionEnabled, true);

  context.payload = {
    protectionEnabled: false,
    blockedDomains: ['stale.example'],
    keywords: ['stale-term'],
    blockedYoutubeVideoIds: [],
  };
  await context.syncFromApp();
  assert.deepEqual(dynamicRules, []);
  assert.equal(sync.protectionEnabled, false);
  assert.deepEqual(Array.from(sync.blockedDomains), []);
  assert.deepEqual(Array.from(sync.keywords), []);
  assert.equal(snapshot.protectionEnabled, false);
  assert.deepEqual(Array.from(snapshot.blockedDomains), []);
});

test('Chrome background replaces persistent DNR rules and sync settings on app OFF', async () => {
  const dynamicRules = [];
  const sync = {};
  let snapshot;
  const context = vm.createContext({
    AbortController,
    URL,
    TextEncoder,
    setTimeout,
    clearTimeout,
    fetch: async () => ({ ok: true, json: async () => context.payload }),
    chrome: {
      runtime: { getManifest: () => ({ name: 'FocusFense for Chrome' }) },
      declarativeNetRequest: {
        getDynamicRules: async () => dynamicRules,
        updateDynamicRules: async ({ removeRuleIds, addRules }) => {
          for (let i = dynamicRules.length - 1; i >= 0; i--) {
            if (removeRuleIds.includes(dynamicRules[i].id)) dynamicRules.splice(i, 1);
          }
          dynamicRules.push(...addRules);
        },
      },
      storage: {
        sync: { set: async (values) => Object.assign(sync, values) },
        local: { get: async () => ({}), set: async (values) => { snapshot = values.sixvpn_rules_snapshot; } },
      },
    },
  });
  // Quota worker has separate sender/ledger tests; isolate navigation rules here.
  context.importScripts = () => {};
  vm.runInContext(chromeBackgroundSource.slice(0, chromeBackgroundSource.indexOf('chrome.runtime.onStartup')), context);

  context.payload = {
    protectionEnabled: true,
    blockedDomains: ['blocked.example'],
    keywords: [],
    blockedYoutubeVideoIds: [],
  };
  await context.syncFromApp();
  assert.equal(dynamicRules.length, 1);
  assert.equal(sync.protectionEnabled, true);

  context.payload = {
    protectionEnabled: false,
    blockedDomains: ['stale.example'],
    keywords: ['stale-term'],
    blockedYoutubeVideoIds: [],
  };
  await context.syncFromApp();
  assert.deepEqual(dynamicRules, []);
  assert.equal(sync.protectionEnabled, false);
  assert.deepEqual(Array.from(sync.blockedDomains), []);
  assert.deepEqual(Array.from(sync.keywords), []);
  assert.equal(snapshot.protectionEnabled, false);
  assert.deepEqual(Array.from(snapshot.blockedDomains), []);
});

test('Firefox YouTube filters follow the app protection toggle and do not redirect while OFF', () => {
  const styleById = new Map();
  const store = {
    ytDistraction: { hideComments: true, blockShorts: true },
    protectionEnabled: true,
  };
  const listeners = [];
  const style = { id: '', textContent: '' };
  const document = {
    head: { appendChild: (node) => styleById.set(node.id, node) },
    documentElement: { appendChild: (node) => styleById.set(node.id, node) },
    getElementById: (id) => styleById.get(id) || null,
    createElement: () => ({ id: '', textContent: '' }),
    querySelectorAll: () => [],
    querySelector: () => null,
  };
  let replacements = 0;
  let restores = 0;
  const context = vm.createContext({
    document,
    location: {
      hostname: 'www.youtube.com', pathname: '/watch', href: 'https://www.youtube.com/watch?v=fixture',
      replace: () => { replacements++; },
    },
    MutationObserver: class { observe() {} },
    requestAnimationFrame: (callback) => callback(),
    setInterval: () => 1,
    clearInterval: () => {},
    AbortController,
    setTimeout,
    clearTimeout,
    fetch: async () => { throw new Error('no active app endpoint in isolated test'); },
    sixvpnPrecision: {
      hideNode: () => {},
      restorePage: () => { restores++; },
    },
    chrome: {
      storage: {
        sync: { get: (_defaults, callback) => callback({ ...store }) },
        onChanged: { addListener: (listener) => listeners.push(listener) },
      },
    },
  });
  vm.runInContext(youtubeSource, context);
  const styleNode = styleById.get('sixvpn-yt-distraction-style') || style;
  assert.match(styleNode.textContent, /#comments/);

  store.protectionEnabled = false;
  store.ytDistraction = { hideComments: true, blockShorts: true };
  listeners[0]({ protectionEnabled: { oldValue: true, newValue: false } }, 'sync');
  assert.equal(styleNode.textContent, '');
  assert.equal(replacements, 0);
  assert.ok(restores > 0);
});

test('Firefox YouTube distraction script is gated by app OFF and restores its CSS', () => {
  const styles = new Map();
  const store = {
    ytDistraction: { hideComments: true, blockShorts: true },
    protectionEnabled: true,
  };
  const listeners = [];
  const document = {
    head: { appendChild: (node) => styles.set(node.id, node) },
    documentElement: { appendChild: (node) => styles.set(node.id, node) },
    getElementById: (id) => styles.get(id) || null,
    createElement: () => ({ id: '', textContent: '' }),
    querySelectorAll: () => [],
    querySelector: () => null,
  };
  let replacements = 0;
  let restores = 0;
  const location = {
    hostname: 'www.youtube.com', pathname: '/watch', href: 'https://www.youtube.com/watch?v=fixture',
    replace: () => { replacements++; },
  };
  const context = vm.createContext({
    document,
    location,
    MutationObserver: class { observe() {} },
    requestAnimationFrame: (callback) => callback(),
    setInterval: () => 1,
    clearInterval: () => {},
    AbortController,
    setTimeout,
    clearTimeout,
    fetch: async () => { throw new Error('no active app endpoint in isolated test'); },
    sixvpnPrecision: {
      hideNode: () => {},
      restorePage: () => { restores++; },
    },
    chrome: {
      storage: {
        sync: { get: (_defaults, callback) => callback({ ...store }) },
        onChanged: { addListener: (listener) => listeners.push(listener) },
      },
    },
  });
  vm.runInContext(youtubeSource, context);
  const css = styles.get('sixvpn-yt-distraction-style');
  assert.match(css.textContent, /#comments/);

  store.protectionEnabled = false;
  location.pathname = '/shorts/fixture';
  location.href = 'https://www.youtube.com/shorts/fixture';
  listeners[0]({ protectionEnabled: { oldValue: true, newValue: false } }, 'sync');
  assert.equal(css.textContent, '');
  assert.equal(replacements, 0);
  assert.ok(restores > 0);
});
