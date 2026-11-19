'use strict';

// Digest do changelog tech no Slack: PRs mergeados na janela, agrupados por impacto no parceiro e tipo.
// Só lê labels, a descrição do PR e o comentário do classificador. Ver docs/CHANGELOG_TECH.md.

const taxonomy = require('./taxonomy');
const { parseFields, findBotComment, parseBotComment } = require('./fields');
const defaultConfig = require('./config.json');

const SECTIONS = [
  { key: 'breaking', title: '🔴 Quebra contrato com parceiro' },
  { key: 'additive', title: '🟡 Comunicar ao parceiro' },
  { key: 'feat', title: '✨ Novidades' },
  { key: 'fix', title: '🐛 Correções' },
  { key: 'perf', title: '⚡ Performance' },
  { key: 'security', title: '🔒 Segurança' },
  { key: 'unknown', title: '❔ Sem classificação (sem label e sem prefixo reconhecível no título)' },
];
const COUNT_ONLY = ['infra', 'chore'];

const SUMMARY_MAX = 280;
// O Slack trunca mensagens acima de 40.000 caracteres.
const MESSAGE_MAX = 39000;

// ---------------------------------------------------------------- datas e fuso

function tzOffsetMinutes(date, tz) {
  const name = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'longOffset' })
    .formatToParts(date)
    .find((p) => p.type === 'timeZoneName').value; // "GMT-03:00" ou "GMT"
  const m = /GMT([+-])(\d{2}):?(\d{2})?/.exec(name);
  if (!m) return 0;
  return (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3] || 0));
}

const WEEKDAYS = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/** Data local { y, m, d, weekday } (weekday: 0 = domingo). */
function localDate(date, tz) {
  const parts = {};
  for (const p of new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'short',
  }).formatToParts(date)) {
    parts[p.type] = p.value;
  }
  return { y: Number(parts.year), m: Number(parts.month), d: Number(parts.day), weekday: WEEKDAYS[parts.weekday] };
}

function addDays({ y, m, d }, n) {
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
}

/** O instante (UTC) correspondente a `hour`:00 do dia local informado. */
function atLocalHour({ y, m, d }, hour, tz) {
  const guess = Date.UTC(y, m - 1, d, hour);
  return new Date(guess - tzOffsetMinutes(new Date(guess), tz) * 60000);
}

/**
 * Janela [since, until) do digest.
 * - diário: desde o dia útil anterior às `digestHour` (segunda volta para sexta);
 * - semanal: desde 7 dias antes, no mesmo horário.
 * O fim é hoje às `digestHour` (ou agora, se ainda não chegou), para as janelas não se sobreporem.
 * Com `sinceOverride`, a janela vai dele até agora.
 */
function computeWindow(mode, now, config, sinceOverride) {
  if (sinceOverride) return { since: sinceOverride, until: now };
  const tz = config.timezone;
  const hour = config.digestHour == null ? 9 : config.digestHour;
  const today = localDate(now, tz);
  const anchor = atLocalHour(today, hour, tz);
  const until = now < anchor ? now : anchor;
  let back;
  if (mode === 'weekly') back = 7;
  else back = { 0: 2, 1: 3 }[today.weekday] || 1; // domingo e segunda voltam para sexta
  return { since: atLocalHour(addDays(today, -back), hour, tz), until };
}

