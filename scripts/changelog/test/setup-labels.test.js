'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildCommands, parseArgs } = require('../setup-labels');

test('um `gh label create --force` por label em cada repo', () => {
  const cmds = buildCommands({ owner: 'BullCredTech', repos: ['a', 'b'] });
  assert.equal(cmds.length, 18);
  assert.deepEqual(cmds[0], [
    'gh', 'label', 'create', 'cl:feat', '--repo', 'BullCredTech/a', '--color', '0E8A16',
    '--description', 'Changelog: funcionalidade nova ou mudança de comportamento', '--force',
  ]);
  assert.ok(cmds.every((c) => c[c.length - 1] === '--force'));
  assert.deepEqual(new Set(cmds.map((c) => c[5])), new Set(['BullCredTech/a', 'BullCredTech/b']));
});

test('argumentos: --dry-run e --repo repetível; desconhecido falha', () => {
  assert.deepEqual(parseArgs(['--dry-run', '--repo', 'x', '--repo', 'y']), { dryRun: true, repos: ['x', 'y'] });
  assert.deepEqual(parseArgs([]), { dryRun: false, repos: null });
  assert.throws(() => parseArgs(['--apply']), /Argumento desconhecido/);
});
