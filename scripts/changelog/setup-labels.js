#!/usr/bin/env node
'use strict';

// Cria ou atualiza as labels do changelog (cl:* e partner:*) nos repos do piloto.
// Idempotente: usa `gh label create --force`, que atualiza cor e descrição se a label já existe.
//
// Uso:
//   node scripts/changelog/setup-labels.js --dry-run            # só imprime os comandos
//   node scripts/changelog/setup-labels.js                      # aplica em todos os repos do config.json
//   node scripts/changelog/setup-labels.js --repo bull-x --dry-run
//
// Requer o `gh` autenticado com permissão de escrita (triage) nos repos.

const { execFileSync } = require('node:child_process');
const taxonomy = require('./taxonomy');
const config = require('./config.json');

/** Lista de comandos `gh` (argv) para cada label em cada repo. */
function buildCommands({ owner, repos }) {
  const cmds = [];
  for (const repo of repos) {
    for (const label of taxonomy.allLabels()) {
      cmds.push([
        'gh',
        'label',
        'create',
        label.name,
        '--repo',
        `${owner}/${repo}`,
        '--color',
        label.color,
        '--description',
        label.description,
        '--force',
      ]);
    }
  }
  return cmds;
}

function parseArgs(argv) {
  const args = { dryRun: false, repos: null };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--dry-run') args.dryRun = true;
    else if (argv[i] === '--repo') args.repos = (args.repos || []).concat(argv[(i += 1)]);
    else throw new Error(`Argumento desconhecido: ${argv[i]}`);
  }
  return args;
}

function shellQuote(arg) {
  return /^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replace(/'/g, `'\\''`)}'`;
}

function main(argv) {
  const args = parseArgs(argv);
  const repos = args.repos || config.repos;
  const unknown = repos.filter((r) => !config.repos.includes(r));
  if (unknown.length) console.warn(`Aviso: fora do piloto (config.json): ${unknown.join(', ')}`);

  const cmds = buildCommands({ owner: config.owner, repos });
  for (const argvCmd of cmds) {
    if (args.dryRun) {
      console.log(argvCmd.map(shellQuote).join(' '));
    } else {
      execFileSync(argvCmd[0], argvCmd.slice(1), { stdio: 'inherit' });
    }
  }
  console.log(`${args.dryRun ? '[DRY-RUN] ' : ''}${cmds.length} label(s) em ${repos.length} repo(s).`);
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}

module.exports = { buildCommands, parseArgs };
