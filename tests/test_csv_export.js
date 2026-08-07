// Verifies actual CSV FILE CONTENT (not just that a download fired) produced by the REAL
// exportGuestsTable('csv') function extracted from app/index.html: correct guest count, correct
// fields per guest, UTF-8 BOM present (Excel-DK correctness), semicolon separators, and correct
// escaping of a guest record containing a comma, a semicolon, a double quote, and an embedded newline
// — plus Danish characters æ/ø/å surviving intact.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');

const src = fs.readFileSync(APP_PATH, 'utf8');
function extract(s, e) { const i = src.indexOf(s); assert(i !== -1, 'not found: ' + s); const j = src.indexOf(e, i); assert(j !== -1, 'end not found: ' + e); return src.slice(i, j); }
const guestExportSlugSrc = extract('function guestExportSlug(){', 'function exportGuestsJson');
const exportGuestsTableSrc = extract('function exportGuestsTable(kind){', 'function exportLogCsv');
const escSrc = "function esc(s){ return String(s??'').replace(/[&<>\"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c])); }\n";

let capturedBlob = null, capturedFilename = null;
const state = {
  eventTitle: 'Emily & Lars', eventDate: '2026-09-04',
  gaester: [
    { navn: 'Emily Sørensen', kat: 'voksen', reception: true, middag: true, kost: 'Nøddeallergi, alvorlig' },
    { navn: 'Lars Ærø', kat: 'voksen', reception: true, middag: false, kost: '' },
    { navn: 'Gæst "Vigtig", søn af Bjørn', kat: 'barn', reception: false, middag: true, kost: 'Vegetar;\ningen fisk' },
  ],
};
const sandbox = {
  console,
  state,
  Blob: global.Blob,
  downloadBlob: (blob, filename) => { capturedBlob = blob; capturedFilename = filename; },
};
vm.createContext(sandbox);
vm.runInContext(escSrc + guestExportSlugSrc + exportGuestsTableSrc, sandbox);

let failures = 0;
function check(name, cond) { if (cond) console.log('PASS:', name); else { console.log('FAIL:', name); failures++; } }

(async () => {
  sandbox.exportGuestsTable('csv');
  check('downloadBlob was called with a Blob', capturedBlob instanceof global.Blob);
  check('filename contains a safe event slug and date', capturedFilename === 'emily-lars-2026-09-04.csv');
  check('MIME type is text/csv with utf-8 charset', capturedBlob.type === 'text/csv;charset=utf-8');

  // Blob.text() decodes via TextDecoder, which per the WHATWG Encoding spec consumes/strips a leading
  // BOM as part of normal UTF-8 decoding (it does not appear in the decoded string) — so the BOM must
  // be verified at the raw byte level instead, which is what Excel/any file reader actually sees.
  const bytes = new Uint8Array(await capturedBlob.arrayBuffer());
  check('file starts with the raw UTF-8 BOM bytes EF BB BF (so Excel opens Danish characters correctly)', bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF);
  const body = await capturedBlob.text(); // already BOM-stripped by the decoder; nothing to slice off
  check('uses CRLF line endings', body.includes('\r\n'));
  check('header uses semicolon separators and correct Danish column names', body.startsWith('"Navn";"Kategori";"Reception";"Middag";"Særlig kost"\r\n'));
  check('row 1 preserves Danish characters æ/ø/å in name', body.includes('Emily Sørensen'));
  check('row 1 preserves kost text with an embedded comma (not treated as a delimiter)', body.includes('"Nøddeallergi, alvorlig"'));
  check('embedded double quote in name is escaped by doubling (""), not broken', body.includes('""Vigtig""'));

  // A tiny quote-aware CSV parser is the only correct way to check row/column counts once a field
  // contains an embedded real newline — naive '\r\n'-splitting would wrongly fragment that row.
  function parseCsv(text) {
    const rows = []; let row = []; let field = ''; let inQuotes = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inQuotes) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; } }
        else field += c;
      } else {
        if (c === '"') inQuotes = true;
        else if (c === ';') { row.push(field); field = ''; }
        else if (c === '\r' && text[i + 1] === '\n') { row.push(field); rows.push(row); row = []; field = ''; i++; }
        else field += c;
      }
    }
    if (field.length || row.length) { row.push(field); rows.push(row); }
    return rows;
  }
  const parsed = parseCsv(body);
  check('quote-aware parse yields exactly 4 rows (header + 3 guests), embedded newline did not fragment a row', parsed.length === 4);
  check('every row has exactly 5 columns (no column drift from unescaped delimiters)', parsed.every(r => r.length === 5));
  const guest3 = parsed[3];
  check('guest 3 name field intact incl. embedded quote and Bjørn', guest3[0] === 'Gæst "Vigtig", søn af Bjørn');
  check('guest 3 kost field intact incl. embedded semicolon and real newline', guest3[4] === 'Vegetar;\ningen fisk');
  check('guest 3 category is "barn"', guest3[1] === 'barn');
  check('guest 3 reception=Nej, middag=Ja reflected correctly', guest3[2] === 'Nej' && guest3[3] === 'Ja');

  console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
  process.exit(failures === 0 ? 0 : 1);
})();
