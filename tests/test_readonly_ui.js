// Proves applyPreviewReadOnly() actually locks the exact controls a real customer preview renders:
// the guest table (name/kost/kat/reception/middag/tilføj/slet), the agenda item note composer, and
// the message composer. Uses the REAL viewGaester()/viewPunkter()/viewBeskeder() HTML-producing
// functions extracted from app/index.html plus the REAL applyPreviewReadOnly(), not reimplementations.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const { JSDOM } = require('jsdom');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
function extract(startMarker, endMarker) {
  const s = src.indexOf(startMarker);
  assert(s !== -1, 'start marker not found: ' + startMarker);
  const e = src.indexOf(endMarker, s);
  assert(e !== -1, 'end marker not found: ' + endMarker);
  return src.slice(s, e);
}

const guardSrc = extract('function assertCanMutate(){', '/* UI-lag oven på mutate()');
const readOnlySrc = extract('function applyPreviewReadOnly(){', 'function onEnterSubmit');
// Range covers everything viewGaester() actually calls at render time (guestEditsAreLocked lives just
// above it; bulkGuestFiltered/dietSummaryCard/dietTags/DIET_TAG_LABEL/normNameForDupe live below it, up
// to taskNotesHtml). The "Indsæt flere navne"/CSV-import modal renderers (MODAL_RENDERERS.*) sit in the
// middle of that range and reference the generic modal system (MODAL_RENDERERS/state.modal), which this
// focused test never exercises — stripped out below so their unresolved references don't break the
// sandbox eval.
const guestEditsAreLockedSrc = extract('function guestEditsAreLocked(){', 'function viewGaester(){');
let viewGaesterSrc = extract('function viewGaester(){', 'function taskNotesHtml');
viewGaesterSrc = viewGaesterSrc.slice(0, viewGaesterSrc.indexOf('MODAL_RENDERERS.bulkAddNames'))
  + viewGaesterSrc.slice(viewGaesterSrc.indexOf('function bulkGuestFiltered'));
const taskNotesHtmlSrc = extract('function taskNotesHtml(p){', 'function renderTask');
const renderTaskSrc = extract('function renderTask(p){', 'function viewPunkter');
const viewBeskederSrc = extract('function viewBeskeder(){', '/* =========================================================');

// Minimal esc() used inside the view functions.
const escSrc = "function esc(s){ return String(s??'').replace(/[&<>\"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c])); }\n";

const dom = new JSDOM('<!doctype html><html><body><main id="view"></main></body></html>', { url: 'http://localhost/' });
const sandbox = {
  window: dom.window,
  document: dom.window.document,
  console,
  state: {
    previewMode: true,
    soeg: '',
    gaester: [
      { id: 'g1', navn: 'Emily', kat: 'voksen', reception: true, middag: true, kost: 'Nøddeallergi' },
      { id: 'g2', navn: 'Lars', kat: 'voksen', reception: true, middag: true, kost: '' }
    ],
    rolle: 'kunde',
    agendaNotes: {},
    openTaskNotes: new Set(),
    orgName: 'Kilden',
    log: [],
    guestSel: new Set(),
    guestBulkFilter: {}
  }
};
const helperSrc = "const DAG=864e5;\nfunction dageTil(iso){ return Math.ceil((new Date(iso+'T00:00:00')-new Date())/DAG); }\nfunction datoKort(iso){ return new Date(iso+'T00:00:00').toLocaleDateString('da-DK',{day:'numeric',month:'short'}); }\nconst STATUS_LABEL = {mangler:'Mangler', udkast:'Udkast', aftalt:'Udført'};\n";

vm.createContext(sandbox);
vm.runInContext(escSrc + helperSrc + guardSrc + readOnlySrc + guestEditsAreLockedSrc, sandbox);
vm.runInContext(viewGaesterSrc, sandbox);
vm.runInContext(taskNotesHtmlSrc, sandbox);
vm.runInContext(renderTaskSrc, sandbox);
vm.runInContext(viewBeskederSrc, sandbox);

// Render the guest tab + a real "jer"-owned open task (mark-done button) + its note composer + the
// messages tab, exactly like render() would inject them into #view for a kunde/preview session.
const guestsHtml = sandbox.viewGaester();
const taskHtml = sandbox.renderTask({ id: 't1', titel: 'Vælg bordplan', ejer: 'jer', status: 'mangler', frist: null, note: '' });
const msgHtml = sandbox.viewBeskeder();
dom.window.document.getElementById('view').innerHTML = guestsHtml + taskHtml + msgHtml;

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

const doc = dom.window.document;

// --- BEFORE calling applyPreviewReadOnly(): confirm the raw render is indeed fully editable
// (this is the exact bug: the customer/preview template renders a live, writable guest table).
check('sanity: guest name input exists and is NOT readonly before lock', doc.querySelector('[data-f="navn"]').readOnly === false);
check('sanity: "Tilføj gæst" button exists before lock', !!doc.getElementById('tilfoej'));
check('sanity: guest delete button exists before lock', !!doc.querySelector('[data-slet]'));
check('sanity: send message button exists and enabled before lock', doc.getElementById('sendmsg').disabled === false);
check('sanity: "Marker som udført" button exists and enabled before lock', doc.querySelector('[data-punkt-done]').disabled === false);

sandbox.applyPreviewReadOnly();

// --- AFTER: verify every known mutation surface is locked.
check('guest name input is readonly after lock', doc.querySelector('[data-f="navn"]').readOnly === true);
check('guest kost input is readonly after lock', doc.querySelector('[data-f="kost"]').readOnly === true);
check('guest category select is disabled after lock', doc.querySelector('[data-f="kat"]').disabled === true);
check('guest reception checkbox is disabled after lock', doc.querySelector('[data-f="reception"]').disabled === true);
check('guest middag checkbox is disabled after lock', doc.querySelector('[data-f="middag"]').disabled === true);
check('"Tilføj gæst" button removed from DOM', doc.getElementById('tilfoej') === null);
check('guest delete button(s) removed from DOM', doc.querySelectorAll('[data-slet]').length === 0);
check('note text input is readonly after lock', doc.querySelector('[data-note-text]').readOnly === true);
check('note file input is disabled after lock', doc.querySelector('[data-note-file]').disabled === true);
check('note send button is disabled after lock', doc.querySelector('[data-note-send]').disabled === true);
check('message textarea is readonly after lock', doc.getElementById('msgtext').readOnly === true);
check('"Send besked" button is disabled after lock', doc.getElementById('sendmsg').disabled === true);
check('"Marker som udført" button is disabled after lock', doc.querySelector('[data-punkt-done]').disabled === true);

// --- Read-only interactions must survive untouched: search input for the guest list must remain
// fully interactive (not readonly/disabled), since the task explicitly requires search to keep working.
check('guest search input (#soeg) is untouched (not readonly, not disabled)', doc.getElementById('soeg').readOnly === false && doc.getElementById('soeg').disabled === false);
check('export controls untouched', doc.getElementById('eksport').disabled === false && doc.getElementById('exportFormat').disabled === false);

// --- Attempting to actually type into a locked field and read its value back proves readOnly
// blocks user typing at the DOM level (browsers refuse value changes via keyboard on readOnly
// fields); programmatic .value assignment still works (jsdom doesn't model keyboard input), which is
// exactly why mutate() — not this DOM layer — is the real security backstop (see test_mutate_guard.js).
const navnInput = doc.querySelector('[data-f="navn"]');
check('locked field keeps its original value untouched by the lock itself', navnInput.value === 'Emily');

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
