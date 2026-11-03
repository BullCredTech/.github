'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const gate = require('../gate');
const { fakeOctokit, fakeCore, TEMPLATE_BODY } = require('./helpers');

const CONFIG = {
  owner: 'BullCredTech',
  repos: ['bull-module-proposals'],
  baseBranch: 'main',
  timezone: 'America/Sao_Paulo',
  docsRepo: 'BullCredTech/bull-api-docs-gitbook',
};
const DOCS = 'https://github.com/BullCredTech/bull-api-docs-gitbook/pull/42';
const BREAKING_BODY = `## Summary\n\n- muda o contrato\n\nChangelog: remove o campo legado\nParceiro: o campo X deixa de vir\nFlag: api.campo_x.remove\nDocs: ${DOCS}\n`;

function evaluate(over) {
  return gate.evaluate({ labels: [], body: '', config: CONFIG, ...over });
}

test('sem labels: falta uma de cada eixo, com as opções listadas', () => {
  const { errors } = evaluate({ labels: [] });
  assert.equal(errors.length, 2);
  assert.match(errors[0], /Falta a label de tipo.*`cl:feat`.*`cl:chore`/);
  assert.match(errors[1], /Falta a label de impacto no parceiro.*`partner:none`.*`partner:breaking`/);
});

test('só uma das duas labels: aponta o eixo que falta', () => {
  assert.deepEqual(evaluate({ labels: ['cl:feat'] }).errors.length, 1);
  assert.match(evaluate({ labels: ['cl:feat'] }).errors[0], /impacto no parceiro/);
  assert.match(evaluate({ labels: ['partner:none'] }).errors[0], /label de tipo/);
});

test('duas labels no mesmo eixo: pede para deixar só uma', () => {
  const tipo = evaluate({ labels: ['cl:feat', 'cl:fix', 'partner:none'] }).errors;
  assert.equal(tipo.length, 1);
  assert.match(tipo[0], /Há 2 labels de tipo \(`cl:feat`, `cl:fix`\)/);
  const parceiro = evaluate({ labels: ['cl:feat', 'partner:none', 'partner:additive'] }).errors;
  assert.equal(parceiro.length, 1);
  assert.match(parceiro[0], /Há 2 labels de impacto no parceiro/);
});

test('uma de cada eixo, sem breaking: passa sem exigir campos', () => {
  for (const partner of ['none', 'additive']) {
    const { errors } = evaluate({ labels: ['cl:feat', `partner:${partner}`], body: '' });
    assert.deepEqual(errors, [], partner);
  }
});

test('label fora da taxonomia vira nota, não erro', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:none', 'cl:docs'] });
  assert.deepEqual(r.errors, []);
  assert.match(r.notes.join('\n'), /`cl:docs`/);
});

test('breaking com Flag e Docs: passa, sem pedir aprovação nem lista de aprovadores', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY });
  assert.deepEqual(r.errors, []);
  assert.equal(r.breaking, true);
  assert.doesNotMatch(r.notes.join('\n'), /aprova/i);
});

test('o config não tem mais lista de aprovadores', () => {
  const config = require('../config.json');
  assert.equal('partnerApprovers' in config, false);
});

test('breaking sem Docs, ou com Docs que não é PR do repo de docs', () => {
  const semDocs = BREAKING_BODY.replace(/^Docs:.*$/m, '');
  let r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: semDocs });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /exige o campo `Docs:`/);

  for (const docs of ['https://docs.bullcredtech.com/changelog', 'https://github.com/BullCredTech/bull-module-proposals/pull/1', 'pendente']) {
    r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace(DOCS, docs) });
    assert.equal(r.errors.length, 1, docs);
    assert.match(r.errors[0], /precisa apontar para um PR de BullCredTech\/bull-api-docs-gitbook/);
  }

  // Forma curta owner/repo#N também vale.
  r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace(DOCS, 'BullCredTech/bull-api-docs-gitbook#42') });
  assert.deepEqual(r.errors, []);
});

test('breaking sem Flag, ou com Flag fora do formato <superfície>.<recurso>.<mudança>', () => {
  const semFlag = BREAKING_BODY.replace(/^Flag:.*$/m, 'Flag:');
  let r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: semFlag });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /exige o campo `Flag:`/);

  // `-` fica de fora: o changes-api recusa (CHECK em flag_rules.key) e a ponte quebraria no merge.
  for (const flag of ['sdk.otp.disabled', 'api.', 'API.Campo.x', 'api.campo x.y', 'api.campo-x.remove', 'api..x', 'api', 'api.so_duas_partes', 'webhook.status']) {
    r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.campo_x.remove', flag) });
    assert.equal(r.errors.length, 1, flag);
    assert.match(r.errors[0], /formato `<superfície>\.<recurso>\.<mudança>`/);
  }
  // Crase em volta da chave é tolerada.
  r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.campo_x.remove', '`api.campo_x.remove`') });
  assert.deepEqual(r.errors, []);
  for (const flag of ['api.contracts.remove_bank_code', 'webhook.proposal_status.new_payload', 'api.simulate.amount.strict']) {
    r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.campo_x.remove', flag) });
    assert.deepEqual(r.errors, [], flag);
  }
});

