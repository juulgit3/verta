// Proves the event-routing resolution logic extracted verbatim from cloudBoot() in app/index.html:
// URL context > sessionStorage context > single-access default > picker fallback, and that a
// URL/session value NOT present in the user's own real access rows is silently ignored (never trusted
// on its own) rather than granting access to an event the user doesn't actually have a row for.
const fs = require('fs');
const assert = require('assert');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
const marker = "let row = (urlEventId && acc.find";
const start = src.indexOf(marker);
assert(start !== -1, 'resolution block not found');
const end = src.indexOf('if(!row){', start);
const block = src.slice(start, end);
console.log('--- extracted resolution logic (urlEventId/storedEventId/acc are the REAL cloudBoot() variable names, injected here as test inputs) ---\n' + block + '----------------------------------');

function resolve(acc, urlEventId, storedEventId) {
  // Re-executes the EXACT extracted expression (not a reimplementation) against injected inputs.
  const fn = new Function('acc', 'urlEventId', 'storedEventId', block + '\nreturn row;');
  return fn(acc, urlEventId, storedEventId);
}

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

const A = { id: 'row-a', event_id: 'event-A', display_name: 'Emily & Lars' };
const B = { id: 'row-b', event_id: 'event-B', display_name: 'Emily & Lars' };

// Scenario 1: single access, no URL/session context -> auto-resolve to it (preserves today's good UX
// for the common case of one guest = one event).
check('single access with no context resolves directly', resolve([A], null, null) === A);

// Scenario 2 (the reported bug): two accesses exist (link A opened earlier, link B generated later).
// A fresh load carrying link B's URL context must open B — and, critically, a fresh load of link A's
// URL (or a restored session for A) must still open A, never silently reroute to B because B is newer.
check('two accesses, URL says A -> opens A (not "newest wins")', resolve([A, B], 'event-A', null) === A);
check('two accesses, URL says B -> opens B', resolve([A, B], 'event-B', null) === B);
check('two accesses, stored session says A (URL empty, e.g. reload) -> opens A', resolve([A, B], null, 'event-A') === A);
check('two accesses, URL wins over a stale stored session pointing elsewhere', resolve([A, B], 'event-B', 'event-A') === B);

// Scenario 3: no context at all with multiple accesses -> no default guess, caller must show a picker.
check('two accesses, no context at all -> unresolved (row is null/undefined), picker required', !resolve([A, B], null, null));

// Scenario 4 (security-relevant): a forged/foreign event id in the URL that is NOT one of the user's
// own real event_access rows must be ignored, not trusted, and must not itself grant/resolve access.
check('URL event id not in the users own access rows is ignored, not resolved', !resolve([A, B], 'event-FOREIGN', null));
check('stored event id not in the users own access rows is ignored, not resolved', !resolve([A, B], null, 'event-FOREIGN'));

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
