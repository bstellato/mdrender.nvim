#!/usr/bin/env node
// Math renderer for mdrender.nvim.
// Reads one JSON request per line on stdin and writes one JSON reply per line.
//   request: {id, tex, display, fg, cw, ch, scale, max_cols, min_rows, inline_em, display_em,
//             baseline, weight, macros}
//   reply:   {id, ok: true, png: <base64>, cols, rows} or {id, ok: false, error}
// The PNG is drawn on a canvas that is a whole number of terminal cells.

const readline = require('readline');
const { mathjax } = require('mathjax-full/js/mathjax.js');
const { TeX } = require('mathjax-full/js/input/tex.js');
const { SVG } = require('mathjax-full/js/output/svg.js');
const { liteAdaptor } = require('mathjax-full/js/adaptors/liteAdaptor.js');
const { RegisterHTMLHandler } = require('mathjax-full/js/handlers/html.js');
require('mathjax-full/js/input/tex/AllPackages.js'); // registers every package
const { Resvg } = require('@resvg/resvg-js');

const PACKAGES = [
  'base', 'ams', 'newcommand', 'boldsymbol', 'mathtools', 'color', 'cancel',
  'braket', 'bbox', 'unicode', 'textmacros', 'configmacros',
];

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);

let doc = null;
let macrosKey = null;

function document(macros) {
  const key = JSON.stringify(macros || {});
  if (!doc || key !== macrosKey) {
    const tex = new TeX({ packages: PACKAGES, macros: macros || {} });
    const svg = new SVG({ fontCache: 'none' });
    doc = mathjax.document('', { InputJax: tex, OutputJax: svg });
    macrosKey = key;
  }
  return doc;
}

function render(req) {
  const node = document(req.macros).convert(req.tex, { display: !!req.display });
  let svg = adaptor.innerHTML(node);

  const err = svg.match(/data-mjx-error="([^"]*)"/);
  if (err) throw new Error(err[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&'));

  // The viewBox is in 1/1000 em, with the baseline at y = 0.
  const vb = svg.match(/viewBox="([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)"/);
  if (!vb) throw new Error('no viewBox in MathJax output');
  const [minY, vw, vh] = [parseFloat(vb[2]), parseFloat(vb[3]), parseFloat(vb[4])];

  const { cw, ch } = req;
  const scale = req.scale || 2;
  const em = ch * (req.display ? req.display_em || 1.0 : req.inline_em || 0.9);
  let w = (vw / 1000) * em;
  let h = (vh / 1000) * em;
  let ascent = (-minY / 1000) * em;

  let cols, rows, x, y;
  if (req.display) {
    const maxW = (req.max_cols || 80) * cw;
    if (w > maxW) {
      const s = maxW / w;
      w *= s; h *= s;
    }
    cols = Math.max(1, Math.ceil(w / cw));
    // At least one row per source line, so rendering never changes the line count.
    rows = Math.max(1, Math.ceil((h + ch * 0.3) / ch), req.min_rows || 0);
    x = (cols * cw - w) / 2;
    y = (rows * ch - h) / 2;
  } else {
    // Inline math always takes one row: shrink formulas taller than a cell.
    const maxH = ch * 0.98;
    if (h > maxH) {
      const s = maxH / h;
      w *= s; h *= s; ascent *= s;
    }
    rows = 1;
    // No side padding: like TeX, spacing comes from the spaces in the surrounding text.
    cols = Math.max(1, Math.ceil(w / cw - 0.08));
    x = (cols * cw - w) / 2;
    // Sit the math baseline on the text baseline when it fits.
    y = ch * (req.baseline || 0.76) - ascent;
    y = Math.min(Math.max(y, 0), ch - h);
  }

  const W = cols * cw * scale;
  const H = rows * ch * scale;
  // A thin outline makes the light TeX fonts readable next to terminal text.
  const weight = req.weight == null ? 12 : req.weight;
  svg = svg
    .replace('stroke-width="0"', `stroke-width="${weight}"`)
    .replace(/currentColor/g, req.fg || '#000000')
    .replace(/<svg ([^>]*)>/, (_, attrs) => {
      const kept = attrs
        .replace(/\s?(width|height|style)="[^"]*"/g, '')
        .trim();
      return `<svg x="${x * scale}" y="${y * scale}" width="${w * scale}" height="${h * scale}" ${kept}>`;
    });
  const canvas =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${svg}</svg>`;

  const png = new Resvg(canvas, {
    fitTo: { mode: 'original' },
    font: { loadSystemFonts: false }, // MathJax output is paths only
  }).render().asPng();
  return { png: png.toString('base64'), cols, rows };
}

if (require.main === module) {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let req;
    try {
      req = JSON.parse(line);
    } catch (e) {
      return;
    }
    let reply;
    try {
      reply = Object.assign({ id: req.id, ok: true }, render(req));
    } catch (e) {
      reply = { id: req.id, ok: false, error: String(e.message || e) };
    }
    process.stdout.write(JSON.stringify(reply) + '\n');
  });
  rl.on('close', () => process.exit(0));
}

module.exports = { render };
