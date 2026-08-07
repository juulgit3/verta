// Proves the real fix to updateEventDetails(): the previous bug was that render() (which fully
// recreates the #edSave button from viewAdmin()'s template) ran BEFORE flashSaved('#edSave'), so the
// "Gemmer…" state was wiped and replaced by a fresh, plain "Gem" button with only a barely-visible
// 900ms background tint — no textual "Gemt" confirmation ever appeared. This test proves the fixed
// function shows Gemmer… -> Gemt ✓ (surviving the render() DOM-recreation) -> back to Gem, using
// setTimeout mocked out so the sequence can be asserted deterministically.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const { JSDOM } = require('jsdom');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
function extract(s, e) { const i = src.indexOf(s); assert(i !== -1, 'not found: ' + s); const j = src.indexOf(e, i); assert(j !== -1, 'end not found: ' + e); return src.slice(i, j); }
const fnSrc = extract('async function updateEventDetails(){', 'function addDays(');

const dom = new JSDOM(`<!doctype html><html><body>
  <input id="edTitle" value="NORDA A/S — Ledermøde">
  <select id="edVenue"><option value="v1" selected>Ringsted Kongrescenter</option></select>
  <input id="edDate" value="2026-09-24">
  <input id="edPrice" value="22000">
  <select id="edType"><option value="konference" selected>konference</option></select>
  <button id="edSave" class="btn primary">Gem</button>
</body></html>`, { url: 'http://localhost/' });

const state = { eventId: 'evt-1', offerTotal: 0, eventDate: '', eventTitle: '', venueName: '', venueId: '', eventType: '' };
const timers = []; // capture setTimeout callbacks instead of running them, so the test controls time
let renderCallCount = 0;
const sandbox = {
  window: dom.window,
  document: dom.window.document,
  console,
  state,
  setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
  mutate: async (thunk) => thunk(),
  sb: {
    from(table) {
      return {
        update: () => ({ eq: () => Promise.resolve({ error: null }) }),
        select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: { offer_total_kr: 22000, event_date: '2026-09-24', title: 'NORDA A/S — Ledermøde', venues: { name: 'Ringsted Kongrescenter' }, venue_id: 'v1', event_type: 'konference' } }) }) }),
      };
    },
  },
  loadRooms: async () => {},
  pushLog: () => {},
  showToast: () => {},
  render: () => {
    // Mirrors the real render(): fully destroys and recreates #edSave from a template, exactly the
    // behavior that broke the old flashSaved()-after-render() ordering.
    renderCallCount++;
    const old = dom.window.document.getElementById('edSave');
    const fresh = dom.window.document.createElement('button');
    fresh.id = 'edSave'; fresh.className = 'btn primary'; fresh.textContent = 'Gem';
    old.replaceWith(fresh);
  },
};
vm.createContext(sandbox);
vm.runInContext(fnSrc, sandbox);

let failures = 0;
function check(name, cond) { if (cond) console.log('PASS:', name); else { console.log('FAIL:', name); failures++; } }
const doc = dom.window.document;

(async () => {
  const p = sandbox.updateEventDetails();
  // Right after calling (before the awaited mutate/select resolve), the ORIGINAL button should already
  // show the in-flight state.
  await Promise.resolve(); // let the function run to its first await
  check('button shows "Gemmer…" and is disabled while saving', doc.getElementById('edSave').textContent === 'Gemmer…' && doc.getElementById('edSave').disabled === true);

  await p; // let the whole async function finish (including the render() call)

  check('render() was actually invoked (view refreshed)', renderCallCount === 1);
  const btnAfterRender = doc.getElementById('edSave');
  check('after render() recreates the button, it now shows "Gemt ✓" (not reset to plain "Gem")', btnAfterRender.textContent === 'Gemt ✓');
  check('the "Gemt ✓" button is disabled during its confirmation window (no accidental double-save)', btnAfterRender.disabled === true);
  check('the "Gemt ✓" button carries the flash-saved visual class', btnAfterRender.classList.contains('flash-saved'));
  check('a restore timer was scheduled (setTimeout captured, not yet run)', timers.length === 1 && timers[0].ms >= 1000);

  // Fire the captured timer to simulate the 1.4s elapsing.
  timers[0].fn();
  const btnFinal = doc.getElementById('edSave');
  check('after the confirmation window, button text reverts to "Gem"', btnFinal.textContent === 'Gem');
  check('after the confirmation window, button is enabled again', btnFinal.disabled === false);
  check('after the confirmation window, flash-saved class is removed', !btnFinal.classList.contains('flash-saved'));

  check('event data was actually applied to state (not just UI theater)', state.eventTitle === 'NORDA A/S — Ledermøde' && state.offerTotal === 22000);

  console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
  process.exit(failures === 0 ? 0 : 1);
})();
