'use strict';

// Gate determinístico do changelog tech (check `changelog-gate`).
// Só LÊ labels e campos da descrição. Não classifica nem aplica labels: isso é do classificador
// (ver "Contrato com o classificador" em docs/CHANGELOG_TECH.md).
// Não exige aprovação própria: a revisão normal do PR aprova a classificação, e a aprovação voltada
// ao parceiro acontece no BMS, ao Anunciar.
// Não olha data: a vigência de uma breaking change vive no registro de mudanças programadas.
// Não verifica se a flag existe: no merge, a ponte (changelog-bridge) cria a mudança programada com
// a flag no changes-api, ou anexa o PR à mudança viva que já tem a flag.

const taxonomy = require('./taxonomy');
const { parseFields, escapeRe } = require('./fields');
const defaultConfig = require('./config.json');

const DOC_URL = 'https://github.com/BullCredTech/.github/blob/main/docs/CHANGELOG_TECH.md';

// Chave de flag de API: o formato de chave do changes-api (`^[a-z][a-z0-9]*(\.[a-z0-9_]+)+$`,
// CHECK em flag_rules.key) com o namespace `api`. Aceitar algo fora dele faria a ponte receber 422
// ao criar a mudança programada no merge. Sem ambiguidade de backtracking: cada repetição começa
// com "." e "." não está na classe.
const FLAG_KEY_RE = /^api(?:\.[a-z0-9_]+)+$/;

function list(keys, prefix) {
  return keys.map((k) => `\`${prefix}${k}\``).join(', ');
}

function axisErrors(found, keys, prefix, axisName) {
  if (found.length === 1) return [];
  if (found.length === 0) {
    return [`Falta a label de ${axisName}: aplique exatamente uma entre ${list(keys, prefix)}.`];
  }
  return [`Há ${found.length} labels de ${axisName} (${list(found, prefix)}): deixe só uma.`];
}

/** Aceita a URL do PR ou a forma curta owner/repo#N, desde que seja no repo de docs. */
function docsPrRef(value, docsRepo) {
  if (!value) return null;
  const repo = escapeRe(docsRepo);
  const url = new RegExp(`https?://github\\.com/${repo}/pull/(\\d+)`, 'i').exec(value);
  if (url) return Number(url[1]);
  const short = new RegExp(`(?:^|\\s)${repo}#(\\d+)`, 'i').exec(value);
  return short ? Number(short[1]) : null;
}

/** Lembrete do log de sucesso de um breaking: o merge não comunica nada ao parceiro sozinho. */
function breakingReminder(flagKey) {
  return (
    'Lembrete: a mudança só chega ao parceiro quando alguém clicar em Anunciar no BMS. No merge, a ponte cria o ' +
    `rascunho da mudança programada da flag \`${flagKey}\` (ou anexa este PR à mudança que já tem a flag); ` +
    'até o anúncio, nada vai para o /changelog nem para o parceiro.'
  );
}

/**
 * Avaliação pura. Recebe o estado do PR e devolve { errors, notes }.
 * errors vazio = gate passa.
 */
function evaluate({ labels, body, config = defaultConfig }) {
  const errors = [];
  const notes = [];

  const types = taxonomy.typesFromLabels(labels);
  const partners = taxonomy.partnersFromLabels(labels);
  errors.push(...axisErrors(types, taxonomy.TYPE_KEYS, taxonomy.TYPE_PREFIX, 'tipo'));
  errors.push(...axisErrors(partners, taxonomy.PARTNER_KEYS, taxonomy.PARTNER_PREFIX, 'impacto no parceiro'));

  const unknown = taxonomy.unknownAxisLabels(labels);
  if (unknown.length) notes.push(`Labels fora da taxonomia, ignoradas: ${unknown.map((l) => `\`${l}\``).join(', ')}.`);

  const fields = parseFields(body);
  const breaking = partners.includes('breaking');

  if (breaking) {
    const docsRepo = config.docsRepo || 'BullCredTech/bull-api-docs-gitbook';
    if (!fields.docs) {
      errors.push(`\`partner:breaking\` exige o campo \`Docs:\` na descrição, com o link do PR em ${docsRepo}.`);
    } else if (docsPrRef(fields.docs, docsRepo) === null) {
      errors.push(`O campo \`Docs:\` precisa apontar para um PR de ${docsRepo} (recebido: "${fields.docs}").`);
    }

    if (!fields.flag) {
      errors.push('`partner:breaking` exige o campo `Flag:` na descrição, com a chave da feature flag (formato `api.<nome>`).');
    } else if (!FLAG_KEY_RE.test(fields.flag)) {
      errors.push(`O campo \`Flag:\` precisa ser uma chave no formato \`api.<nome>\` (recebido: "${fields.flag}").`);
    }
  }

  if (partners.some((p) => p !== 'none') && !fields.parceiro) {
    notes.push('Sem `Parceiro:` na descrição: o texto para o parceiro virá do classificador (não bloqueia).');
  }

  return { errors, notes, fields, breaking };
}

async function run({ github, context, core, config = defaultConfig }) {
  const payloadPr = context.payload && context.payload.pull_request;
  if (!payloadPr) {
    core.setFailed(`changelog-gate: evento "${context.eventName}" sem pull_request no payload.`);
    return;
  }
  const { owner, repo } = context.repo;

  // O ruleset escolhe os repos, mas o workflow também roda no próprio .github e em qualquer repo
  // que entre no ruleset antes do config.json: fora do piloto, o gate não cobra nada.
  if (!config.repos.includes(repo)) {
    core.info(`changelog-gate: ${owner}/${repo} não está no piloto (scripts/changelog/config.json). Nada a avaliar.`);
    return;
  }

  // Relê o PR: num re-run o payload é o do evento original, e as labels/descrição podem ter mudado.
  const { data: pr } = await github.request('GET /repos/{owner}/{repo}/pulls/{pull_number}', {
    owner,
    repo,
    pull_number: payloadPr.number,
  });

  if (pr.base.ref !== config.baseBranch) {
    core.info(`changelog-gate: PR #${pr.number} aponta para "${pr.base.ref}", não "${config.baseBranch}". Nada a avaliar.`);
    return;
  }

  const result = evaluate({ labels: pr.labels, body: pr.body, config });

  for (const n of result.notes) core.info(n);

  if (result.errors.length) {
    core.setFailed(
      [`changelog-gate: ${result.errors.length} pendência(s) no PR #${pr.number}:`, ...result.errors.map((e) => `- ${e}`), `Como resolver: ${DOC_URL}`].join('\n'),
    );
    return;
  }

  const labels = taxonomy.labelNames(pr.labels).filter((n) => /^(cl|partner):/i.test(n));
  core.info(`changelog-gate: OK — PR #${pr.number} com ${labels.join(' + ')}.`);
  // Notice, e não só log: aparece no resumo do check, sem abrir o job.
  if (result.breaking) core.notice(breakingReminder(result.fields.flag));
}

module.exports = { evaluate, run, docsPrRef, breakingReminder, FLAG_KEY_RE };
