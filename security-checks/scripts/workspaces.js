#!/usr/bin/env node
// Auxiliar do license.sh para npm/yarn workspaces. Sem rede. Falha fechado: package.json inválido ou
// `workspaces` malformado saem com código 1 e mensagem em stderr, nunca como "sem workspaces".
// Quem diz QUAIS são os workspaces é o gerenciador (npm query / yarn workspaces info), não este script.
//
//   declared <dir>              -> true|false: o package.json de <dir> declara workspaces?
//   npmdirs  <dir>  (stdin)     -> diretórios (absolutos) a partir do JSON de `npm query .workspace`
//   yarndirs <dir>  (stdin)     -> idem, a partir da saída de `yarn workspaces info --json` (v1)
//   ids   <dir> [ws-dir...]     -> "name@version;..." do <dir> e dos workspaces
//   union <dir> [ws-dir...]     -> package.json sintético com as deps de produção do <dir> e dos
//                                  workspaces, sem os pacotes do próprio repo (o license-checker só lê
//                                  as deps do package.json inicial)
'use strict';
const fs = require('fs');
const path = require('path');

class Falha extends Error {}
const falha = (m) => { throw new Falha(m); };

function lerPkg(d) {
  const f = path.join(d, 'package.json');
  let txt;
  try { txt = fs.readFileSync(f, 'utf8'); } catch (e) { return falha(`não consegui ler ${f}`); }
  let j;
  try { j = JSON.parse(txt); } catch (e) { return falha(`JSON inválido em ${f}`); }
  if (j === null || typeof j !== 'object' || Array.isArray(j)) falha(`${f} precisa ser um objeto`);
  return j;
}

function declarados(pkg, f) {
  let ws = pkg.workspaces;
  if (ws === undefined) return false;
  if (ws !== null && typeof ws === 'object' && !Array.isArray(ws)) ws = ws.packages;
  if (!Array.isArray(ws) || !ws.every((w) => typeof w === 'string')) {
    falha(`campo workspaces malformado em ${f}`);
  }
  return ws.length > 0;
}

function lerStdin() { return fs.readFileSync(0, 'utf8'); }

function pegaJson(txt, abre, fecha) {
  const i = txt.indexOf(abre), j = txt.lastIndexOf(fecha);
  if (i < 0 || j < i) falha('resposta do gerenciador não é JSON');
  try { return JSON.parse(txt.slice(i, j + 1)); } catch (e) { return falha('resposta do gerenciador não é JSON'); }
}

function main() {
  const [modo, raiz, ...resto] = process.argv.slice(2);
  if (!['declared', 'npmdirs', 'yarndirs', 'ids', 'union'].includes(modo) || !raiz) {
    falha('uso: workspaces.js declared|npmdirs|yarndirs|ids|union <dir> [ws-dir...]');
  }
  if (modo === 'declared') {
    console.log(declarados(lerPkg(raiz), path.join(raiz, 'package.json')) ? 'true' : 'false');
  } else if (modo === 'npmdirs') {
    const arr = pegaJson(lerStdin(), '[', ']');
    if (!Array.isArray(arr)) falha('npm query não retornou uma lista');
    arr.forEach((w) => {
      // `location` (relativo à raiz do projeto) é mais confiável que `path`; este vira reserva.
      const p = w && (typeof w.location === 'string' ? path.join(raiz, w.location) : (typeof w.path === 'string' ? w.path : null));
      if (!p) falha('item do npm query sem path');
      console.log(p);
    });
  } else if (modo === 'yarndirs') {
    const obj = pegaJson(lerStdin(), '{', '}');
    Object.keys(obj).forEach((k) => {
      if (!obj[k] || typeof obj[k].location !== 'string') falha(`workspace ${k} sem location`);
      console.log(path.join(raiz, obj[k].location));
    });
  } else {
    const pkgs = [raiz, ...resto].map(lerPkg);
    if (modo === 'ids') {
      console.log(pkgs.filter((p) => p.name).map((p) => (p.version ? `${p.name}@${p.version}` : p.name)).join(';'));
    } else {
      const proprios = new Set(pkgs.map((p) => p.name));
      const deps = {};
      pkgs.forEach((p) => Object.assign(deps, p.dependencies || {}, p.optionalDependencies || {}));
      proprios.forEach((n) => delete deps[n]);
      const base = pkgs[0];
      console.log(JSON.stringify({ name: base.name || 'org-workspace-root', version: base.version || '0.0.0', private: true, dependencies: deps }));
    }
  }
}

try { main(); } catch (e) {
  if (e instanceof Falha) { console.error(`workspaces.js: ${e.message}`); process.exit(1); }
  throw e;
}
