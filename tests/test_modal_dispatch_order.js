// Regression test for a real, critical bug found during this session's browser verification:
// several `MODAL_RENDERERS.xxx = function(){...}` / `MODAL_BINDERS.xxx = function(){...}` property
// assignments (added while building the CSV-import feature) ended up textually BEFORE the
// `const MODAL_RENDERERS = {}` / `const MODAL_BINDERS = {}` declaration further down in the file.
// That is a ReferenceError (temporal dead zone) in plain JavaScript — it stopped the ENTIRE <script>
// block from executing on every single page load, confirmed live with a real Chromium instance
// (Playwright): "Cannot access 'MODAL_RENDERERS' before initialization". Fixed by moving both const
// declarations to the very top of the script, right after the `state` object.
//
// This test guards against the same class of bug recurring: it scans the real source for every
// `MODAL_RENDERERS.` / `MODAL_BINDERS.` occurrence and asserts none of them appear before the
// object's own `const` declaration.
const fs = require('fs');
const path = require('path');
const APP_PATH = path.join(__dirname, '..', 'app', 'index.html');
const src = fs.readFileSync(APP_PATH, 'utf8');

let failures = 0;
function check(name, cond) {
  if (cond) console.log('PASS:', name);
  else { console.log('FAIL:', name); failures++; }
}

for (const name of ['MODAL_RENDERERS', 'MODAL_BINDERS']) {
  const declIdx = src.indexOf(`const ${name} = {}`);
  check(`${name}: const declaration exists exactly once`, src.indexOf(`const ${name} = {}`, declIdx + 1) === -1 && declIdx !== -1);

  // Every `NAME.something = ` assignment (property tildeling) must come AFTER the const declaration.
  const assignRe = new RegExp(`\\b${name}\\.[A-Za-z_]+\\s*=`, 'g');
  let m, earliestAssign = Infinity, offenders = [];
  while ((m = assignRe.exec(src))) {
    if (m.index < earliestAssign) earliestAssign = m.index;
    if (m.index < declIdx) offenders.push(m[0] + ' at offset ' + m.index);
  }
  check(`${name}: no property assignment appears before its own const declaration`, offenders.length === 0);
  if (offenders.length) console.log('  offending assignments:', offenders.join(', '));

  // Sanity: there really are assignments in the file (proves the regex isn't just missing everything).
  assignRe.lastIndex = 0;
  const count = (src.match(assignRe) || []).length;
  check(`${name}: has at least one registered feature (sanity check, found ${count})`, count > 0);
}

// Also ACTUALLY RUN the whole top-level script in a real DOM (jsdom), not just compile it — a plain
// `new Function(...)` only checks syntax, it never executes the body, so it would NOT have caught the
// TDZ bug above (that only throws when the script actually runs top-to-bottom). This reproduces the
// live Chromium/Playwright check performed manually during this session, as a permanent, repeatable
// regression test that needs no browser or network access.
{
  const { JSDOM } = require('jsdom');
  // Pull out every element id/tag the app's top-level script (outside function bodies) touches
  // directly via document.getElementById(...).onclick=... at load time, so the DOM has them to find.
  const ids = [...src.matchAll(/document\.getElementById\('([\w-]+)'\)\.onclick/g)].map(m => m[1]);
  const body = [...new Set(ids)].map(id => `<button id="${id}"></button>`).join('\n') +
    '<div id="view"></div><div id="tabs"></div><main id="view2"></main>';
  const dom = new JSDOM(`<!doctype html><html><body>${body}</body></html>`, { url: 'http://localhost/', runScripts: 'outside-only' });
  const { window } = dom;
  window.supabase = { createClient: () => ({
    auth: { getSession: async () => ({ data: { session: null }, error: null }),
            onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } }) },
    from: () => ({ select(){return this;}, eq(){return this;}, order(){return this;},
                    then(resolve){ resolve({ data: [], error: null }); } }),
    channel: () => ({ on(){return this;}, subscribe(){return this;} })
  }) };
  const scriptSrc = src.match(/<script>([\s\S]*)<\/script>/)[1];
  let threw = null;
  try {
    window.eval(scriptSrc);
  } catch (e) {
    threw = e;
  }
  check('full inline <script> block runs top-to-bottom in a real DOM without throwing' + (threw ? ' (' + threw.message + ')' : ''), !threw);
}

console.log('\n' + (failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'));
process.exit(failures === 0 ? 0 : 1);
