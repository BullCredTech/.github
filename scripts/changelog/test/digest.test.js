'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const d = require('../digest');
const { parseFields, findBotComment, parseBotComment } = require('../fields');
const { fakeOctokit, fakeCore, searchItem, TEMPLATE_BODY } = require('./helpers');

const CONFIG = {
  owner: 'BullCredTech',
  repos: ['bull-module-proposals', 'bull-module-auction'],
  baseBranch: 'main',
  timezone: 'America/Sao_Paulo',
  partnerApprovers: [],
  docsRepo: 'BullCredTech/bull-api-docs-gitbook',
  digestHour: 9,
};

const iso = (date) => date.toISOString();
const botComment = (json, extra = '') => `<!-- changelog-bot -->\n### Changelog (classificador)\n\n\`\`\`json\n${JSON.stringify(json, null, 2)}\n\`\`\`\n${extra}`;

// ---------------------------------------------------------------- janela

test('janela diária: terça pega desde segunda 09:00 BRT até hoje 09:00 BRT', () => {
  const w = d.computeWindow('daily', new Date('2026-11-03T12:07:00Z'), CONFIG);
  assert.equal(iso(w.since), '2026-11-02T12:00:00.000Z');
  assert.equal(iso(w.until), '2026-11-03T12:00:00.000Z');
});

test('janela diária: segunda volta para sexta 09:00 BRT', () => {
  const w = d.computeWindow('daily', new Date('2026-11-02T12:03:00Z'), CONFIG);
  assert.equal(iso(w.since), '2026-10-30T12:00:00.000Z');
  assert.equal(iso(w.until), '2026-11-02T12:00:00.000Z');
});

test('janela diária: domingo (disparo manual) também volta para sexta', () => {
  const w = d.computeWindow('daily', new Date('2026-11-01T15:00:00Z'), CONFIG);
  assert.equal(iso(w.since), '2026-10-30T12:00:00.000Z');
});

test('janela semanal: 7 dias, de segunda a segunda 09:00 BRT', () => {
  const w = d.computeWindow('weekly', new Date('2026-11-02T12:03:00Z'), CONFIG);
  assert.equal(iso(w.since), '2026-10-26T12:00:00.000Z');
  assert.equal(iso(w.until), '2026-11-02T12:00:00.000Z');
});

test('janela antes das 09:00 BRT termina agora; since explícito vai até agora', () => {
  const now = new Date('2026-11-03T10:00:00Z'); // 07:00 BRT
  assert.equal(iso(d.computeWindow('daily', now, CONFIG).until), iso(now));
  const since = new Date('2026-10-20T00:00:00-03:00');
  assert.deepEqual(d.computeWindow('weekly', now, CONFIG, since), { since, until: now });
});

test('fmtLocal mostra dia/mês hora no fuso do config', () => {
  assert.equal(d.fmtLocal(new Date('2026-10-30T12:00:00Z'), 'America/Sao_Paulo'), '30/10 09:00');
});

// ---------------------------------------------------------------- campos e resumo

test('campos da descrição: template com linhas vazias não captura a linha de baixo', () => {
  assert.deepEqual(parseFields(TEMPLATE_BODY), { changelog: null, parceiro: null, flag: null, docs: null });
  // Regressão do protótipo: com \s, "Changelog:" vazio pegava "Parceiro: ..." como valor.
  const f = parseFields('Changelog:\nParceiro: o campo X passa a vir\nFlag:\nDocs: https://x\n');
  assert.equal(f.changelog, null);
  assert.equal(f.parceiro, 'o campo X passa a vir');
  assert.equal(f.flag, null);
  assert.equal(f.docs, 'https://x');
});

test('campos da descrição: CRLF, lista, negrito e crase', () => {
  const f = parseFields('- **Changelog:** nova rota de simulação\r\nFlag: `api.nova_rota`\r\n');
  assert.equal(f.changelog, 'nova rota de simulação');
  assert.equal(f.flag, 'api.nova_rota');
});

