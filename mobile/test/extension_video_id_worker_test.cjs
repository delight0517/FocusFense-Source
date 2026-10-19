// Executes the actual shared Chrome/Edge/Aside worker parser without a browser.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../assets/browser_extensions/chrome/background.js'), 'utf8');
function parse(input) {
  const context = vm.createContext({ URL, TextEncoder, importScripts() {} });
  vm.runInContext(source.slice(0, source.indexOf('chrome.runtime.onStartup')), context);
  context.input = input;
  return Array.from(vm.runInContext('extractYoutubeVideoIds(input)', context));
}
function evaluate(expression, input) {
  const context = vm.createContext({ URL, TextEncoder, importScripts() {} });
  vm.runInContext(source.slice(0, source.indexOf('chrome.runtime.onStartup')), context);
  context.input = input;
  return JSON.parse(vm.runInContext(`JSON.stringify(${expression})`, context));
}
async function buildRules(domains, keywords) {
  const addedRules = [];
  const context = vm.createContext({
    URL,
    TextEncoder,
    importScripts() {},
    chrome: { declarativeNetRequest: {
      getDynamicRules: async () => [],
      updateDynamicRules: async ({ addRules }) => { addedRules.push(...addRules); },
    } },
  });
  vm.runInContext(source.slice(0, source.indexOf('chrome.runtime.onStartup')), context);
  context.input = { domains, keywords };
  await vm.runInContext('applyDynamicRules(input.domains, input.keywords, [])', context);
  return addedRules;
}
test('watch URLs capture the case-preserved video ID, never the host name', () => {
  for (const prefix of ['youtube.com', 'https://www.youtube.com', 'https://m.youtube.com']) {
    assert.deepEqual(parse([`${prefix}/watch?v=oKv36JQ64QM`]), ['oKv36JQ64QM']);
    assert.deepEqual(parse([`${prefix}/watch?feature=share&v=oKv36JQ64QM&t=1`]), ['oKv36JQ64QM']);
  }
});
test('unrelated words, domain rules and channel rules are not video IDs', () => {
  assert.deepEqual(parse(['youtube.com/@ChosenFixture', 'blocked-test.example', 'ordinarykeyword']), []);
});
test('short URLs and Shorts preserve video ID case and deduplicate', () => {
  assert.deepEqual(parse(['https://youtu.be/oKv36JQ64QM', 'https://www.youtube.com/shorts/oKv36JQ64QM']), ['oKv36JQ64QM']);
});
test('international YouTube channel rules are ASCII and avoid duplicate regex rules', async () => {
  const rules = await buildRules(['bücher.de'], ['youtube.com/@보따']);
  const filters = rules.map((rule) => rule.condition.urlFilter || rule.condition.regexFilter);
  assert.equal(rules.length, 3);
  assert.ok(filters.every((filter) => /^[\x00-\x7F]*$/.test(filter)));
  assert.ok(filters.some((filter) => filter.includes('@%EB%B3%B4%EB%94%B0')));
  assert.equal(rules.filter((rule) => 'regexFilter' in rule.condition).length, 0);
  assert.ok(filters.includes('||xn--bcher-kva.de^'));
});
test('internationalized domains are converted to ASCII IDNA hostnames', () => {
  const rule = evaluate('domainToRule(input, 1)', 'bücher.de');
  assert.equal(rule.condition.urlFilter, '||xn--bcher-kva.de^');
  assert.ok(/^[\x00-\x7F]*$/.test(rule.condition.urlFilter));
});
