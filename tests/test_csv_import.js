// Gæsteimport (CSV): udtrækker de RIGTIGE parse-/mapping-/dublet-funktioner direkte fra
// app/index.html og kører dem i isolation, uden UI/Supabase. Dækker "min. 24 scenarier"-listens
// CSV-import-krav: gyldige/ugyldige rækker, dublet-detektion, kolonnegætning uafhængig af rækkefølge/
// sprog, komma- vs. semikolon-sniffing.
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
const importSrc = extract('function parseCsvText(text){', 'MODAL_RENDERERS.bulkAddNames');

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

const sandbox = { state: { gaester: [] }, console };
vm.createContext(sandbox);
vm.runInContext(importSrc, sandbox);
const { parseCsvText, guessColumnIndex, normalizeCategoryImport, parseBoolImport, normNameForDupe, buildImportPreview, dietTags } = sandbox;

// --- parseCsvText: delimiter sniffing, quotes, BOM ---
const semicolonCsv = 'Navn;Kategori;Reception;Middag;Særlig kost\r\nSofie Hansen;voksen;Ja;Ja;\r\n"Hansen, Bo";voksen;Ja;Nej;"Gluten; skal tjekkes"\r\n';
const rowsSemi = parseCsvText('﻿' + semicolonCsv);
check('BOM is stripped', rowsSemi[0][0] === 'Navn');
check('semicolon-delimited file is sniffed correctly (5 columns)', rowsSemi[0].length === 5);
check('quoted field containing the delimiter is not split', rowsSemi[2][0] === 'Hansen, Bo');
check('quoted field containing a literal semicolon is preserved whole', rowsSemi[2][4] === 'Gluten; skal tjekkes');

const commaCsv = 'Navn,Kategori,Reception,Middag,Særlig kost\nEmily,voksen,Ja,Ja,\n';
const rowsComma = parseCsvText(commaCsv);
check('comma-delimited file is sniffed correctly (5 columns)', rowsComma[0].length === 5);

// --- guessColumnIndex: language/order independence ---
check('guessColumnIndex finds "Navn" for the "navn" pattern', guessColumnIndex(['Navn', 'Kategori'], ['navn', 'name']) === 0);
check('guessColumnIndex finds "Name" (English header) for the same pattern list', guessColumnIndex(['Type', 'Name'], ['navn', 'name']) === 1);
check('guessColumnIndex returns -1 when no header matches', guessColumnIndex(['Foo', 'Bar'], ['navn', 'name']) === -1);

// --- normalizeCategoryImport / parseBoolImport ---
check('category "Barn" normalizes to barn', normalizeCategoryImport('Barn') === 'barn');
check('category "child" normalizes to barn', normalizeCategoryImport('child') === 'barn');
check('category "Baby" normalizes to baby', normalizeCategoryImport('Baby') === 'baby');
check('unrecognized category defaults to voksen', normalizeCategoryImport('xyz') === 'voksen');
check('bool "Ja" -> true', parseBoolImport('Ja', false) === true);
check('bool "Nej" -> false', parseBoolImport('Nej', true) === false);
check('bool empty value falls back to default', parseBoolImport('', true) === true);
check('bool unrecognized value falls back to default', parseBoolImport('???', false) === false);

// --- buildImportPreview: valid/invalid rows + duplicate detection (real scenario from the test plan) ---
sandbox.state.gaester = [{ id: 'existing-1', navn: 'Emily Hansen', kat: 'voksen', reception: true, middag: true, kost: '' }];
const previewRows = parseCsvText(
  'Navn;Kategori;Reception;Middag;Særlig kost\r\n' +
  'Sofie Hansen;voksen;Ja;Ja;\r\n' +           // valid, new
  ';barn;Ja;Nej;\r\n' +                          // invalid: missing navn
  'emily   hansen;voksen;Ja;Ja;\r\n' +           // duplicate of existing guest (case/whitespace-insensitive)
  'Lille Anna;barn;Ja;Nej;Nøddeallergi\r\n'      // valid, new, with diet info
);
const preview = buildImportPreview(previewRows);
const valid = preview.parsed.filter(r => !r.errors.length);
const invalid = preview.parsed.filter(r => r.errors.length);
const dupes = preview.parsed.filter(r => r.duplicateOf);
check('4 data rows parsed', preview.parsed.length === 4);
check('3 rows are valid (have a navn)', valid.length === 3);
check('1 row is invalid (missing navn)', invalid.length === 1);
check('invalid row error message is "Mangler navn"', invalid[0].errors.includes('Mangler navn'));
check('exactly 1 row is flagged as a duplicate', dupes.length === 1);
check('duplicate detection is case/whitespace-insensitive ("emily   hansen" matches "Emily Hansen")', dupes[0].navn.trim().toLowerCase().replace(/\s+/g, ' ') === normNameForDupe('Emily Hansen'));
check('duplicateOf points at the real existing guest id', dupes[0].duplicateOf === 'existing-1');
check('non-duplicate valid rows have duplicateOf === null', valid.find(r => r.navn === 'Sofie Hansen').duplicateOf === null);

// --- dietTags: normalization keeps original text, groups common allergens ---
check('"Nøddeallergi" tags as noedder', dietTags('Nøddeallergi').includes('noedder'));
check('"Vegansk, ingen mælk" tags as both vegansk and laktosefri', dietTags('Vegansk, ingen mælk').includes('vegansk') && dietTags('Vegansk, ingen mælk').includes('laktosefri'));
check('unrecognized free text still gets grouped as "andet" rather than dropped', dietTags('Skal sidde ved vinduet').includes('andet'));
check('empty diet text produces no tags', dietTags('').length === 0);

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