test('campos dentro de comentário HTML do template não contam', () => {
  assert.equal(parseFields('<!--\nChangelog: exemplo do template\n-->\nChangelog:\n').changelog, null);
});

test('comentário do classificador: último com o marcador; JSON inválido vira erro sem lançar', () => {
  const comments = [
    { body: 'oi' },
    { body: botComment({ summary: 'antigo' }) },
    { body: botComment({ summary: 'novo' }) },
  ];
  assert.equal(parseBotComment(findBotComment(comments).body).data.summary, 'novo');
  assert.equal(findBotComment([{ body: 'sem marcador' }]), null);
  assert.match(parseBotComment('<!-- changelog-bot -->\n```json\n{ quebrado\n```').error, /JSON inválido/);
  assert.match(parseBotComment('<!-- changelog-bot -->\nsem bloco').error, /sem bloco/);
});

test('resumo: Changelog: > summary do classificador > título sem prefixo', () => {
  const pr = { title: 'feat(api): rota nova', body: 'Changelog: rota de simulação por CPF' };
  assert.deepEqual(d.summaryFor(pr, { summary: 'do bot' }), { text: 'rota de simulação por CPF', source: 'changelog' });
  assert.deepEqual(d.summaryFor({ ...pr, body: TEMPLATE_BODY }, { summary: 'do bot' }), { text: 'do bot', source: 'bot' });
  assert.deepEqual(d.summaryFor({ ...pr, body: TEMPLATE_BODY }, null), { text: 'rota nova', source: 'title' });
  assert.deepEqual(d.summaryFor({ ...pr, body: '' }, { summary: '   ' }), { text: 'rota nova', source: 'title' });
});

// ---------------------------------------------------------------- agrupamento

test('classify: impacto no parceiro tem precedência sobre o tipo', () => {
  assert.equal(d.classify({ title: 'feat: x', labels: ['cl:feat', 'partner:breaking'] }).group, 'breaking');
  assert.equal(d.classify({ title: 'fix: x', labels: ['cl:infra', 'partner:additive'] }).group, 'additive');
  assert.equal(d.classify({ title: 'x', labels: ['cl:perf', 'partner:none'] }).group, 'perf');
  // Duas labels de impacto (gate contornado): vale a mais grave.
  assert.equal(d.classify({ title: 'x', labels: ['cl:fix', 'partner:none', 'partner:breaking'] }).group, 'breaking');
});

test('classify: sem label usa o prefixo do título e marca como sem label', () => {
  assert.deepEqual(d.classify({ title: 'hotfix(prod): x', labels: [] }), { group: 'fix', type: 'fix', partner: null, missingLabels: true });
  assert.equal(d.classify({ title: 'Atualiza README', labels: [] }).group, 'unknown');
  assert.equal(d.classify({ title: 'feat: x', labels: ['cl:chore'] }).missingLabels, true); // falta partner:*
  assert.equal(d.classify({ title: 'feat: x', labels: ['cl:chore', 'partner:none'] }).group, 'chore'); // label vence o título
});

function prs() {
  const base = { url: 'https://github.com/BullCredTech/bull-module-proposals/pull/1', repo: 'bull-module-proposals' };
  const mk = (number, group, text, missingLabels = false) => ({ ...base, number, group, missingLabels, summary: { text } });
  return [
    mk(1, 'feat', 'rota nova'),
    mk(2, 'breaking', 'remove campo <legado> & antigo'),
    mk(3, 'fix', 'corrige cálculo'),
    mk(4, 'infra', 'x'),
    mk(5, 'chore', 'x', true),
    mk(6, 'chore', 'x', true),
    mk(7, 'additive', 'campo novo'),
    mk(8, 'security', 'atualiza qs'),
    mk(9, 'perf', 'cache'),
    mk(10, 'unknown', 'sem prefixo', true),
  ];
}

