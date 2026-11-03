'use strict';

// Octokit e core falsos para testar gate.run e digest.run sem rede.

/** routes: { 'GET /rota/{x}': (params) => data } */
function fakeOctokit(routes) {
  const calls = [];
  async function request(route, params = {}) {
    calls.push({ route, params });
    const handler = routes[route];
    if (!handler) throw new Error(`rota não mockada: ${route}`);
    return { data: await handler(params) };
  }
  // Como o octokit real: endpoints de busca devolvem { items }, o paginate achata para a lista.
  async function paginate(route, params = {}) {
    const { data } = await request(route, params);
    return Array.isArray(data) ? data : data.items;
  }
  return { request, paginate, calls };
}

function fakeCore() {
  const core = {
    infos: [],
    notices: [],
    warnings: [],
    failed: null,
    info: (m) => core.infos.push(m),
    notice: (m) => core.notices.push(m),
    warning: (m) => core.warnings.push(m),
    setFailed: (m) => {
      core.failed = m;
    },
  };
  return core;
}

/** Item no formato da busca do GitHub (GET /search/issues). */
function searchItem({ repo, number, title, body = '', labels = [], mergedAt = null, createdAt = null, owner = 'BullCredTech' }) {
  return {
    number,
    title,
    body,
    html_url: `https://github.com/${owner}/${repo}/pull/${number}`,
    repository_url: `https://api.github.com/repos/${owner}/${repo}`,
    labels: labels.map((name) => ({ name })),
    created_at: createdAt,
    pull_request: { merged_at: mergedAt },
  };
}

// Template da org como o PR chega: campos vazios, um por linha, com comentário explicativo.
const TEMPLATE_BODY = `## Summary

- muda X

## Changelog

<!--
Changelog: uma frase para o time interno.
Parceiro: frase para o parceiro.
Flag: api.<nome>
Docs: link do PR no bull-api-docs-gitbook
-->

Changelog:
Parceiro:
Flag:
Docs:

## Checklist

- [ ] Build passa
`;

module.exports = { fakeOctokit, fakeCore, searchItem, TEMPLATE_BODY };
