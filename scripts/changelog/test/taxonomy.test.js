'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const t = require('../taxonomy');

test('allLabels: 6 de tipo + 3 de impacto, cor hex e descrição dentro do limite do GitHub', () => {
  const labels = t.allLabels();
  assert.deepEqual(
    labels.map((l) => l.name),
    ['cl:feat', 'cl:fix', 'cl:perf', 'cl:security', 'cl:infra', 'cl:chore', 'partner:none', 'partner:additive', 'partner:breaking'],
  );
  for (const l of labels) {
    assert.match(l.color, /^[0-9A-F]{6}$/, l.name);
    assert.ok(l.description.length > 0 && l.description.length <= 100, `${l.name}: ${l.description.length} caracteres`);
  }
});

test('leitura de labels aceita string ou { name } e ignora caixa', () => {
  const labels = [{ name: 'CL:Feat' }, 'partner:additive', { name: 'migration' }, null];
  assert.deepEqual(t.typesFromLabels(labels), ['feat']);
  assert.deepEqual(t.partnersFromLabels(labels), ['additive']);
  assert.deepEqual(t.typesFromLabels([]), []);
  assert.deepEqual(t.partnersFromLabels(undefined), []);
});

test('labels do eixo fora da taxonomia não contam e são apontadas', () => {
  const labels = ['cl:docs', 'partner:maybe', 'cl:fix', 'bug'];
  assert.deepEqual(t.typesFromLabels(labels), ['fix']);
  assert.deepEqual(t.partnersFromLabels(labels), []);
  assert.deepEqual(t.unknownAxisLabels(labels), ['cl:docs', 'partner:maybe']);
});

test('severidade do impacto: none < additive < breaking', () => {
  assert.ok(t.partnerSeverity('none') < t.partnerSeverity('additive'));
  assert.ok(t.partnerSeverity('additive') < t.partnerSeverity('breaking'));
  assert.equal(t.partnerSeverity('xyz'), -1);
  assert.equal(t.mostSevere(['none', 'breaking', 'additive']), 'breaking');
  assert.equal(t.mostSevere(['none']), 'none');
  assert.equal(t.mostSevere([]), null);
});

test('tipo a partir do prefixo Conventional Commits', () => {
  const cases = {
    'feat: x': 'feat',
    'feat(proposals-api): x': 'feat',
    'feat!: x': 'feat',
    'feat(api)!: x': 'feat',
    'Feat: x': 'feat',
    'fix: x': 'fix',
    'hotfix(prod): x': 'fix',
    'perf: x': 'perf',
    'security: x': 'security',
    'sec(deps): x': 'security',
    'ci(deploy): x': 'infra',
    'infra: x': 'infra',
    'build: x': 'infra',
    'chore(deps): x': 'chore',
    'refactor: x': 'chore',
    'docs: x': 'chore',
    'test: x': 'chore',
    'style: x': 'chore',
    'revert: x': 'chore',
  };
  for (const [title, type] of Object.entries(cases)) assert.equal(t.typeFromTitle(title), type, title);
  for (const title of ['deps: bump', 'Revert "feat: x"', 'Merge pull request #1', 'sem prefixo', '', null]) {
    assert.equal(t.typeFromTitle(title), null, String(title));
  }
});

test('stripPrefix tira tipo, escopo e "!", e devolve o título se não houver prefixo', () => {
  assert.equal(t.stripPrefix('feat(proposals-api): P0 decidida só pelo motor'), 'P0 decidida só pelo motor');
  assert.equal(t.stripPrefix('fix!:   espaço extra '), 'espaço extra');
  assert.equal(t.stripPrefix('Atualiza README'), 'Atualiza README');
  assert.equal(t.stripPrefix('deps: bump'), 'deps: bump');
  assert.equal(t.parseTitle('feat(api)!: muda').bang, true);
});
