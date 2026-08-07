// Loads the REAL mutate()/assertCanMutate() source straight out of app/index.html (not a
// reimplementation) and proves, by calling it directly (no DOM, no UI), that the thunk passed to
// mutate() is never invoked while state.previewMode is true. This is the test the task explicitly
// asked for: "Test også mutationsfunktionerne direkte, så de afviser kald i preview-mode, selv hvis
// de kaldes uden om UI'et."
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
const start = src.indexOf('function assertCanMutate(){');
const stopMarker = '/* UI-lag oven på mutate()';
const stop = src.indexOf(stopMarker, start);
assert(start !== -1, 'assertCanMutate not found in source');
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
  const sandbox = { state: { previewMode: false }, console };
  vm.createContext(sandbox);
  vm.runInContext(extracted, sandbox);

  // Test 1: not in preview -> thunk runs, real return value passed through
  let called = false;
  const r1 = await sandbox.mutate(() => { called = true; return { data: { id: 1 }, error: null }; });
  check('preview OFF: thunk is invoked', called === true);
  check('preview OFF: real result passed through', r1.data && r1.data.id === 1 && r1.error === null);

  // Test 2: enable preview -> thunk must NEVER be invoked, even calling mutate() directly (bypassing all UI)
  sandbox.state.previewMode = true;
  called = false;
  const r2 = await sandbox.mutate(() => { called = true; return { data: { id: 2 }, error: null }; });
  check('preview ON: thunk is NOT invoked (no network call constructed)', called === false);
  check('preview ON: returns error shaped like Supabase {data,error}', r2.data === null && r2.error && typeof r2.error.message === 'string');
  check('preview ON: error code is PREVIEW_READONLY', r2.error.code === 'PREVIEW_READONLY');

  // Test 3: a thunk that would throw/reject if actually called (simulates a real eager Storage.upload()
  // call) must not blow up mutate() in preview mode, proving the thunk is skipped entirely, not
  // "invoked and its rejection swallowed".
  let thunkCallCount = 0;
  const dangerousThunk = () => { thunkCallCount++; throw new Error('NETWORK CALL WAS CONSTRUCTED — this must never happen in preview'); };
  let threw = false;
  try { await sandbox.mutate(dangerousThunk); } catch (e) { threw = true; }
  check('preview ON: dangerous thunk never executed (0 calls)', thunkCallCount === 0);
  check('preview ON: mutate() itself does not throw', threw === false);

  // Test 4: turning preview back off restores normal behavior (no stuck state)
  sandbox.state.previewMode = false;
  called = false;
  await sandbox.mutate(() => { called = true; return { data: {}, error: null }; });
  check('preview OFF again: thunk runs normally', called === true);

  console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
  process.exit(failures === 0 ? 0 : 1);
})();
