// Proves the fixed tab-resolution logic: switching to "Forhåndsvis som kunde" while a staff-only tab
// (e.g. "I dag") is active must fall back to Oversigt, not keep rendering the staff-only view/controls
// under the customer role. Uses the REAL TABS constant and the REAL allowedTabs guard line extracted
// from app/index.html.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
function extract(s, e) { const i = src.indexOf(s); assert(i !== -1, 'not found: ' + s); const j = src.indexOf(e, i); assert(j !== -1, 'end not found: ' + e); return src.slice(i, j); }
const tabsSrc = extract('const TABS = {', '\nfunction renderTabs');
const guardLine = extract("const allowedTabs=TABS[state.rolle].map(t=>t[0]);", "document.getElementById('view')");

const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(tabsSrc, sandbox);

let failures = 0;
function check(name, cond) { if (cond) console.log('PASS:', name); else { console.log('FAIL:', name); failures++; } }

function resolveTab(rolle, tab, mapKeys) {
  const state = { rolle, tab };
  const map = {}; mapKeys.forEach(k => map[k] = () => {});
  const localSandbox = { state, map, document: { getElementById: () => ({}) } };
  vm.createContext(localSandbox);
  vm.runInContext(tabsSrc, localSandbox);
  vm.runInContext(guardLine, localSandbox);
  return localSandbox.state.tab;
}
const allTabKeys = ['live', 'oversigt', 'gaester', 'punkter', 'koekken', 'log', 'admin', 'tidslinje', 'beskeder'];

check('staff on "live" tab stays on "live" (valid for kilden)', resolveTab('kilden', 'live', allTabKeys) === 'live');
check('THE BUG: switching role to kunde while tab="live" now resets to oversigt', resolveTab('kunde', 'live', allTabKeys) === 'oversigt');
check('switching role to kunde while tab="admin" also resets to oversigt', resolveTab('kunde', 'admin', allTabKeys) === 'oversigt');
check('switching role to kunde while tab="log" also resets to oversigt', resolveTab('kunde', 'log', allTabKeys) === 'oversigt');
check('switching role to kunde while tab="koekken" also resets to oversigt', resolveTab('kunde', 'koekken', allTabKeys) === 'oversigt');
check('kunde on a tab that legitimately belongs to them (gaester) is left alone', resolveTab('kunde', 'gaester', allTabKeys) === 'gaester');
check('kunde on tidslinje (kunde-only tab) is left alone', resolveTab('kunde', 'tidslinje', allTabKeys) === 'tidslinje');
check('an unknown/garbage tab value still falls back to oversigt', resolveTab('kilden', 'not-a-real-tab', allTabKeys) === 'oversigt');

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