const USES_FLAG = { filename: 'apis/proposals-api/src/simulate/simulate.service.ts', patch: "@@ -1 +1,2 @@\n+if (this.featureFlags.isEnabled('api.campo_x.remove', origin.code)) {\n context" };

test('breaking: a chave da Flag tem de aparecer nas linhas adicionadas do código', () => {
  const labels = ['cl:feat', 'partner:breaking'];
  let r = evaluate({ labels, body: BREAKING_BODY, files: [USES_FLAG] });
  assert.deepEqual(r.errors, []);
  assert.match(r.notes.join('\n'), /aparece no código alterado: `apis\/proposals-api\/src\/simulate\/simulate\.service\.ts`/);

  // Decorator e aspas duplas também valem.
  r = evaluate({ labels, body: BREAKING_BODY, files: [{ filename: 'src/a.controller.ts', patch: '+@PartnerFlags("api.campo_x.remove")' }] });
  assert.deepEqual(r.errors, []);

  // Não aparece em lugar nenhum.
  r = evaluate({ labels, body: BREAKING_BODY, files: [{ filename: 'src/a.ts', patch: '+const x = 1;' }] });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /não aparece no código alterado/);
  assert.match(r.errors[0], /isEnabled\('api\.campo_x\.remove', origem\)/);

  // Só em linha removida, em teste, em .md ou em docs/ não conta.
  for (const f of [
    { filename: 'src/a.ts', patch: "-isEnabled('api.campo_x.remove')" },
    { filename: 'src/a.spec.ts', patch: "+isEnabled('api.campo_x.remove')" },
    { filename: 'test/a.e2e.ts', patch: "+isEnabled('api.campo_x.remove')" },
    { filename: 'docs/SCHEDULED.md', patch: "+`api.campo_x.remove`" },
    { filename: 'README.md', patch: "+'api.campo_x.remove'" },
  ]) {
    r = evaluate({ labels, body: BREAKING_BODY, files: [f] });
    assert.equal(r.errors.length, 1, f.filename);
  }

  // Chave como prefixo de outra não conta (precisa estar entre aspas inteira).
  r = evaluate({ labels, body: BREAKING_BODY, files: [{ filename: 'src/a.ts', patch: "+isEnabled('api.campo_x.remove_v2')" }] });
  assert.equal(r.errors.length, 1);
});

test('breaking: arquivo sem diff visível pela API entra na mensagem', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY, files: [{ filename: 'src/enorme.ts' }] });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /não mostrou o diff de 1 arquivo\(s\) grande\(s\) \(`src\/enorme\.ts`\)/);
});

test('sem breaking, o diff não é avaliado', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:additive'], body: 'Parceiro: campo novo', files: [] });
  assert.deepEqual(r.errors, []);
});

test('breaking com o template vazio: Docs e Flag faltam (a linha de baixo não vira valor)', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: TEMPLATE_BODY });
  assert.equal(r.errors.length, 2);
  assert.match(r.errors[0], /exige o campo `Docs:`/);
  assert.match(r.errors[1], /exige o campo `Flag:`/);
});

test('breaking sem nada: lista as duas pendências de uma vez', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: '' });
  assert.equal(r.errors.length, 2);
  assert.match(r.errors[0], /exige o campo `Docs:`/);
  assert.match(r.errors[1], /exige o campo `Flag:`/);
});

test('additive sem Parceiro: só nota, não bloqueia', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:additive'], body: 'Changelog: algo' });
  assert.deepEqual(r.errors, []);
  assert.match(r.notes.join('\n'), /Sem `Parceiro:`/);
});

test('o gate não olha data: nada de relógio no gate.js', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'gate.js'), 'utf8');
  assert.doesNotMatch(src, /new Date|Date\.now/);
});

// ---------------------------------------------------------------- run (com octokit falso)

function prFixture({ labels = [], body = '', base = 'main', number = 7 } = {}) {
  return { number, body, base: { ref: base }, labels: labels.map((name) => ({ name })) };
}

function ctx(number = 7, eventName = 'pull_request') {
  return { eventName, repo: { owner: 'BullCredTech', repo: 'bull-module-proposals' }, payload: { pull_request: { number, labels: [] } } };
}

