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
const BREAKING_BODY = `## Summary\n\n- muda o contrato\n\nChangelog: remove o campo legado\nParceiro: o campo X deixa de vir\nFlag: api.remove_campo_x\nDocs: ${DOCS}\n`;

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

test('breaking sem Flag, ou com Flag fora do formato api.<nome>', () => {
  const semFlag = BREAKING_BODY.replace(/^Flag:.*$/m, 'Flag:');
  let r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: semFlag });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /exige o campo `Flag:`/);

  // `-` fica de fora: o changes-api recusa (CHECK em flag_rules.key) e a ponte quebraria no merge.
  for (const flag of ['sdk.otp_disabled', 'api.', 'API.Campo', 'api.campo x', 'api.campo-x', 'api..x', 'api']) {
    r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.remove_campo_x', flag) });
    assert.equal(r.errors.length, 1, flag);
    assert.match(r.errors[0], /formato `api.<nome>`/);
  }
  // Crase em volta da chave é tolerada.
  r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.remove_campo_x', '`api.remove_campo_x`') });
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
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.deepEqual(github.calls.map((c) => c.route), ['GET /repos/{owner}/{repo}/pulls/{pull_number}']);
  assert.match(core.infos.join('\n'), /OK — PR #7 com cl:feat \+ partner:breaking/);
  assert.equal(core.notices.length, 1);
  assert.match(core.notices[0], /só chega ao parceiro quando alguém clicar em Anunciar no BMS/);
  assert.match(core.notices[0], /`api\.remove_campo_x`/);
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
