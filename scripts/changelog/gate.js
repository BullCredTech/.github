'use strict';

// Gate determinístico do changelog tech (check `changelog-gate`).
// Só LÊ labels e campos da descrição. Não classifica nem aplica labels: isso é do classificador
// (ver "Contrato com o classificador" em docs/CHANGELOG_TECH.md).
// Não exige aprovação própria: a revisão normal do PR aprova a classificação, e a aprovação voltada
// ao parceiro acontece no BMS, ao Anunciar.
// Não olha data: a vigência de uma breaking change vive no registro de mudanças programadas.
// Não verifica se a flag existe no changes-api: no merge, a ponte (changelog-bridge) cria a mudança
// programada com a flag, ou anexa o PR à mudança viva que já tem a flag. Mas verifica que a chave
// aparece no CÓDIGO alterado pelo PR: declarar `Flag:` sem usar a flag deixaria a breaking change
// ir direto para produção.

const taxonomy = require('./taxonomy');
const { parseFields } = require('./fields');
const defaultConfig = require('./config.json');

const DOC_URL = 'https://github.com/BullCredTech/.github/blob/main/docs/CHANGELOG_TECH.md';

// Chave de flag de mudança programada: `<superfície>.<recurso>.<mudança>`, superfície `api` ou
// `webhook`, partes em minúsculas, dígitos e `_` (ex.: `api.contracts.remove_bank_code`,
// `webhook.proposal_status.new_payload`). É um subconjunto do formato do changes-api
// (`^[a-z][a-z0-9]*(\.[a-z0-9_]+)+$`, CHECK em flag_rules.key): aceitar algo fora dele faria a
// ponte receber 422 no merge. Sem ambiguidade de backtracking: cada parte começa com "." e "."
// não está na classe.
const FLAG_KEY_RE = /^(?:api|webhook)\.[a-z0-9_]+\.[a-z0-9_]+(?:\.[a-z0-9_]+)*$/;
const FLAG_FORMAT = '`<superfície>.<recurso>.<mudança>`, com superfície `api` ou `webhook` (ex.: `api.contracts.remove_bank_code`)';

// Arquivos que não contam como "código que usa a flag": documentação e testes. Uma chave citada só
// num teste ou num .md não protege o parceiro.
const NON_CODE_RE = /(?:\.(?:md|mdx|txt)$|(?:^|\/)docs\/|\.(?:spec|test)\.[cm]?[jt]sx?$|(?:^|\/)(?:__tests__|tests?)\/)/i;

/**
 * Procura a chave da flag, entre aspas, nas linhas ADICIONADAS do diff dos arquivos de código.
 * files: itens de GET /pulls/{n}/files ({ filename, patch? }). A API omite o patch de arquivo
 * grande ou binário: esses entram em `unreadable`.
 */
function flagUsage(files, key) {
  const quoted = [`'${key}'`, `"${key}"`, `\`${key}\``];
  const found = [];
  const unreadable = [];
  for (const f of files || []) {
    if (NON_CODE_RE.test(f.filename)) continue;
    if (typeof f.patch !== 'string') {
      unreadable.push(f.filename);
      continue;
    }
    const added = f.patch.split('\n').filter((l) => l.startsWith('+') && !l.startsWith('+++'));
    if (added.some((l) => quoted.some((q) => l.includes(q)))) found.push(f.filename);
  }
  return { found, unreadable };
}

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
  // Regex literais + comparação do repo como texto (sem RegExp() dinâmico, bloqueado pelo Semgrep).
  const want = String(docsRepo).toLowerCase();
  const url = /https?:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/i.exec(value);
  if (url && url[1].toLowerCase() === want) return Number(url[2]);
  const short = /(?:^|\s)([\w.-]+\/[\w.-]+)#(\d+)/i.exec(value);
  if (short && short[1].toLowerCase() === want) return Number(short[2]);
  return null;
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
 * files: arquivos do PR (só são necessários em `partner:breaking`; null = não verificar o diff).
 * errors vazio = gate passa.
 */
function evaluate({ labels, body, files = null, config = defaultConfig }) {
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
      errors.push(`\`partner:breaking\` exige o campo \`Flag:\` na descrição, com a chave da feature flag no formato ${FLAG_FORMAT}.`);
    } else if (!FLAG_KEY_RE.test(fields.flag)) {
      errors.push(`O campo \`Flag:\` precisa seguir o formato ${FLAG_FORMAT} (recebido: "${fields.flag}").`);
    } else if (files !== null) {
      const { found, unreadable } = flagUsage(files, fields.flag);
      if (found.length) {
        notes.push(`A flag \`${fields.flag}\` aparece no código alterado: ${found.map((f) => `\`${f}\``).join(', ')}.`);
      } else {
        errors.push(
          `A flag \`${fields.flag}\` não aparece no código alterado por este PR. Uma breaking change precisa ` +
            `entrar desligada, atrás da flag: use \`isEnabled('${fields.flag}', origem)\` ou ` +
            `\`@PartnerFlags('${fields.flag}')\` no código (testes e .md não contam).` +
            (unreadable.length
              ? ` A API do GitHub não mostrou o diff de ${unreadable.length} arquivo(s) grande(s) ` +
                `(${unreadable.slice(0, 5).map((f) => `\`${f}\``).join(', ')}${unreadable.length > 5 ? ', …' : ''}); ` +
                'se a chave estiver só neles, divida o PR.'
              : ''),
        );
      }
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

  // O diff só é lido em `partner:breaking`: é onde o gate confere que a flag está no código.
  const breakingLabel = taxonomy.partnersFromLabels(pr.labels).includes('breaking');
  const files = breakingLabel
    ? await github.paginate('GET /repos/{owner}/{repo}/pulls/{pull_number}/files', {
        owner,
        repo,
        pull_number: pr.number,
        per_page: 100,
      })
    : null;

  const result = evaluate({ labels: pr.labels, body: pr.body, files, config });

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

module.exports = { evaluate, run, docsPrRef, breakingReminder, flagUsage, FLAG_KEY_RE };
