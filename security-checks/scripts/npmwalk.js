#!/usr/bin/env node
// Inventário de licenças de TUDO que o npm/yarn instalou (node_modules em qualquer profundidade).
// Substitui o license-checker, que só segue as deps do package.json inicial e perde pacotes aninhados.
//
// Uso: npmwalk.js <raiz> [--min N] [--expect <dir-de-workspace>...]
// Saída: JSON [{Name, Version, Path, License, LicenseText?}], para `licenses.py npm`.
//
// Regras:
//  - percorre node_modules/<nome> e node_modules/@escopo/<nome>, e o node_modules aninhado de cada um
//    (é onde ficam as versões conflitantes que não subiram);
//  - pacote próprio = SÓ a raiz e os diretórios de workspace informados em --expect (vêm do npm query /
//    yarn info): não são checados, mas o node_modules deles é percorrido;
//  - todo o resto é de terceiro e é checado, inclusive "private": true e qualquer symlink (para
//    vendor/ dentro do repo, para fora dele...);
//  - cada pacote é identificado pelo caminho real (não por nome@versão): duas cópias da mesma versão
//    em lugares diferentes são duas entradas;
//  - sem campo license/licenses, tenta o texto de LICENSE/LICENSE.md/LICENSE.txt/COPYING (vai em
//    LicenseText para o licenses.py reconhecer); valor presente mas estranho vai como JSON, para
//    reprovar na allowlist;
//  - falha fechado: symlink quebrado, pacote sem package.json legível, workspace esperado que não está
//    instalado, ou menos de N pacotes (--min) => exit 1.
'use strict';
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const raiz = args.shift();
let min = 0;
const esperados = [];
while (args.length) {
  const a = args.shift();
  if (a === '--min') min = Number(args.shift());
  else if (a === '--expect') esperados.push(args.shift());
  else { console.error(`npmwalk: argumento desconhecido: ${a}`); process.exit(2); }
}
if (!raiz) { console.error('uso: npmwalk.js <raiz> [--min N] [--expect dir...]'); process.exit(2); }

const erros = [];
let raizReal;
try { raizReal = fs.realpathSync(raiz); } catch (e) { console.error(`npmwalk: raiz inexistente: ${raiz}`); process.exit(1); }

const visitados = new Set();
const pacotes = new Map();
const ligados = new Set();
const proprios = new Set([raizReal]);
for (const e of esperados) { try { proprios.add(fs.realpathSync(e)); } catch (x) { /* reportado abaixo */ } }

function relativo(real) {
  const rel = path.relative(raizReal, real);
  const dentro = !rel.startsWith('..') && !path.isAbsolute(rel);
  return { dentro, rel };
}

const ARQUIVOS_LICENCA = new Set(['license', 'license.md', 'license.txt', 'copying']);

function licenca(pj, dir) {
  const l = pj.license;
  if (typeof l === 'string' && l.trim() !== '') return { License: l };
  if (l && typeof l === 'object' && !Array.isArray(l) && typeof l.type === 'string' && l.type !== '') return { License: l.type };
  if (l !== undefined && l !== null && !(typeof l === 'string')) return { License: JSON.stringify(l) };
  if (Array.isArray(pj.licenses) && pj.licenses.length) {
    const t = pj.licenses.map((x) => (typeof x === 'string' ? x : (x && x.type) || '')).filter(Boolean);
    if (t.length) return { License: t.join(' OR ') };
    return { License: JSON.stringify(pj.licenses) };
  }
  if (pj.licenses !== undefined && pj.licenses !== null) return { License: JSON.stringify(pj.licenses) };
  // ausente: o texto do arquivo de licença, se houver
  let texto = '';
  try {
    const nome = fs.readdirSync(dir).sort().find((n) => ARQUIVOS_LICENCA.has(n.toLowerCase()));
    if (nome) texto = fs.readFileSync(path.join(dir, nome), 'utf8').slice(0, 4000);
  } catch (e) { /* sem arquivo */ }
  return { License: '', LicenseText: texto };
}

function percorrer(nm) {
  let real;
  try { real = fs.realpathSync(nm); } catch (e) { return; } // sem node_modules aqui
  if (visitados.has(real)) return;
  visitados.add(real);
  let nomes;
  try { nomes = fs.readdirSync(nm).sort(); } catch (e) { erros.push(`não consegui listar ${nm}`); return; }
  for (const n of nomes) {
    if (n.startsWith('.')) continue; // .bin, .cache, .package-lock.json, .yarn-integrity...
    const p = path.join(nm, n);
    if (n.startsWith('@')) {
      let subs;
      try { subs = fs.readdirSync(p).sort(); } catch (e) { continue; }
      subs.filter((s) => !s.startsWith('.')).forEach((s) => pacote(path.join(p, s)));
    } else {
      pacote(p);
    }
  }
}

function pacote(p) {
  let lst;
  try { lst = fs.lstatSync(p); } catch (e) { return; }
  if (!lst.isDirectory() && !lst.isSymbolicLink()) return;
  let real;
  try { real = fs.realpathSync(p); } catch (e) { erros.push(`symlink quebrado: ${p}`); return; }
  const { dentro, rel } = relativo(real);
  if (proprios.has(real)) {
    ligados.add(real);                         // a raiz ou um workspace informado
    percorrer(path.join(real, 'node_modules')); // mas as deps não içadas dele valem
    return;
  }
  let pj;
  try { pj = JSON.parse(fs.readFileSync(path.join(real, 'package.json'), 'utf8')); } catch (e) {
    erros.push(`package.json ilegível em ${p}`); return;
  }
  if (!pj || typeof pj !== 'object') { erros.push(`package.json inválido em ${p}`); return; }
  const nome = pj.name || path.basename(p);
  const versao = pj.version || '?';
  const caminho = dentro ? rel : real;
  if (!pacotes.has(real)) pacotes.set(real, Object.assign({ Name: nome, Version: versao, Path: caminho }, licenca(pj, real)));
  percorrer(path.join(real, 'node_modules'));
}

percorrer(path.join(raizReal, 'node_modules'));

for (const e of esperados) {
  let real;
  try { real = fs.realpathSync(e); } catch (x) { erros.push(`workspace inexistente: ${e}`); continue; }
  if (!ligados.has(real)) erros.push(`workspace não instalado em node_modules: ${e}`);
}
if (pacotes.size < min) erros.push(`esperava ao menos ${min} pacote(s) instalado(s) e achei ${pacotes.size}`);

if (erros.length) {
  erros.forEach((m) => console.error(`npmwalk: ${m}`));
  process.exit(1);
}
console.log(JSON.stringify([...pacotes.values()].sort((a, b) => a.Path.localeCompare(b.Path))));