test('run: repo fora do piloto passa sem ler o PR', async () => {
  const github = fakeOctokit({});
  const core = fakeCore();
  const context = { eventName: 'pull_request', repo: { owner: 'BullCredTech', repo: '.github' }, payload: { pull_request: { number: 9, labels: [] } } };
  await gate.run({ github, context, core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.equal(github.calls.length, 0);
  assert.match(core.infos.join('\n'), /não está no piloto/);
});

test('run: relê o PR na API (labels atuais, não as do payload) e passa', async () => {
  const github = fakeOctokit({
    'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ labels: ['cl:fix', 'partner:none'] }),
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.match(core.infos.join('\n'), /OK — PR #7 com cl:fix \+ partner:none/);
  assert.deepEqual(github.calls.map((c) => c.route), ['GET /repos/{owner}/{repo}/pulls/{pull_number}']);
  assert.equal(github.calls[0].params.pull_number, 7);
});

test('run: falha com a lista de pendências e o link do doc', async () => {
  const github = fakeOctokit({ 'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture() });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.match(core.failed, /2 pendência\(s\) no PR #7/);
  assert.match(core.failed, /docs\/CHANGELOG_TECH\.md/);
});

test('run: breaking com Flag e Docs passa sem buscar reviews e lembra do Anunciar no BMS', async () => {
  const github = fakeOctokit({
    'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY }),
    'GET /repos/{owner}/{repo}/pulls/{pull_number}/files': () => [USES_FLAG],
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.deepEqual(github.calls.map((c) => c.route), [
    'GET /repos/{owner}/{repo}/pulls/{pull_number}',
    'GET /repos/{owner}/{repo}/pulls/{pull_number}/files',
  ]);
  assert.equal(github.calls[1].params.pull_number, 7);
  assert.match(core.infos.join('\n'), /OK — PR #7 com cl:feat \+ partner:breaking/);
  assert.equal(core.notices.length, 1);
  assert.match(core.notices[0], /só chega ao parceiro quando alguém clicar em Anunciar no BMS/);
  assert.match(core.notices[0], /`api\.campo_x\.remove`/);
});

test('run: sem breaking, nenhum lembrete de anúncio', async () => {
  const github = fakeOctokit({
    'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ labels: ['cl:feat', 'partner:additive'], body: 'Parceiro: campo novo' }),
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.deepEqual(core.notices, []);
});

test('run: breaking sem Flag nem Docs falha e não lembra do anúncio', async () => {
  const github = fakeOctokit({
    'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ labels: ['cl:feat', 'partner:breaking'], body: TEMPLATE_BODY }),
    'GET /repos/{owner}/{repo}/pulls/{pull_number}/files': () => [],
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.match(core.failed, /2 pendência\(s\)/);
  assert.deepEqual(core.notices, []);
});

test('run: PR contra outra base (ex.: staging) não é avaliado', async () => {
  const github = fakeOctokit({ 'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ base: 'staging' }) });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.match(core.infos.join('\n'), /aponta para "staging"/);
  assert.equal(github.calls.length, 1);
});

test('run: evento sem pull_request falha explicando', async () => {
  const core = fakeCore();
  await gate.run({ github: fakeOctokit({}), context: { eventName: 'push', repo: {}, payload: {} }, core, config: CONFIG });
  assert.match(core.failed, /sem pull_request/);
});

test('workflow changelog.yml carrega o gate.js que existe, no checkout .changelog-bot', () => {
  const root = path.resolve(__dirname, '../../..');
  const wf = fs.readFileSync(path.join(root, '.github/workflows/changelog.yml'), 'utf8');
  assert.match(wf, /name: changelog-gate/);
  assert.match(wf, /\.changelog-bot\/scripts\/changelog\/gate\.js/);
  assert.match(wf, /ref: \$\{\{ github\.workflow_sha \}\}/);
  assert.doesNotMatch(wf, /pull_request_review/, 'o gate não lê reviews');
  assert.ok(fs.existsSync(path.join(root, 'scripts/changelog/gate.js')));
});

test('docsPrRef: aceita URL e atalho do repo de docs, recusa outro repo', () => {
  const repo = 'BullCredTech/bull-api-docs-gitbook';
  assert.equal(gate.docsPrRef('https://github.com/BullCredTech/bull-api-docs-gitbook/pull/22', repo), 22);
  assert.equal(gate.docsPrRef('ver bullcredtech/BULL-API-DOCS-GITBOOK#7', repo), 7);
  assert.equal(gate.docsPrRef('https://github.com/BullCredTech/bull-module-proposals/pull/200', repo), null);
  assert.equal(gate.docsPrRef('BullCredTech/outro#3', repo), null);
});
