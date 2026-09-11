// Loads the REAL mutate() source straight out of app/index.html (not a reimplementation) and proves,
// by calling it directly (no DOM, no UI), that the thunk passed to mutate() is never invoked while
// state.eventArchived is true — the one remaining central write-gate after the v1 simplification
// dropped the "Forhåndsvis som kunde" preview-mode guard (assertCanMutate()/previewMode; see
// roadmap.html "Skåret fra v1"). Archiving is the last case where mutate() must reject a write on its
// own, even if it's called directly, bypassing all UI.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
const start = src.indexOf('async function mutate(thunk){');
const stopMarker = 'function onEnterSubmit(el, fn){';
const stop = src.indexOf(stopMarker, start);
assert(start !== -1, 'mutate not found in source');
assert(stop !== -1, 'stop marker not found in source');
const extracted = src.slice(start, stop);
console.log('--- extracted source under test ---');
console.log(extracted);
console.log('------------------------------------');

let failures = 0;
function check(name, cond) {
  if (cond) { console.log('PASS:', name); }
  else { console.log('FAIL:', name); failures++; }
}

(async () => {
  const sandbox = { state: { eventArchived: false }, console };
  vm.createContext(sandbox);
  vm.runInContext(extracted, sandbox);

  // Test 1: not archived -> thunk runs, real return value passed through
  let called = false;
  const r1 = await sandbox.mutate(() => { called = true; return { data: { id: 1 }, error: null }; });
  check('not archived: thunk is invoked', called === true);
  check('not archived: real result passed through', r1.data && r1.data.id === 1 && r1.error === null);

  // Test 2: archived -> thunk must NEVER be invoked, even calling mutate() directly (bypassing all UI)
  sandbox.state.eventArchived = true;
  called = false;
  const r2 = await sandbox.mutate(() => { called = true; return { data: { id: 2 }, error: null }; });
  check('archived: thunk is NOT invoked (no network call constructed)', called === false);
  check('archived: returns error shaped like Supabase {data,error}', r2.data === null && r2.error && typeof r2.error.message === 'string');
  check('archived: error code is ARCHIVED_READONLY', r2.error.code === 'ARCHIVED_READONLY');

  // Test 3: a thunk that would throw/reject if actually called (simulates a real eager Storage.upload()
  // call) must not blow up mutate() while archived, proving the thunk is skipped entirely, not
  // "invoked and its rejection swallowed".
  let thunkCallCount = 0;
  const dangerousThunk = () => { thunkCallCount++; throw new Error('NETWORK CALL WAS CONSTRUCTED — this must never happen on an archived event'); };
  let threw = false;
  try { await sandbox.mutate(dangerousThunk); } catch (e) { threw = true; }
  check('archived: dangerous thunk never executed (0 calls)', thunkCallCount === 0);
  check('archived: mutate() itself does not throw', threw === false);

  // Test 4: unarchiving restores normal behavior (no stuck state) — mirrors unarchiveEvent()'s real
  // effect of setting state.eventArchived back to false.
  sandbox.state.eventArchived = false;
  called = false;
  await sandbox.mutate(() => { called = true; return { data: {}, error: null }; });
  check('unarchived again: thunk runs normally', called === true);

  console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
  process.exit(failures === 0 ? 0 : 1);
})();
