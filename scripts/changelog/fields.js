'use strict';

// Leitura dos campos da descrição do PR (Changelog:, Parceiro:, Flag:, Docs:) e do comentário
// do classificador (<!-- changelog-bot --> + bloco ```json). Ver docs/CHANGELOG_TECH.md.

const BOT_MARKER = '<!-- changelog-bot -->';

const FIELD_NAMES = {
  changelog: 'Changelog',
  parceiro: 'Parceiro',
  flag: 'Flag',
  docs: 'Docs',
};

// Uma linha "Nome: valor", tolerando lista ("- ") e negrito ("**Nome:**").
// ATENÇÃO: só [ \t] entre os dois-pontos e o valor. Com \s, um campo vazio do template
// ("Changelog:" seguido de "Parceiro:" na linha de baixo) capturaria a linha seguinte.
// Regex literais (uma por campo), sem RegExp() dinâmico: o Semgrep da org bloqueia regex montada.
const FIELD_RES = {
  changelog: /^[ \t]*(?:[-*][ \t]+)?(?:\*\*)?Changelog(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(.*)$/im,
  parceiro: /^[ \t]*(?:[-*][ \t]+)?(?:\*\*)?Parceiro(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(.*)$/im,
  flag: /^[ \t]*(?:[-*][ \t]+)?(?:\*\*)?Flag(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(.*)$/im,
  docs: /^[ \t]*(?:[-*][ \t]+)?(?:\*\*)?Docs(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(.*)$/im,
};

/** Remove comentários HTML (o template explica os campos dentro de <!-- -->) e normaliza quebras. */
function cleanBody(body) {
  return String(body || '')
    .replace(/\r\n?/g, '\n')
    .replace(/<!--[\s\S]*?-->/g, '');
}

function cleanValue(raw) {
  const v = (raw || '').replace(/`/g, '').trim();
  return v === '' ? null : v;
}

/** { changelog, parceiro, flag, docs } — cada um string ou null (ausente ou vazio). */
function parseFields(body) {
  const text = cleanBody(body);
  const out = {};
  for (const [key, re] of Object.entries(FIELD_RES)) {
    const m = re.exec(text);
    out[key] = m ? cleanValue(m[1]) : null;
  }
  return out;
}

/** O comentário do classificador: o último cujo corpo começa com o marcador. */
function findBotComment(comments) {
  const found = (comments || []).filter((c) => String((c && c.body) || '').trimStart().startsWith(BOT_MARKER));
  return found.length ? found[found.length - 1] : null;
}

/**
 * Extrai o JSON do primeiro bloco ```json do comentário do classificador.
 * Retorna { data } ou { error } — nunca lança.
 */
function parseBotComment(body) {
  const text = String(body || '').replace(/\r\n?/g, '\n');
  if (!text.trimStart().startsWith(BOT_MARKER)) return { error: 'comentário sem o marcador <!-- changelog-bot -->' };
  const m = /```json[ \t]*\n([\s\S]*?)\n[ \t]*```/i.exec(text);
  if (!m) return { error: 'comentário sem bloco ```json' };
  try {
    const data = JSON.parse(m[1]);
    if (!data || typeof data !== 'object' || Array.isArray(data)) return { error: 'o JSON não é um objeto' };
    return { data };
  } catch (e) {
    return { error: `JSON inválido (${e.message})` };
  }
}

module.exports = { BOT_MARKER, FIELD_NAMES, parseFields, cleanBody, findBotComment, parseBotComment };