function fmtLocal(date, tz) {
  const p = {};
  for (const part of new Intl.DateTimeFormat('en-GB', {
    timeZone: tz,
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date)) {
    p[part.type] = part.value;
  }
  return `${p.day}/${p.month} ${p.hour}:${p.minute}`;
}

function tzLabel(tz) {
  return tz === 'America/Sao_Paulo' ? 'BRT' : tz;
}

// UTC com "Z": "+00:00" quebraria a busca, porque o octokit não codifica o "+" (vira espaço).
function isoSeconds(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// ---------------------------------------------------------------- GitHub

function normalizeItem(item) {
  const repo = String(item.repository_url || '').split('/').pop();
  return {
    repo,
    number: item.number,
    title: item.title || '',
    body: item.body || '',
    url: item.html_url,
    labels: taxonomy.labelNames(item.labels),
    mergedAt: item.pull_request && item.pull_request.merged_at ? new Date(item.pull_request.merged_at) : null,
    createdAt: item.created_at ? new Date(item.created_at) : null,
  };
}

async function search(github, q, owner, repo) {
  try {
    return await github.paginate('GET /search/issues', { q, per_page: 100 });
  } catch (e) {
    throw new Error(
      `Falha ao buscar PRs de ${owner}/${repo} (${e.status || 'erro'}: ${e.message}). ` +
        'Confira se o token (secret CHANGELOG_GH_TOKEN) tem leitura de pull requests nesse repo.',
    );
  }
}

/** PRs mergeados na base, em [since, until), em todos os repos do config. Uma busca por repo. */
async function fetchMerged(github, config, { since, until }) {
  const out = [];
  for (const repo of config.repos) {
    const q = `repo:${config.owner}/${repo} is:pr is:merged base:${config.baseBranch} merged:${isoSeconds(since)}..${isoSeconds(until)}`;
    const items = await search(github, q, config.owner, repo);
    for (const item of items) {
      const pr = normalizeItem(item);
      if (pr.mergedAt && pr.mergedAt >= since && pr.mergedAt < until) out.push(pr);
    }
  }
  return out.sort((a, b) => a.mergedAt - b.mergedAt);
}

/** PRs abertos na base com partner:breaking. */
async function fetchOpenBreaking(github, config) {
  const out = [];
  for (const repo of config.repos) {
    const q = `repo:${config.owner}/${repo} is:pr is:open base:${config.baseBranch} label:"${taxonomy.PARTNER_PREFIX}breaking"`;
    for (const item of await search(github, q, config.owner, repo)) out.push(normalizeItem(item));
  }
  return out.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
}

/** JSON do comentário do classificador (ou null). Falha de rede vira aviso, não erro. */
async function botData(github, config, pr, core, cache) {
  const key = `${pr.repo}#${pr.number}`;
  if (cache && cache.has(key)) return cache.get(key);
  let data = null;
  try {
    const comments = await github.paginate('GET /repos/{owner}/{repo}/issues/{issue_number}/comments', {
      owner: config.owner,
      repo: pr.repo,
      issue_number: pr.number,
      per_page: 100,
    });
    const comment = findBotComment(comments);
    if (comment) {
      const parsed = parseBotComment(comment.body);
      if (parsed.error) core.warning(`${key}: comentário do classificador ignorado: ${parsed.error}.`);
      else data = parsed.data;
    }
  } catch (e) {
    core.warning(`${key}: não deu para ler os comentários (${e.message}); resumo cai no título.`);
  }
  if (cache) cache.set(key, data);
  return data;
}

// ---------------------------------------------------------------- classificação e resumo

/** Grupo do PR no digest e se faltam labels. Só lê labels; sem label de tipo, usa o prefixo do título. */
function classify(pr) {
  const types = taxonomy.typesFromLabels(pr.labels);
  const partners = taxonomy.partnersFromLabels(pr.labels);
  const type = types.length ? taxonomy.TYPE_KEYS.find((k) => types.includes(k)) : taxonomy.typeFromTitle(pr.title);
  const partner = taxonomy.mostSevere(partners);
  let group;
  if (partner === 'breaking' || partner === 'additive') group = partner;
  else group = type || 'unknown';
  return { group, type, partner, missingLabels: types.length === 0 || partners.length === 0 };
}

function oneLine(text, max = SUMMARY_MAX) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

/** Resumo: linha `Changelog:` da descrição → `summary` do classificador → título sem prefixo. */
function summaryFor(pr, data) {
  const fields = parseFields(pr.body);
  if (fields.changelog) return { text: oneLine(fields.changelog), source: 'changelog' };
  if (data && typeof data.summary === 'string' && data.summary.trim()) return { text: oneLine(data.summary), source: 'bot' };
  return { text: oneLine(taxonomy.stripPrefix(pr.title)), source: 'title' };
}

/** Só busca comentários quando a descrição não tem `Changelog:`. */
async function withSummaries(github, config, prs, core, cache) {
  const out = [];
  for (const pr of prs) {
    const needsBot = !parseFields(pr.body).changelog;
    const data = needsBot ? await botData(github, config, pr, core, cache) : null;
    out.push({ ...pr, ...classify(pr), summary: summaryFor(pr, data) });
  }
  return out;
}

// ---------------------------------------------------------------- Slack

function escapeSlack(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function itemLine(pr, suffix = '') {
  return `• <${pr.url}|${pr.repo}#${pr.number}> ${escapeSlack(pr.summary.text)}${suffix}`;
}

/**
 * Monta o texto mrkdwn. Retorna null para diário sem PR (não posta).
 * `openBreaking` só vem no semanal.
 */
function buildMessage({ mode, window, merged, openBreaking, config }) {
  if (mode === 'daily' && merged.length === 0) return null;
  const tz = config.timezone;
  const lines = [];
  const title = mode === 'weekly' ? 'semanal' : 'diário';
  lines.push(
    `*Changelog tech — ${title}* · ${fmtLocal(window.since, tz)} → ${fmtLocal(window.until, tz)} (${tzLabel(tz)}) · ` +
      `${merged.length} PR${merged.length === 1 ? '' : 's'} mergeado${merged.length === 1 ? '' : 's'}`,
  );

  if (merged.length === 0) lines.push('', '_Nenhum PR mergeado na janela._');

  for (const section of SECTIONS) {
    const items = merged.filter((pr) => pr.group === section.key);
    if (!items.length) continue;
    lines.push('', `*${section.title}*`, ...items.map((pr) => itemLine(pr)));
  }

  const counts = COUNT_ONLY.map((k) => [k, merged.filter((pr) => pr.group === k).length]).filter(([, n]) => n > 0);
  if (counts.length) lines.push('', `⚙️ ${counts.map(([k, n]) => `${n} ${k}`).join(' · ')}`);

  const unlabeled = merged.filter((pr) => pr.missingLabels).length;
  if (unlabeled) {
    lines.push(
      '',
      `⚠️ ${unlabeled} de ${merged.length} PR${merged.length === 1 ? '' : 's'} sem label de changelog (falta \`cl:*\` ou \`partner:*\`): ` +
        'sem `cl:*`, o tipo veio do prefixo do título; sem `partner:*`, o impacto no parceiro é desconhecido.',
    );
  }

  if (openBreaking) {
    lines.push('', '*🗓️ Breaking em aberto*');
    if (!openBreaking.length) lines.push('_Nenhum PR aberto com `partner:breaking`._');
    else lines.push(...openBreaking.map((pr) => itemLine(pr, pr.createdAt ? ` _(aberto em ${fmtLocal(pr.createdAt, tz).slice(0, 5)})_` : '')));
  }

  return truncate(lines.join('\n'));
}

function truncate(text) {
  if (text.length <= MESSAGE_MAX) return text;
  const lines = text.split('\n');
  const kept = [];
  let size = 0;
  for (const line of lines) {
    if (size + line.length + 1 > MESSAGE_MAX - 100) break;
    kept.push(line);
    size += line.length + 1;
  }
  return `${kept.join('\n')}\n… (${lines.length - kept.length} linha(s) cortadas pelo limite do Slack)`;
}

async function postToSlack(webhookUrl, text, fetchImpl) {
  const res = await fetchImpl(webhookUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, unfurl_links: false, unfurl_media: false }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`Slack respondeu HTTP ${res.status}${detail ? `: ${detail}` : ''}`);
  }
}

// ---------------------------------------------------------------- entrada

/**
 * Ponto de entrada (actions/github-script).
 * - schedule: diário; na segunda (no fuso do config), diário e semanal;
 * - workflow_dispatch: inputs `mode` (daily|weekly), `since` (ISO, opcional) e `dry_run` (default true).
 * Retorna [{ mode, window, message, posted }] (útil para testes e execução local).
 */
async function run({
  github,
  context,
  core,
  config = defaultConfig,
  env = process.env,
  fetchImpl = globalThis.fetch,
  now = new Date(),
}) {
  const inputs = (context.payload && context.payload.inputs) || {};
  const isDispatch = context.eventName === 'workflow_dispatch';
  const dryRun = isDispatch ? String(inputs.dry_run == null ? 'true' : inputs.dry_run).toLowerCase() !== 'false' : false;
  const prefix = dryRun ? '[DRY-RUN] ' : '';

  let modes;
  if (isDispatch) {
    const mode = String(inputs.mode || 'daily').toLowerCase();
    if (!['daily', 'weekly'].includes(mode)) {
      core.setFailed(`mode inválido: "${inputs.mode}" (use daily ou weekly).`);
      return [];
    }
    modes = [mode];
  } else {
    modes = localDate(now, config.timezone).weekday === 1 ? ['daily', 'weekly'] : ['daily'];
  }

  let since = null;
  if (inputs.since) {
    since = new Date(inputs.since);
    if (Number.isNaN(since.getTime()) || since >= now) {
      core.setFailed(`since inválido: "${inputs.since}" (use ISO 8601 no passado, ex.: 2026-10-27T09:00:00-03:00).`);
      return [];
    }
  }

  const webhook = env.SLACK_CHANGELOG_WEBHOOK;
  if (!dryRun && !webhook) {
    core.setFailed('Secret SLACK_CHANGELOG_WEBHOOK ausente: configure o Incoming Webhook do canal (ver docs/CHANGELOG_TECH.md).');
    return [];
  }

  const cache = new Map();
  const results = [];
  for (const mode of modes) {
    const window = computeWindow(mode, now, config, since);
    const merged = await withSummaries(github, config, await fetchMerged(github, config, window), core, cache);
    const openBreaking =
      mode === 'weekly' ? await withSummaries(github, config, await fetchOpenBreaking(github, config), core, cache) : null;
    const message = buildMessage({ mode, window, merged, openBreaking, config });

    if (!message) {
      core.info(`${prefix}${mode}: nenhum PR mergeado entre ${window.since.toISOString()} e ${window.until.toISOString()}; nada a postar.`);
      results.push({ mode, window, message: null, posted: false });
      continue;
    }
    if (dryRun) {
      core.info(`${prefix}${mode} (${merged.length} PRs) — mensagem que seria postada:\n\n${message}\n`);
      results.push({ mode, window, message, posted: false });
      continue;
    }
    await postToSlack(webhook, message, fetchImpl);
    core.info(`${mode}: postado no Slack (${merged.length} PRs).`);
    results.push({ mode, window, message, posted: true });
  }
  return results;
}

module.exports = {
  SECTIONS,
  computeWindow,
  localDate,
  atLocalHour,
  fmtLocal,
  classify,
  summaryFor,
  escapeSlack,
  buildMessage,
  withSummaries,
  fetchMerged,
  fetchOpenBreaking,
  postToSlack,
  run,
};
