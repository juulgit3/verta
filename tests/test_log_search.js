// Proves the log search field can be cleared 3 ways (backspace-to-empty, the × clear button, Escape)
// and that state.logSearch is always the raw input value (no truthy-skip on empty string), using the
// REAL viewLog()/logRowsFiltered() and the REAL fLogSearch/fLogSearchClear wiring extracted from
// app/index.html.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const { JSDOM } = require('jsdom');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
function extract(s, e) { const i = src.indexOf(s); assert(i !== -1, 'not found: ' + s); const j = src.indexOf(e, i); assert(j !== -1, 'end not found: ' + e); return src.slice(i, j); }

const logRowsFilteredSrc = extract('function logRowsFiltered(){', 'function logLine(');
const logLineSrc = extract('function logLine(e){', 'function guestExportSlug');
const viewLogSrc = extract('function viewLog(){', 'function viewTidslinje');
const wiringSrc = extract("const fLS=document.getElementById('fLogSearch');", "document.querySelectorAll('[data-msg-to-task]')");
const escSrc = "function esc(s){ return String(s??'').replace(/[&<>\"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c])); }\n";
const helperSrc = "function tid(ts){ return new Date(ts).toLocaleString('da-DK'); }\nconst AREA_TXT={gaester:'Gæster',punkter:'Punkter',system:'System'};\nconst DAG=864e5;\n";

const dom = new JSDOM('<!doctype html><html><body><main id="view"></main></body></html>', { url: 'http://localhost/' });
const state = {
  log: [
    { ts: 1000, who: 'Emily', side: 'kunde', type: 'change', area: 'gaester', label: 'Gæst tilføjet', friendly: 'Emily tilføjede en gæst', from: '', to: '', text: '' },
    { ts: 2000, who: 'Kilden', side: 'kilden', type: 'message', area: 'system', label: '', friendly: '', from: '', to: '', text: 'Hej, spørgsmål om menuen' },
    { ts: 3000, who: 'Lars', side: 'kunde', type: 'change', area: 'punkter', label: 'Opgave udført', friendly: 'Lars markerede bordplan som udført', from: '', to: '', text: '' }
  ],
  logType: 'alle', logWho: 'alle', logArea: 'alle', logDays: 'alle', logFrom: '', logTo: '', logSearch: '', logShowTech: false
};
const sandbox = { window: dom.window, document: dom.window.document, console, state };
vm.createContext(sandbox);
vm.runInContext(escSrc + helperSrc + logRowsFilteredSrc + logLineSrc + viewLogSrc, sandbox);

function renderLog() {
  dom.window.document.getElementById('view').innerHTML = sandbox.viewLog();
  vm.runInContext('{' + wiringSrc + '}', sandbox); // block-scoped so re-running per "render" doesn't redeclare const
}
sandbox.render = renderLog; // mirrors the real render()'s job of re-rendering + re-binding after a state change
renderLog();

let failures = 0;
function check(name, cond) { if (cond) console.log('PASS:', name); else { console.log('FAIL:', name); failures++; } }
const doc = dom.window.document;

check('sanity: 3 rows shown with empty search', sandbox.logRowsFiltered().length === 3);

// 1) Type a query -> filters down
let input = doc.getElementById('fLogSearch');
input.value = 'menuen';
input.oninput();
check('typing "menuen" filters to 1 row', sandbox.logRowsFiltered().length === 1);
check('state.logSearch reflects raw typed value', state.logSearch === 'menuen');

// 2) Backspace to empty -> full list restored (no truthy-skip on empty string assignment)
input = doc.getElementById('fLogSearch'); // re-fetch: render() rebuilt the DOM
input.value = '';
input.oninput();
check('backspacing to empty restores full list (3 rows)', sandbox.logRowsFiltered().length === 3);
check('state.logSearch is empty string, not stale', state.logSearch === '');

// 3) Clear button: type again, then click the × button
input = doc.getElementById('fLogSearch');
input.value = 'bordplan';
input.oninput();
check('sanity: filtered again before testing clear button', sandbox.logRowsFiltered().length === 1);
const clearBtn = doc.getElementById('fLogSearchClear');
check('clear (×) button is rendered when search is non-empty', !!clearBtn);
clearBtn.onclick();
check('clicking × restores full list (3 rows)', sandbox.logRowsFiltered().length === 3);
check('clear button disappears again once search is empty', doc.getElementById('fLogSearchClear') === null);

// 4) Escape key: type again, then press Escape on the field
input = doc.getElementById('fLogSearch');
input.value = 'Emily';
input.oninput();
check('sanity: filtered again before testing Escape', sandbox.logRowsFiltered().length === 1);
input = doc.getElementById('fLogSearch');
let prevented = false;
input.onkeydown({ key: 'Escape', preventDefault: () => { prevented = true; } });
check('Escape calls preventDefault (does not submit/navigate)', prevented === true);
check('Escape restores full list (3 rows)', sandbox.logRowsFiltered().length === 3);

// 5) Other filters must survive a search-clear (e.g. logType stays as set)
state.logType = 'beskeder';
input = doc.getElementById('fLogSearch');
input.value = 'x';
input.oninput();
input = doc.getElementById('fLogSearch');
input.value = '';
input.oninput();
check('other filters (logType) unaffected by clearing the search', state.logType === 'beskeder');
check('the input DOM value always matches state.logSearch after re-render', doc.getElementById('fLogSearch').value === state.logSearch);

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
