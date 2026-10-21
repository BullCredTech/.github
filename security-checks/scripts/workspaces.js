#!/usr/bin/env node
// Resolve os workspaces npm/yarn de um package.json (sem rede, só leitura).
//   workspaces.js dirs <dir>   -> um diretório de workspace por linha (caminhos sob <dir>)
//   workspaces.js ids  <dir>   -> "name@version;..." do próprio <dir> e de cada workspace
//   workspaces.js union <dir>  -> package.json sintético: dependências de produção da raiz e de todos os
//                                 workspaces (menos os pacotes do próprio repo), para o license-checker
//                                 percorrer tudo num só passe (ele só lê as deps do package.json inicial)
// Padrões suportados: caminho exato, "pasta/*" e "pasta/**"; "!padrão" exclui; node_modules é ignorado.
'use strict';
const fs = require('fs');
const path = require('path');

const [modo, raiz] = process.argv.slice(2);
if (!['dirs', 'ids', 'union'].includes(modo) || !raiz) {
  console.error('uso: workspaces.js dirs|ids|union <dir>');
  process.exit(2);
}

const lerPkg = (d) => {
  try { return JSON.parse(fs.readFileSync(path.join(d, 'package.json'), 'utf8')); } catch (e) { return null; }
};
const subdirs = (d) => {
  try {
    return fs.readdirSync(d, { withFileTypes: true })
      .filter((e) => e.isDirectory() && e.name !== 'node_modules' && !e.name.startsWith('.'))
      .map((e) => path.join(d, e.name));
  } catch (e) { return []; }
};
const recursivo = (d) => subdirs(d).flatMap((s) => [s, ...recursivo(s)]);

function expandir(padrao) {
  const p = padrao.replace(/^\.\//, '').replace(/\/+$/, '');
  if (p.endsWith('/**')) return recursivo(path.join(raiz, p.slice(0, -3)));
  if (p.endsWith('/*')) return subdirs(path.join(raiz, p.slice(0, -2)));
  if (p.includes('*')) return [];
  return [path.join(raiz, p)];
}

function workspaces() {
  const pkg = lerPkg(raiz);
  if (!pkg) return [];
  let ws = pkg.workspaces;
  if (ws && !Array.isArray(ws)) ws = ws.packages;
  if (!Array.isArray(ws)) return [];
  const inc = ws.filter((w) => typeof w === 'string' && !w.startsWith('!'));
  const exc = new Set(ws.filter((w) => typeof w === 'string' && w.startsWith('!')).flatMap((w) => expandir(w.slice(1))));
  const dirs = inc.flatMap(expandir).filter((d) => !exc.has(d) && fs.existsSync(path.join(d, 'package.json')));
  return [...new Set(dirs)].sort();
}

const dirs = workspaces();
if (modo === 'dirs') {
  dirs.forEach((d) => console.log(d));
} else if (modo === 'union') {
  const pkgs = [raiz, ...dirs].map(lerPkg).filter(Boolean);
  const proprios = new Set(pkgs.map((p) => p.name));
  const deps = {};
  pkgs.forEach((p) => Object.assign(deps, p.dependencies || {}, p.optionalDependencies || {}));
  proprios.forEach((n) => delete deps[n]);
  const base = lerPkg(raiz) || {};
  console.log(JSON.stringify({ name: base.name || 'org-workspace-root', version: base.version || '0.0.0', private: true, dependencies: deps }));
} else {
  const ids = [raiz, ...dirs].map(lerPkg).filter((p) => p && p.name)
    .map((p) => (p.version ? `${p.name}@${p.version}` : p.name));
  console.log(ids.join(';'));
}
