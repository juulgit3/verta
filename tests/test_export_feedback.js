// Proves the #eksport button's fixed click handler shows "Forbereder fil…" -> "Download startet ✓" ->
// reset, guards against double-submit, and surfaces an exception as a visible error toast instead of
// silently doing nothing (the exact symptom the regression report described: "no download, no feedback
// within 10 seconds"). Uses the REAL handler body extracted from app/index.html.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const { JSDOM } = require('jsdom');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
function extract(s, e) { const i = src.indexOf(s); assert(i !== -1, 'not found: ' + s); const j = src.indexOf(e, i); assert(j !== -1, 'end not found: ' + e); return src.slice(i, j); }
const handlerSrc = extract("const eks=document.getElementById('eksport');", "const pr=document.getElementById('print');");

function run(exportImpl) {
  const dom = new JSDOM(`<!doctype html><body><select id="exportFormat"><option value="csv" selected>CSV</option></select><button id="eksport">Eksportér</button></body>`);
  const timers = [];
  let toastMsg = null;
  const sandbox = {
    window: dom.window, document: dom.window.document, console,
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    showToast: (msg) => { toastMsg = msg; },
    exportGuestsJson: () => {}, exportGuestsTable: exportImpl,
  };
  vm.createContext(sandbox);
  vm.runInContext(handlerSrc, sandbox);
  return { dom, timers, getToast: () => toastMsg };
}

let failures = 0;
function check(name, cond) { if (cond) console.log('PASS:', name); else { console.log('FAIL:', name); failures++; } }

// Scenario 1: happy path.
{
  const { dom, timers } = run(() => {});
  const btn = dom.window.document.getElementById('eksport');
  btn.onclick();
  check('button text becomes "Download startet ✓" immediately after a successful export call', btn.textContent === 'Download startet ✓');
  check('button is disabled during the confirmation window', btn.disabled === true);
  check('a restore timer was scheduled', timers.length === 1);
  timers[0].fn();
  check('button resets to "Eksportér" after the window', btn.textContent === 'Eksportér');
  check('button re-enabled after the window', btn.disabled === false);
}

// Scenario 2: double-click guard — a second click while disabled must be a no-op.
{
  let callCount = 0;
  const { dom } = run(() => { callCount++; });
  const btn = dom.window.document.getElementById('eksport');
  btn.onclick(); btn.onclick(); btn.onclick();
  check('rapid repeated clicks only trigger one actual export call', callCount === 1);
}

// Scenario 3: the export implementation throws (e.g. a real bug in the CSV builder) -> must show a
// visible error toast and leave the button in a sane (not stuck) state, never silently do nothing.
{
  const { dom, timers, getToast } = run(() => { throw new Error('kunne ikke bygge CSV'); });
  const btn = dom.window.document.getElementById('eksport');
  btn.onclick();
  check('an exception surfaces as a visible error toast', getToast() && getToast().includes('kunne ikke bygge CSV'));
  check('button text is restored immediately on error (not left stuck on "Forbereder fil…")', btn.textContent === 'Eksportér');
  timers[0].fn();
  check('button remains usable (re-enabled) after the error path', btn.disabled === false);
}

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
