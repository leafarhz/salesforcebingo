// Injects the network data into the artifact template.
const fs = require('fs');
const data = fs.readFileSync(__dirname + '/network.json', 'utf8');
const tpl = fs.readFileSync(__dirname + '/template.html', 'utf8');
const out = tpl.replace('/*__DATA__*/null', data);
fs.writeFileSync(__dirname + '/network.html', out);
console.log('wrote network.html —', (out.length / 1024).toFixed(1) + 'kb');
