'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const gate = require('../gate');
const { fakeOctokit, fakeCore, TEMPLATE_BODY } = require('./helpers');

const APPROVER = 'parcerias-bull';
const CONFIG = {
  owner: 'BullCredTech',
  repos: ['bull-module-proposals'],
  baseBranch: 'main',
  timezone: 'America/Sao_Paulo',
  partnerApprovers: [APPROVER],
  docsRepo: 'BullCredTech/bull-api-docs-gitbook',
};
const DOCS = 'https://github.com/BullCredTech/bull-api-docs-gitbook/pull/42';
const BREAKING_BODY = `## Summary\n\n- muda o contrato\n\nChangelog: remove o campo legado\nParceiro: o campo X deixa de vir\nFlag: api.remove_campo_x\nDocs: ${DOCS}\n`;

const review = (login, state) => ({ user: { login }, state });
const approved = [review(APPROVER, 'APPROVED')];

function evaluate(over) {
  return gate.evaluate({ labels: [], body: '', reviews: [], config: CONFIG, ...over });
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

test('uma de cada eixo, sem breaking: passa sem exigir campos nem aprovação', () => {
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

test('breaking com tudo certo: passa', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY, reviews: approved });
  assert.deepEqual(r.errors, []);
  assert.match(r.notes.join('\n'), /Aprovado para parceiro por @parcerias-bull/);
});

test('breaking sem aprovador configurado: falha fechado com mensagem clara', () => {
  const r = gate.evaluate({
    labels: ['cl:feat', 'partner:breaking'],
    body: BREAKING_BODY,
    reviews: approved,
    config: { ...CONFIG, partnerApprovers: [] },
  });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /partnerApprovers` está vazio/);
  assert.match(r.errors[0], /falha fechado/);
});

test('breaking sem aprovação: comentário e aprovação de quem não é aprovador não contam', () => {
  for (const reviews of [[], [review(APPROVER, 'COMMENTED')], [review('outra-pessoa', 'APPROVED')]]) {
    const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY, reviews });
    assert.equal(r.errors.length, 1, JSON.stringify(reviews));
    assert.match(r.errors[0], /exige aprovação .* @parcerias-bull/);
  }
});

test('breaking com aprovação revogada: vale a última review do aprovador', () => {
  const revogadas = [
    [review(APPROVER, 'APPROVED'), review(APPROVER, 'CHANGES_REQUESTED')],
    [review(APPROVER, 'DISMISSED')], // aprovação descartada: a API devolve a review com state DISMISSED
  ];
  for (const reviews of revogadas) {
    const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY, reviews });
    assert.equal(r.errors.length, 1, JSON.stringify(reviews));
    assert.match(r.errors[0], /exige aprovação/);
  }
  // Comentário depois da aprovação não revoga; nova aprovação depois do pedido de mudança vale.
  for (const reviews of [
    [review(APPROVER, 'APPROVED'), review(APPROVER, 'COMMENTED')],
    [review(APPROVER, 'CHANGES_REQUESTED'), review(APPROVER, 'APPROVED')],
    [review('Parcerias-Bull', 'APPROVED')],
  ]) {
    assert.deepEqual(evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY, reviews }).errors, [], JSON.stringify(reviews));
  }
});

test('breaking sem Docs, ou com Docs que não é PR do repo de docs', () => {
  const semDocs = BREAKING_BODY.replace(/^Docs:.*$/m, '');
  let r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: semDocs, reviews: approved });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /exige o campo `Docs:`/);

  for (const docs of ['https://docs.bullcredtech.com/changelog', 'https://github.com/BullCredTech/bull-module-proposals/pull/1', 'pendente']) {
    r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace(DOCS, docs), reviews: approved });
    assert.equal(r.errors.length, 1, docs);
    assert.match(r.errors[0], /precisa apontar para um PR de BullCredTech\/bull-api-docs-gitbook/);
  }

  // Forma curta owner/repo#N também vale.
  r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace(DOCS, 'BullCredTech/bull-api-docs-gitbook#42'), reviews: approved });
  assert.deepEqual(r.errors, []);
});

test('breaking sem Flag, ou com Flag fora do formato api.<nome>', () => {
  const semFlag = BREAKING_BODY.replace(/^Flag:.*$/m, 'Flag:');
  let r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: semFlag, reviews: approved });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /exige o campo `Flag:`/);

  for (const flag of ['sdk.otp_disabled', 'api.', 'API.Campo', 'api.campo x']) {
    r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.remove_campo_x', flag), reviews: approved });
    assert.equal(r.errors.length, 1, flag);
    assert.match(r.errors[0], /formato `api.<nome>`/);
  }
  // Crase em volta da chave é tolerada.
  r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY.replace('api.remove_campo_x', '`api.remove_campo_x`'), reviews: approved });
  assert.deepEqual(r.errors, []);
});

test('breaking com o template vazio: Docs e Flag faltam (a linha de baixo não vira valor)', () => {
  const r = evaluate({ labels: ['cl:feat', 'partner:breaking'], body: TEMPLATE_BODY, reviews: approved });
  assert.equal(r.errors.length, 2);
  assert.match(r.errors[0], /exige o campo `Docs:`/);
  assert.match(r.errors[1], /exige o campo `Flag:`/);
});

test('breaking sem nada: lista todas as pendências de uma vez', () => {
  const r = gate.evaluate({ labels: ['cl:feat', 'partner:breaking'], body: '', reviews: [], config: { ...CONFIG, partnerApprovers: [] } });
  assert.equal(r.errors.length, 3);
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

test('run: breaking busca as reviews e passa com aprovação; o TODO do catálogo vira nota', async () => {
  const github = fakeOctokit({
    'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY }),
    'GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews': () => approved,
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(7, 'pull_request_review'), core, config: CONFIG });
  assert.equal(core.failed, null);
  assert.match(core.infos.join('\n'), /Flag `api.remove_campo_x`: verificação no catálogo de flags ainda não implementada/);
});

test('run: breaking sem aprovação falha', async () => {
  const github = fakeOctokit({
    'GET /repos/{owner}/{repo}/pulls/{pull_number}': () => prFixture({ labels: ['cl:feat', 'partner:breaking'], body: BREAKING_BODY }),
    'GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews': () => [review(APPROVER, 'COMMENTED')],
  });
  const core = fakeCore();
  await gate.run({ github, context: ctx(), core, config: CONFIG });
  assert.match(core.failed, /1 pendência\(s\)/);
  assert.match(core.failed, /exige aprovação/);
});

test('run: PR contra outra base (ex.: staging, via pull_request_review) não é avaliado', async () => {
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
  assert.ok(fs.existsSync(path.join(root, 'scripts/changelog/gate.js')));
});
