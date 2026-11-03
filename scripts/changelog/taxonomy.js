'use strict';

// Taxonomia do changelog tech: dois eixos de labels, exatamente uma de cada por PR.
//   - tipo (cl:*): o que o PR é;
//   - impacto no parceiro (partner:*): se o parceiro precisa saber, e se quebra contrato.
// Documentação: docs/CHANGELOG_TECH.md.

const TYPE_PREFIX = 'cl:';
const PARTNER_PREFIX = 'partner:';

// A ordem define a ordem das seções no digest. Descrições têm no máximo 100 caracteres (limite do GitHub).
const TYPES = {
  feat: { color: '0E8A16', description: 'Changelog: funcionalidade nova ou mudança de comportamento' },
  fix: { color: 'D93F0B', description: 'Changelog: correção de bug' },
  perf: { color: 'FBCA04', description: 'Changelog: melhoria de desempenho sem mudança de comportamento' },
  security: { color: 'B60205', description: 'Changelog: correção ou reforço de segurança' },
  infra: { color: '5319E7', description: 'Changelog: CI, build, deploy ou infraestrutura' },
  chore: { color: 'C5DEF5', description: 'Changelog: manutenção, refatoração, docs ou testes' },
};

// severity: o classificador só pode subir nessa escala, nunca descer (ver contrato no doc).
const PARTNERS = {
  none: { severity: 0, color: 'EDEDED', description: 'Parceiro: sem impacto para parceiros' },
  additive: { severity: 1, color: 'FEF2C0', description: 'Parceiro: mudança compatível que vale comunicar (campo, endpoint, enum novo)' },
  breaking: { severity: 2, color: 'B60205', description: 'Parceiro: quebra contrato; exige flag api.* e PR de doc; anunciar no BMS' },
};

const TYPE_KEYS = Object.keys(TYPES);
const PARTNER_KEYS = Object.keys(PARTNERS);

// Prefixo Conventional Commits do título -> tipo. Usado só quando o PR não tem label cl:*.
const PREFIX_TO_TYPE = {
  feat: 'feat',
  fix: 'fix',
  hotfix: 'fix',
  perf: 'perf',
  security: 'security',
  sec: 'security',
  ci: 'infra',
  infra: 'infra',
  build: 'infra',
  chore: 'chore',
  refactor: 'chore',
  docs: 'chore',
  test: 'chore',
  style: 'chore',
  revert: 'chore',
};

// tipo(escopo)!: assunto  — escopo e "!" opcionais.
const TITLE_RE = /^\s*([A-Za-z]+)(?:\([^)]*\))?(!)?[ \t]*:[ \t]*(.*)$/;

/** Lista de labels de taxonomia, no formato aceito por `gh label create`. */
function allLabels() {
  return [
    ...TYPE_KEYS.map((k) => ({ name: TYPE_PREFIX + k, ...pick(TYPES[k]) })),
    ...PARTNER_KEYS.map((k) => ({ name: PARTNER_PREFIX + k, ...pick(PARTNERS[k]) })),
  ];
}

function pick({ color, description }) {
  return { color, description };
}

/** Aceita labels como strings ou objetos `{ name }` (formato da API do GitHub). */
function labelNames(labels) {
  return (labels || []).map((l) => (typeof l === 'string' ? l : l && l.name)).filter(Boolean);
}

function keysWithPrefix(labels, prefix, validKeys) {
  return labelNames(labels)
    .filter((n) => n.toLowerCase().startsWith(prefix))
    .map((n) => n.slice(prefix.length).toLowerCase())
    .filter((k) => validKeys.includes(k));
}

/** Tipos presentes nas labels (ex.: ['feat']). Labels cl:* desconhecidas são ignoradas. */
function typesFromLabels(labels) {
  return keysWithPrefix(labels, TYPE_PREFIX, TYPE_KEYS);
}

/** Impactos presentes nas labels (ex.: ['additive']). */
function partnersFromLabels(labels) {
  return keysWithPrefix(labels, PARTNER_PREFIX, PARTNER_KEYS);
}

/** Labels do eixo que não pertencem à taxonomia (ex.: cl:docs). */
function unknownAxisLabels(labels) {
  return labelNames(labels).filter((n) => {
    const lower = n.toLowerCase();
    if (lower.startsWith(TYPE_PREFIX)) return !TYPE_KEYS.includes(lower.slice(TYPE_PREFIX.length));
    if (lower.startsWith(PARTNER_PREFIX)) return !PARTNER_KEYS.includes(lower.slice(PARTNER_PREFIX.length));
    return false;
  });
}

function partnerSeverity(key) {
  return PARTNERS[key] ? PARTNERS[key].severity : -1;
}

/** O impacto mais grave da lista (null se vazia). */
function mostSevere(partnerKeys) {
  return (partnerKeys || []).reduce(
    (worst, k) => (worst === null || partnerSeverity(k) > partnerSeverity(worst) ? k : worst),
    null,
  );
}

/** Decompõe um título Conventional Commits. Retorna null se não houver prefixo reconhecível. */
function parseTitle(title) {
  const m = TITLE_RE.exec(title || '');
  if (!m) return null;
  const type = PREFIX_TO_TYPE[m[1].toLowerCase()];
  if (!type) return null;
  return { type, prefix: m[1].toLowerCase(), bang: Boolean(m[2]), subject: m[3].trim() };
}

function typeFromTitle(title) {
  const parsed = parseTitle(title);
  return parsed ? parsed.type : null;
}

/** Título sem o prefixo Conventional Commits (ou o título inteiro, se não houver prefixo). */
function stripPrefix(title) {
  const parsed = parseTitle(title);
  return parsed && parsed.subject ? parsed.subject : (title || '').trim();
}

module.exports = {
  TYPE_PREFIX,
  PARTNER_PREFIX,
  TYPES,
  PARTNERS,
  TYPE_KEYS,
  PARTNER_KEYS,
  PREFIX_TO_TYPE,
  allLabels,
  labelNames,
  typesFromLabels,
  partnersFromLabels,
  unknownAxisLabels,
  partnerSeverity,
  mostSevere,
  parseTitle,
  typeFromTitle,
  stripPrefix,
};
