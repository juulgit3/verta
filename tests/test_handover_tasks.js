// Regression test for a real bug found during the coordinator-workflow walkthrough: handoverEvent()
// used to move ALL open agenda items to the new owner when "flyt åbne opgaver" was checked, instead of
// only the ones actually assigned to the OUTGOING owner — silently reassigning a colleague's own tasks
// (e.g. a secondary coordinator's) away from them on every handover. Fixed by filtering on
// p.assignedStaffId===oldOwnerId (captured before state.ownerStaffId is overwritten with the new owner).
// This test extracts the REAL handoverEvent() from app/index.html and runs it against a fake Supabase
// client that records exactly which agenda_items ids were sent in the update().in(...) call.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
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

const handoverSrc = extract('async function handoverEvent(newOwnerId, moveTasks, note){', 'MODAL_RENDERERS.handover = function(){');

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

function makeSandbox() {
  const calls = { agendaUpdates: [] };
  const sandbox = {
    console,
    calls,
    state: {
      eventId: 'ev1',
      ownerStaffId: 'staff-old',
      roster: [{ id: 'staff-old', name: 'Anna' }, { id: 'staff-new', name: 'Bo' }, { id: 'staff-other', name: 'Cecilie' }],
      punkter: [
        { id: 't1', status: 'mangler', assignedStaffId: 'staff-old' },  // owned by outgoing owner -> should move
        { id: 't2', status: 'udkast', assignedStaffId: 'staff-old' },   // owned by outgoing owner -> should move
        { id: 't3', status: 'mangler', assignedStaffId: 'staff-other' }, // owned by a THIRD colleague -> must NOT move
        { id: 't4', status: 'mangler', assignedStaffId: '' },           // unassigned -> must NOT move
        { id: 't5', status: 'aftalt', assignedStaffId: 'staff-old' }    // done -> excluded regardless of owner
      ]
    },
    mutate: async (thunk) => thunk(),
    sb: {
      from(table) {
        if (table === 'events') return { update: () => ({ eq: async () => ({ error: null }) }) };
        if (table === 'event_staff') return { upsert: async () => ({ error: null }) };
        if (table === 'agenda_items') return { update: (payload) => ({ in: async (col, ids) => { calls.agendaUpdates.push({ payload, ids }); return { error: null }; } }) };
        throw new Error('unexpected table ' + table);
      }
    },
    showToast: () => {},
    pushLog: () => {},
    loadEventStaff: async () => {},
    reloadPunkter: async () => {}
  };
  vm.createContext(sandbox);
  return sandbox;
}

(async () => {
  const sandbox = makeSandbox();
  vm.runInContext(handoverSrc, sandbox);
  const ok = await sandbox.handoverEvent('staff-new', true, '');

  check('handoverEvent returns true on success', ok === true);
  check('exactly one agenda_items update was issued', sandbox.calls.agendaUpdates.length === 1);
  const moved = (sandbox.calls.agendaUpdates[0] || { ids: [] }).ids.slice().sort();
  check('only the outgoing owner\'s two open tasks were moved (t1, t2)', JSON.stringify(moved) === JSON.stringify(['t1', 't2']));
  check('a third colleague\'s open task (t3) was NOT swept into the handover', !moved.includes('t3'));
  check('an unassigned open task (t4) was NOT swept into the handover', !moved.includes('t4'));
  check('an already-done task (t5) was NOT included even though it belonged to the outgoing owner', !moved.includes('t5'));
  check('the new owner id is what tasks get reassigned to', sandbox.calls.agendaUpdates[0].payload.assigned_staff_id === 'staff-new');

  // moveTasks=false must skip the agenda_items call entirely.
  const sandbox2 = makeSandbox();
  vm.runInContext(handoverSrc, sandbox2);
  await sandbox2.handoverEvent('staff-new', false, '');
  check('moveTasks=false issues no agenda_items update at all', sandbox2.calls.agendaUpdates.length === 0);

  console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
  process.exit(failures === 0 ? 0 : 1);
})();
