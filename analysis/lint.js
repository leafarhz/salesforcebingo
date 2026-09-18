// A top-level `const`/`let` named after a non-configurable window property throws
// SyntaxError at evaluation time — the whole script dies before running, and
// neither `node --check` nor a Node harness can see it (no `window` there).
const fs = require('fs');
const RESTRICTED = [
    'top', 'self', 'window', 'document', 'location', 'parent', 'frames',
    'history', 'navigator', 'closed', 'length', 'origin', 'external'
];
const src = fs.readFileSync(process.argv[2], 'utf8');
const script = src.slice(src.lastIndexOf('<script>') + 8, src.lastIndexOf('</script>'));
const bad = [];
script.split('\n').forEach((line, i) => {
    const m = line.match(/^\s*(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/);
    if (m && RESTRICTED.includes(m[1])) bad.push(`  line ${i + 1}: ${m[1]} — ${line.trim()}`);
});
if (bad.length) {
    console.log('FAIL: top-level names collide with non-configurable window properties');
    console.log(bad.join('\n'));
    process.exit(1);
}
console.log('lint OK: no restricted global shadowing');
