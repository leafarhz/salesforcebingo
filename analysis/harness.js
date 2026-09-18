// Minimal DOM stub: runs the artifact's script to surface runtime errors
// without a browser.
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync('/tmp/extracted.js', 'utf8');

const tokens = {
    '--warm-1': '#ffd2b4', '--warm-2': '#ffa87c', '--warm-3': '#ff8a5b', '--warm-4': '#e0603a',
    '--edge': '#3a5a78', '--edge-hi': '#7fb4dd', '--surface': '#17222f',
    '--ground': '#0e1621', '--faint': '#4d6076', '--ink': '#edf1f5', '--muted': '#8697a9',
    '--mono': "ui-monospace, Menlo, monospace"
};

const ctx2d = new Proxy({}, {
    get: (t, k) => {
        if (k === 'setTransform' || k === 'clearRect' || k === 'beginPath' || k === 'arc' ||
            k === 'fill' || k === 'stroke' || k === 'moveTo' || k === 'lineTo' ||
            k === 'fillText') return () => {};
        return t[k];
    },
    set: (t, k, v) => { t[k] = v; return true; }
});

const els = {};
const mkEl = (id) => (els[id] = els[id] || {
    id,
    innerHTML: '',
    getContext: () => ctx2d,
    getBoundingClientRect: () => ({ width: 1200, height: 700, left: 0, top: 0 }),
    addEventListener: () => {},
    width: 0, height: 0,
    style: {}
});

const sandbox = {
    console,
    document: {
        getElementById: (id) => mkEl(id),
        documentElement: {}
    },
    getComputedStyle: () => ({ getPropertyValue: (k) => tokens[k] ?? '' }),
    matchMedia: () => ({ matches: false }),
    requestAnimationFrame: () => {},
    addEventListener: () => {},
    Math, JSON, Set, Map, Array, Object, String, Number, Infinity, isNaN
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

try {
    vm.createContext(sandbox);
    vm.runInContext(src, sandbox, { filename: 'artifact.js' });
    console.log('RAN CLEAN');
    console.log('  stats html length:', (els.stats?.innerHTML || '').length);
    console.log('  rank  html length:', (els.rank?.innerHTML || '').length);
    console.log('  most  html length:', (els.most?.innerHTML || '').length);
} catch (e) {
    console.log('THREW:', e.name + ':', e.message);
    console.log(e.stack.split('\n').slice(0, 5).join('\n'));
}
