#!/usr/bin/env node
// CLI renderer: netlist JSON -> SVG via our netlistsvg wrapper (the stock
// netlistsvg CLI rejects inout port_directions, which interface ports use).
const path = require('path');
const fs = require('fs');
const api = require(path.join(__dirname, '..', 'web-src', 'netlistsvg-entry.js'));

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) {
  console.error('usage: render.js <netlist.json> <out.svg>');
  process.exit(1);
}
const skin = fs.readFileSync(path.join(__dirname, '..', 'web', 'skin.svg'), 'utf8');
const design = JSON.parse(fs.readFileSync(inFile, 'utf8'));
api.render(skin, design).then(svg => {
  fs.writeFileSync(outFile, svg);
}).catch(e => {
  console.error(e);
  process.exit(1);
});
