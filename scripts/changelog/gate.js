'use strict';

// Gate determinístico do changelog tech (check `changelog-gate`).
// Só LÊ labels, campos da descrição e reviews. Não classifica nem aplica labels: isso é do
// classificador (ver "Contrato com o classificador" em docs/CHANGELOG_TECH.md).
// Não olha data: a vigência de uma breaking change vive no registro de mudanças programadas.

const taxonomy = require('./taxonomy');
const { parseFields, escapeRe } = require('./fields');
const defaultConfig = require('./config.json');

const DOC_URL = 'https://github.com/BullCredTech/.github/blob/main/docs/CHANGELOG_TECH.md';

// Chave de flag de API: "api." seguido de minúsculas, dígitos e separadores (. _ -).
const FLAG_KEY_RE = /^api\.[a-z0-9]+(?:[._-][a-z0-9]+)*$/;

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

/** Última review de cada aprovador que conta (COMMENTED e PENDING não mudam o estado). */
function approvalBy(reviews, approvers) {
  const wanted = new Set(approvers.map((a) => a.toLowerCase()));
  const lastState = new Map();
  for (const r of reviews || []) {
    const login = r && r.user && r.user.login ? r.user.login.toLowerCase() : null;
    if (!login || !wanted.has(login)) continue;
    if (r.state === 'COMMENTED' || r.state === 'PENDING') continue;
    lastState.set(login, { state: r.state, login: r.user.login });
  }
  return [...lastState.values()].filter((v) => v.state === 'APPROVED').map((v) => v.login);
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

/**
 * TODO(catálogo de flags): verificar que `flagKey` existe no catálogo de feature flags do repo
 * (adicionada neste diff ou já existente). Depende da generalização de `sdk_feature_flags` para
 * `feature_flags` com namespace `api.*` no bull-module-proposals (plano, seção C.1). Até lá o gate
 * só valida o formato da chave. Quando o catálogo existir, implementar aqui e devolver
 * { ok: false, message } se a chave não estiver lá; o resto do gate não muda.
 */
async function checkFlagInCatalog(/* flagKey, { github, owner, repo, pr } */) {
  return { ok: true, skipped: true, message: 'verificação no catálogo de flags ainda não implementada (só o formato foi validado)' };
}

/**
 * Avaliação pura. Recebe o estado do PR e devolve { errors, notes }.
 * errors vazio = gate passa.
 */
function evaluate({ labels, body, reviews, config = defaultConfig }) {
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
    const approvers = config.partnerApprovers || [];
    if (approvers.length === 0) {
      errors.push(
        '`partner:breaking` exige aprovação de parcerias, mas `partnerApprovers` está vazio em ' +
          '`scripts/changelog/config.json` do BullCredTech/.github. O gate falha fechado até alguém ' +
          'preencher a lista (PR no repo .github).',
      );
    } else {
      const approvedBy = approvalBy(reviews, approvers);
      if (approvedBy.length === 0) {
        errors.push(
          `\`partner:breaking\` exige aprovação (review "Approve") de um destes: ${approvers.map((a) => `@${a}`).join(', ')}. ` +
            'Vale a última review de cada um; comentário não conta e aprovação descartada ou seguida de "Request changes" deixa de valer.',
        );
      } else {
        notes.push(`Aprovado para parceiro por ${approvedBy.map((a) => `@${a}`).join(', ')}.`);
      }
    }

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

  const isBreaking = taxonomy.partnersFromLabels(pr.labels).includes('breaking');
  const reviews = isBreaking
    ? await github.paginate('GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews', {
        owner,
        repo,
        pull_number: pr.number,
        per_page: 100,
      })
    : [];

  const result = evaluate({ labels: pr.labels, body: pr.body, reviews, config });

  if (isBreaking && result.fields.flag && FLAG_KEY_RE.test(result.fields.flag)) {
    const flag = await checkFlagInCatalog(result.fields.flag, { github, owner, repo, pr });
    if (!flag.ok) result.errors.push(flag.message);
    else if (flag.skipped) result.notes.push(`Flag \`${result.fields.flag}\`: ${flag.message}.`);
  }

  for (const n of result.notes) core.info(n);

  if (result.errors.length) {
    core.setFailed(
      [`changelog-gate: ${result.errors.length} pendência(s) no PR #${pr.number}:`, ...result.errors.map((e) => `- ${e}`), `Como resolver: ${DOC_URL}`].join('\n'),
    );
    return;
  }

  const labels = taxonomy.labelNames(pr.labels).filter((n) => /^(cl|partner):/i.test(n));
  core.info(`changelog-gate: OK — PR #${pr.number} com ${labels.join(' + ')}.`);
}

module.exports = { evaluate, run, approvalBy, docsPrRef, checkFlagInCatalog, FLAG_KEY_RE };
