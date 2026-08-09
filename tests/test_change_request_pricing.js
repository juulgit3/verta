// Ændringsforslag med prisvirkning: udtrækker de RIGTIGE prisberegnings- og opsummeringsfunktioner
// direkte fra app/index.html. Dækker "min. 24 scenarier"-listens krav om korrekt prisdelta-beregning
// for ændringsforslag, samt den tids-baserede (ikke felt-baserede) regel for hvornår en gæst mister
// direkte skriveadgang til gæstelisten.
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

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

const sandbox = { console, state: { rolle: 'kunde', status: 'kladde' } };
vm.createContext(sandbox);
vm.runInContext("const esc = s => String(s).replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));\nconst kr = n => n.toLocaleString('da-DK')+' kr.';\n", sandbox);
vm.runInContext(extract('function guestEditsAreLocked(){', 'function viewGaester(){'), sandbox);
vm.runInContext(extract('function changeRequestSummary(c){', 'function viewChangeRequestsStaff'), sandbox);
vm.runInContext(extract('function computeEventTotal(guestRows, catalogRows){', '/* Prioriteringsmodel'), sandbox);
const { computeEventTotal, changeRequestSummary, guestEditsAreLocked } = sandbox;

// --- computeEventTotal: the core price-delta building block ---
const catalog = [
  { basis: 'reception', price_kr: 100, child_half: false },
  { basis: 'middag', price_kr: 500, child_half: true },
  { basis: 'fast', price_kr: 2000, child_half: false } // fx DJ, lejeudstyr — pr. arrangement, ikke pr. gæst
];
const guestsBefore = [
  { category: 'voksen', reception: true, dinner: true },
  { category: 'voksen', reception: true, dinner: true },
  { category: 'barn', reception: true, dinner: true },
  { category: 'baby', reception: true, dinner: true } // babyer betaler aldrig, skal ikke tælle med nogen steder
];
const totalBefore = computeEventTotal(guestsBefore, catalog);
// reception: 2 voksne*100 + 1 barn*100(fuld pris, kun middag har child_half) = 300
// middag: 2 voksne*500 + 1 barn*500/2(child_half) = 1250
// fast: 2000
// total = 300+1250+2000 = 3550
check('computeEventTotal: baseline total is correct (voksne+barn+babyer, child_half kun på middag, fast beløb med)', totalBefore === 3550);

const guestsAfterAddingAdult = guestsBefore.concat([{ category: 'voksen', reception: true, dinner: true }]);
const totalAfter = computeEventTotal(guestsAfterAddingAdult, catalog);
const priceDelta = totalAfter - totalBefore;
check('computeEventTotal: adding one adult increases total by reception+middag price for one adult (600 kr)', priceDelta === 600);

const guestsAfterRemovingChild = guestsBefore.filter(g => g.category !== 'barn');
const totalAfterRemove = computeEventTotal(guestsAfterRemovingChild, catalog);
check('computeEventTotal: removing the child reduces total by exactly what that child cost (100 + 250 = 350)', totalBefore - totalAfterRemove === 350);

check('computeEventTotal: a baby never contributes to the per-person total regardless of reception/dinner flags (only the flat fee remains)', computeEventTotal([{ category: 'baby', reception: true, dinner: true }], catalog) === 2000);
check('computeEventTotal: empty guest list still includes the flat-fee catalog line', computeEventTotal([], catalog) === 2000);

// --- changeRequestSummary: human-readable line + signed price delta shown to staff ---
const insertReq = { after_payload: { action: 'insert', guest: { navn: 'Ny Gæst' } }, price_delta: 600 };
const deleteReq = { after_payload: { action: 'delete', guest: { navn: 'Gammel Gæst' } }, price_delta: -350 };
const editReq = { after_payload: { action: 'update', guest: { navn: 'Rettet Gæst' } }, price_delta: 0 };
check('insert request summary names the action and the guest', changeRequestSummary(insertReq).startsWith('Ny gæst: Ny Gæst'));
check('insert request summary shows a "+" prefixed positive delta', changeRequestSummary(insertReq).includes('(+600 kr.)'));
check('delete request summary shows a negative delta without double sign', changeRequestSummary(deleteReq).includes('(-350 kr.)') && !changeRequestSummary(deleteReq).includes('(+-350'));
check('update/edit request is labeled "Ret:"', changeRequestSummary(editReq).startsWith('Ret: Rettet Gæst'));
check('a request with no computed price_delta omits the parenthetical entirely', !changeRequestSummary({ after_payload: { action: 'update', guest: { navn: 'X' } }, price_delta: null }).includes('('));

// --- guestEditsAreLocked: the time-based (not field-based) cutover rule ---
sandbox.state.rolle = 'kunde'; sandbox.state.status = 'kladde';
check('guest, event still kladde: direct edits allowed (not locked)', guestEditsAreLocked() === false);
sandbox.state.status = 'tilbud';
check('guest, event in tilbud: still not locked (change requests only start at bekræftet)', guestEditsAreLocked() === false);
sandbox.state.status = 'bekræftet';
check('guest, event bekræftet: locked — must use change requests, not direct edits', guestEditsAreLocked() === true);
sandbox.state.status = 'afviklet';
check('guest, event afviklet: still locked', guestEditsAreLocked() === true);
sandbox.state.rolle = 'kilden'; sandbox.state.status = 'bekræftet';
check('staff (kilden) is never locked, even on a bekræftet event — only the guest-facing rule applies', guestEditsAreLocked() === false);

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