const WINDOW = { since: new Date('2026-10-30T12:00:00Z'), until: new Date('2026-11-02T12:00:00Z') };

test('mensagem: seções na ordem, infra/chore só em contagem, aviso de sem label', () => {
  const msg = d.buildMessage({ mode: 'daily', window: WINDOW, merged: prs(), openBreaking: null, config: CONFIG });
  const order = ['🔴 Quebra contrato', '🟡 Comunicar ao parceiro', '✨ Novidades', '🐛 Correções', '⚡ Performance', '🔒 Segurança', '❔ Sem classificação', '⚙️ 1 infra · 2 chore', '⚠️ 3 de 10 PRs sem label'];
  let last = -1;
  for (const s of order) {
    const i = msg.indexOf(s);
    assert.ok(i > last, `${s} fora de ordem ou ausente`);
    last = i;
  }
  assert.match(msg, /^\*Changelog tech — diário\* · 30\/10 09:00 → 02\/11 09:00 \(BRT\) · 10 PRs mergeados/);
  assert.doesNotMatch(msg, /🗓️/);
  assert.doesNotMatch(msg, /#4>/); // infra não é listado
});

test('mensagem: escapa & < > e monta o link <url|repo#n>', () => {
  const msg = d.buildMessage({ mode: 'daily', window: WINDOW, merged: prs(), openBreaking: null, config: CONFIG });
  assert.match(msg, /• <https:\/\/github\.com\/BullCredTech\/bull-module-proposals\/pull\/1\|bull-module-proposals#2> remove campo &lt;legado&gt; &amp; antigo/);
  assert.equal(d.escapeSlack('a & <b> c'), 'a &amp; &lt;b&gt; c');
});

test('mensagem: diário vazio não posta; semanal vazio posta com breaking em aberto', () => {
  assert.equal(d.buildMessage({ mode: 'daily', window: WINDOW, merged: [], openBreaking: null, config: CONFIG }), null);
  const weekly = d.buildMessage({ mode: 'weekly', window: WINDOW, merged: [], openBreaking: [], config: CONFIG });
  assert.match(weekly, /Changelog tech — semanal/);
  assert.match(weekly, /Nenhum PR mergeado na janela/);
  assert.match(weekly, /🗓️ Breaking em aberto\*\n_Nenhum PR aberto com `partner:breaking`._/);
});

// ---------------------------------------------------------------- run (com octokit falso)

function githubWith({ merged = {}, open = {}, comments = {} }) {
  return fakeOctokit({
    'GET /search/issues': ({ q }) => {
      const repo = /repo:BullCredTech\/(\S+)/.exec(q)[1];
      const src = q.includes('is:open') ? open : merged;
      return { total_count: (src[repo] || []).length, items: src[repo] || [] };
    },
    'GET /repos/{owner}/{repo}/issues/{issue_number}/comments': ({ repo, issue_number: n }) => comments[`${repo}#${n}`] || [],
  });
}

const MERGED = {
  'bull-module-proposals': [
    searchItem({ repo: 'bull-module-proposals', number: 10, title: 'feat(api): rota nova', body: 'Changelog: simulação por CPF', labels: ['cl:feat', 'partner:additive'], mergedAt: '2026-11-02T14:00:00Z' }),
    searchItem({ repo: 'bull-module-proposals', number: 11, title: 'fix(api): corrige arredondamento', body: TEMPLATE_BODY, labels: ['cl:fix', 'partner:none'], mergedAt: '2026-11-02T15:00:00Z' }),
    // Fora da janela (a busca do GitHub é inclusiva nas pontas): descartado.
    searchItem({ repo: 'bull-module-proposals', number: 12, title: 'feat: no limite', labels: ['cl:feat', 'partner:none'], mergedAt: '2026-11-03T12:00:00Z' }),
  ],
  'bull-module-auction': [
    searchItem({ repo: 'bull-module-auction', number: 700, title: 'chore(deps): bump', mergedAt: '2026-11-02T13:00:00Z' }),
  ],
};
const COMMENTS = {
  'bull-module-proposals#11': [{ body: botComment({ type: 'fix', partner: 'none', summary: 'Arredondamento do IOF & da parcela', partner_text: '', migration_guide: '', docs: [], reason: 'só cálculo interno' }) }],
};
const TUESDAY = new Date('2026-11-03T12:05:00Z');

test('run (schedule, terça): só diário, posta no webhook sem unfurl', async () => {
  const github = githubWith({ merged: MERGED, comments: COMMENTS });
  const core = fakeCore();
  const posts = [];
  const fetchImpl = async (url, init) => {
    posts.push({ url, payload: JSON.parse(init.body) });
    return { ok: true, status: 200, text: async () => 'ok' };
  };
  const res = await d.run({ github, context: { eventName: 'schedule', payload: {} }, core, config: CONFIG, env: { SLACK_CHANGELOG_WEBHOOK: 'https://hooks.slack.test/x' }, fetchImpl, now: TUESDAY });

  assert.equal(core.failed, null);
  assert.deepEqual(res.map((r) => [r.mode, r.posted]), [['daily', true]]);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, 'https://hooks.slack.test/x');
  assert.equal(posts[0].payload.unfurl_links, false);
  const text = posts[0].payload.text;
  assert.match(text, /3 PRs mergeados/);
  assert.match(text, /🟡 Comunicar ao parceiro\*\n• <[^|]+\|bull-module-proposals#10> simulação por CPF/);
  assert.match(text, /🐛 Correções\*\n• <[^|]+\|bull-module-proposals#11> Arredondamento do IOF &amp; da parcela/);
  assert.match(text, /⚙️ 1 chore/);
  assert.match(text, /⚠️ 1 de 3 PRs sem label/);
  assert.doesNotMatch(text, /#12>/);

  // Uma busca por repo, com a janela em UTC; comentários só para o PR sem Changelog: preenchido.
  const searches = github.calls.filter((c) => c.route === 'GET /search/issues').map((c) => c.params.q);
  assert.deepEqual(searches, [
    'repo:BullCredTech/bull-module-proposals is:pr is:merged base:main merged:2026-11-02T12:00:00Z..2026-11-03T12:00:00Z',
    'repo:BullCredTech/bull-module-auction is:pr is:merged base:main merged:2026-11-02T12:00:00Z..2026-11-03T12:00:00Z',
  ]);
  const commentCalls = github.calls.filter((c) => c.route.endsWith('/comments')).map((c) => `${c.params.repo}#${c.params.issue_number}`);
  assert.deepEqual(commentCalls, ['bull-module-auction#700', 'bull-module-proposals#11']); // ordem de merge
});

test('run (schedule, segunda): diário (desde sexta) e semanal (7 dias); semanal traz breaking em aberto', async () => {
  const merged = {
    'bull-module-proposals': [
      // Só na janela semanal (terça anterior).
      searchItem({ repo: 'bull-module-proposals', number: 20, title: 'perf(api): cache da simulação', labels: ['cl:perf', 'partner:none'], mergedAt: '2026-10-27T18:00:00Z' }),
      // Nas duas (sábado).
      searchItem({ repo: 'bull-module-proposals', number: 21, title: 'fix(api): corrige CET', labels: ['cl:fix', 'partner:none'], mergedAt: '2026-10-31T18:00:00Z' }),
    ],
  };
  const open = {
    'bull-module-auction': [searchItem({ repo: 'bull-module-auction', number: 760, title: 'feat!: remove campo legado', body: 'Changelog: remove o campo legado da oferta', labels: ['cl:feat', 'partner:breaking'], createdAt: '2026-10-28T15:00:00Z' })],
  };
  const github = githubWith({ merged, open });
  const posted = [];
  const fetchImpl = async (url, init) => {
    posted.push(JSON.parse(init.body).text);
    return { ok: true, status: 200, text: async () => 'ok' };
  };
  const res = await d.run({ github, context: { eventName: 'schedule', payload: {} }, core: fakeCore(), config: CONFIG, env: { SLACK_CHANGELOG_WEBHOOK: 'https://hooks.slack.test/x' }, fetchImpl, now: new Date('2026-11-02T12:05:00Z') });
  assert.deepEqual(res.map((r) => [r.mode, r.posted]), [['daily', true], ['weekly', true]]);
  assert.match(posted[0], /Changelog tech — diário\* · 30\/10 09:00 → 02\/11 09:00 \(BRT\) · 1 PR mergeado\n/);
  assert.doesNotMatch(posted[0], /#20>/);
  assert.match(posted[1], /Changelog tech — semanal\* · 26\/10 09:00 → 02\/11 09:00 \(BRT\) · 2 PRs mergeados/);
  assert.match(posted[1], /⚡ Performance\*\n• <[^|]+\|bull-module-proposals#20> cache da simulação/);
  assert.match(posted[1], /🗓️ Breaking em aberto\*\n• <[^|]+\|bull-module-auction#760> remove o campo legado da oferta _\(aberto em 28\/10\)_/);
  const openQuery = github.calls.find((c) => c.route === 'GET /search/issues' && c.params.q.includes('is:open')).params.q;
  assert.equal(openQuery, 'repo:BullCredTech/bull-module-proposals is:pr is:open base:main label:"partner:breaking"');
  // Comentários do PR que aparece nos dois digests são lidos uma vez só.
  const commentCalls = github.calls.filter((c) => c.route.endsWith('/comments')).map((c) => c.params.issue_number);
  assert.deepEqual(commentCalls.filter((n) => n === 21), [21]);
});

test('run (dispatch): dry_run default não posta e não exige webhook', async () => {
  const core = fakeCore();
  let called = false;
  const res = await d.run({
    github: githubWith({ merged: MERGED, comments: COMMENTS }),
    context: { eventName: 'workflow_dispatch', payload: { inputs: { mode: 'daily' } } },
    core,
    config: CONFIG,
    env: {},
    fetchImpl: async () => {
      called = true;
    },
    now: TUESDAY,
  });
  assert.equal(called, false);
  assert.equal(core.failed, null);
  assert.equal(res[0].posted, false);
  assert.match(core.infos.join('\n'), /\[DRY-RUN\] daily \(3 PRs\)/);
});

test('run (dispatch): since explícito e dry_run "false" (string do payload) posta', async () => {
  const github = githubWith({ merged: MERGED, comments: COMMENTS });
  let posts = 0;
  const res = await d.run({
    github,
    context: { eventName: 'workflow_dispatch', payload: { inputs: { mode: 'daily', since: '2026-11-01T00:00:00-03:00', dry_run: 'false' } } },
    core: fakeCore(),
    config: CONFIG,
    env: { SLACK_CHANGELOG_WEBHOOK: 'https://hooks.slack.test/x' },
    fetchImpl: async () => {
      posts += 1;
      return { ok: true, status: 200, text: async () => '' };
    },
    now: TUESDAY,
  });
  assert.equal(posts, 1);
  assert.equal(iso(res[0].window.since), '2026-11-01T03:00:00.000Z');
  assert.equal(iso(res[0].window.until), iso(TUESDAY));
  assert.match(github.calls[0].params.q, /merged:2026-11-01T03:00:00Z\.\.2026-11-03T12:05:00Z/);
});

test('run: diário vazio não posta', async () => {
  let called = false;
  const res = await d.run({
    github: githubWith({}),
    context: { eventName: 'schedule', payload: {} },
    core: fakeCore(),
    config: CONFIG,
    env: { SLACK_CHANGELOG_WEBHOOK: 'https://hooks.slack.test/x' },
    fetchImpl: async () => {
      called = true;
    },
    now: TUESDAY,
  });
  assert.equal(called, false);
  assert.deepEqual(res.map((r) => [r.mode, r.message, r.posted]), [['daily', null, false]]);
});

test('run: sem webhook fora de dry-run falha; inputs inválidos falham', async () => {
  let core = fakeCore();
  await d.run({ github: githubWith({}), context: { eventName: 'schedule', payload: {} }, core, config: CONFIG, env: {}, now: TUESDAY });
  assert.match(core.failed, /SLACK_CHANGELOG_WEBHOOK ausente/);

  core = fakeCore();
  await d.run({ github: githubWith({}), context: { eventName: 'workflow_dispatch', payload: { inputs: { mode: 'monthly' } } }, core, config: CONFIG, env: {}, now: TUESDAY });
  assert.match(core.failed, /mode inválido/);

  core = fakeCore();
  await d.run({ github: githubWith({}), context: { eventName: 'workflow_dispatch', payload: { inputs: { since: 'ontem' } } }, core, config: CONFIG, env: {}, now: TUESDAY });
  assert.match(core.failed, /since inválido/);
});

test('run: erro do Slack e falta de acesso ao repo viram erro com contexto', async () => {
  await assert.rejects(
    d.run({
      github: githubWith({ merged: MERGED, comments: COMMENTS }),
      context: { eventName: 'schedule', payload: {} },
      core: fakeCore(),
      config: CONFIG,
      env: { SLACK_CHANGELOG_WEBHOOK: 'https://hooks.slack.test/x' },
      fetchImpl: async () => ({ ok: false, status: 404, text: async () => 'no_service' }),
      now: TUESDAY,
    }),
    /Slack respondeu HTTP 404: no_service/,
  );

  const denied = fakeOctokit({
    'GET /search/issues': () => {
      const e = new Error('Validation Failed');
      e.status = 422;
      throw e;
    },
  });
  await assert.rejects(
    d.run({ github: denied, context: { eventName: 'workflow_dispatch', payload: { inputs: {} } }, core: fakeCore(), config: CONFIG, env: {}, now: TUESDAY }),
    /bull-module-proposals \(422: Validation Failed\).*CHANGELOG_GH_TOKEN/,
  );
});

test('run: comentário do classificador com JSON inválido vira aviso e o resumo cai no título', async () => {
  const comments = { 'bull-module-proposals#11': [{ body: '<!-- changelog-bot -->\n```json\n{ nope\n```' }] };
  const core = fakeCore();
  const res = await d.run({
    github: githubWith({ merged: MERGED, comments }),
    context: { eventName: 'workflow_dispatch', payload: { inputs: {} } },
    core,
    config: CONFIG,
    env: {},
    now: TUESDAY,
  });
  assert.match(core.warnings.join('\n'), /bull-module-proposals#11: comentário do classificador ignorado: JSON inválido/);
  assert.match(res[0].message, /#11> corrige arredondamento/);
});

test('template de PR da org: os quatro campos existem e chegam vazios', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const tpl = fs.readFileSync(path.resolve(__dirname, '../../../.github/PULL_REQUEST_TEMPLATE.md'), 'utf8');
  for (const name of ['Changelog', 'Parceiro', 'Flag', 'Docs']) assert.match(tpl, new RegExp(`^${name}:$`, 'm'), name);
  assert.deepEqual(parseFields(tpl), { changelog: null, parceiro: null, flag: null, docs: null });
  const filled = tpl.replace(/^Changelog:$/m, 'Changelog: rota nova').replace(/^Flag:$/m, 'Flag: api.rota_nova');
  assert.deepEqual(parseFields(filled), { changelog: 'rota nova', parceiro: null, flag: 'api.rota_nova', docs: null });
});
