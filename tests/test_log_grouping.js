// Loggruppering ("skjul gentagne opslag"): udtrækker den RIGTIGE groupLogRows() fra app/index.html.
// Dækker at kun KONSEKUTIVE "kiggede ind"-hændelser fra SAMME person grupperes — en ændring eller en
// besked midt i en stribe kigge-hændelser skal stadig afbryde grupperingen, og forskellige personers
// kigge-hændelser må aldrig blandes sammen i én gruppe. Respekterer også fra/til-toggle for hele
// funktionen (state.logCollapseViews).
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
const start = src.indexOf('function groupLogRows(rows){');
const stop = src.indexOf('function logLine(e){', start);
assert(start !== -1 && stop !== -1, 'groupLogRows not found');
const extracted = src.slice(start, stop);

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

const sandbox = { state: { logCollapseViews: true }, console };
vm.createContext(sandbox);
vm.runInContext(extracted, sandbox);
const { groupLogRows } = sandbox;

const view = (who, ts) => ({ type: 'view', who, ts });
const change = (who, ts) => ({ type: 'change', who, ts, label: 'x' });

// Three consecutive views from the same person -> one collapsed group.
let rows = [view('Emily', 3), view('Emily', 2), view('Emily', 1)];
let groups = groupLogRows(rows);
check('3 consecutive views from the same person collapse into 1 group', groups.length === 1 && groups[0].kind === 'viewgroup');
check('collapsed group carries all 3 original entries', groups[0].entries.length === 3);

// A single, isolated view stays a single row (grouping a lone entry would be pointless noise).
groups = groupLogRows([view('Emily', 1)]);
check('a single isolated view is NOT wrapped in a group (kind stays "single")', groups.length === 1 && groups[0].kind === 'single');

// A change in between two views must break the run — real activity must never be hidden inside a group.
rows = [view('Emily', 3), change('Emily', 2), view('Emily', 1)];
groups = groupLogRows(rows);
check('a change event between two views breaks the grouping (real activity is never hidden)', groups.length === 3 && groups.every(g => g.kind === 'single'));

// Views from two different people interleaved must never merge into one group.
rows = [view('Emily', 4), view('Lars', 3), view('Emily', 2), view('Emily', 1)];
groups = groupLogRows(rows);
check('views from different people are never merged into the same group', groups.length === 3);
check('the two adjacent Emily views (positions 3,4) still group together on their own', groups.some(g => g.kind === 'viewgroup' && g.entries.length === 2 && g.who === 'Emily'));

// Toggle off entirely -> every row stays single, even long runs.
sandbox.state.logCollapseViews = false;
rows = [view('Emily', 3), view('Emily', 2), view('Emily', 1)];
groups = groupLogRows(rows);
check('state.logCollapseViews=false disables grouping entirely, even for long runs', groups.length === 3 && groups.every(g => g.kind === 'single'));

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
