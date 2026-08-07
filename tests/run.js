// Kører alle test_*.js i denne mappe som separate node-processer og opsummerer resultatet.
// Ingen build, intet testframework — bare selvstændige scripts, der exit(0) ved success / exit(1) ved fejl,
// i tråd med resten af projektets "ingen build"-filosofi. Kræver `npm install` i denne mappe først (jsdom).
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const files = fs.readdirSync(__dirname).filter(f => f.startsWith('test_') && f.endsWith('.js')).sort();
let failed = 0;
for (const f of files) {
  console.log('\n=== ' + f + ' ===');
  try {
    const out = execFileSync('node', [path.join(__dirname, f)], { encoding: 'utf8' });
    process.stdout.write(out);
  } catch (e) {
    process.stdout.write(e.stdout || '');
    process.stderr.write(e.stderr || String(e.message));
    failed++;
  }
}
console.log('\n' + (failed === 0 ? `ALL ${files.length} TEST FILES PASSED` : `${failed} of ${files.length} TEST FILES FAILED`));
process.exit(failed === 0 ? 0 : 1);
