# Changelog tech

Esse documento descreve a esteira determinística do changelog tech: as labels de cada PR, os campos da descrição, o gate `changelog-gate`, o digest no Slack, a ponte com o registro de mudanças programadas e o contrato com o agente que classifica os PRs.

## Por que existe

- Não há visibilidade do que o time tech entrega, nem um filtro do que precisa ser comunicado ao parceiro.
- Uma mudança que quebra contrato vai direto para produção, e o parceiro descobre pelo erro.
- O https://docs.bullcredtech.com/changelog está parado desde 05/05/2026.

A solução tem três camadas, e quase tudo é automático:

| Camada | Quem | O que faz |
|---|---|---|
| **Classificador** | um agente LLM (o tech-agent ou o avaliador) | lê o diff e aplica as labels. Também mantém **um** comentário com o resumo e o texto para o parceiro |
| **Esteira determinística** (este repo) | GitHub Actions, sem LLM | lê as labels, os campos e o comentário, bloqueia o merge quando falta algo e posta o digest |
| **Ponte `changelog-bridge`** | Lambda no `bull-module-devops`, sem LLM | re-executa o gate quando alguém muda labels, descrição ou reviews e, no merge de um PR breaking, cria o rascunho da mudança programada no changes-api. Veja [A ponte](#a-ponte-changelog-bridge) |

O classificador **sugere**. Quem **bloqueia** é sempre uma regra determinística. A esteira não sabe qual LLM classificou: basta seguir o [contrato](#contrato-com-o-classificador).

**Quem aprova um breaking:** a revisão normal do PR, feita por qualquer pessoa, aprova a classificação. Não há lista de aprovadores. A aprovação voltada ao parceiro acontece no BMS, quando alguém **Anuncia** a mudança programada. Até lá, nada chega ao parceiro nem ao /changelog.

### O que a esteira faz e o que não faz

| Faz | Não faz |
|---|---|
| Exige uma label `cl:*` e uma `partner:*` em todo PR para `main` | Não classifica nem aplica labels: isso é do classificador ou de quem abre o PR |
| Em `partner:breaking`, exige `Flag:` e `Docs:` | Não exige aprovação própria: vale a revisão normal do PR |
| Posta o digest diário e o semanal no Slack | Não olha data: a vigência vive no registro de mudanças programadas |
| Lê o `summary` do comentário do classificador | Não verifica se a flag existe: no merge, a [ponte](#a-ponte-changelog-bridge) cria a mudança programada com ela |
| | Não cria a mudança programada (é da ponte) e não publica o /changelog (é do sync no `bull-api-docs-gitbook`, depois do anúncio no BMS) |

### Repos do piloto

Ficam em `scripts/changelog/config.json`:

- `bull-module-proposals`
- `bull-module-auction`
- `bull-module-receivables`

O antigo `bull-api-receivables` foi renomeado para `bull-module-receivables`. A API REST segue o nome antigo, mas a busca não segue, então o config usa o nome novo. O `bull-lambda-webhook-sender` está arquivado desde 28/10/2026 e o código dele foi para o `bull-module-proposals`, por isso não entra no piloto.

## Labels

Exatamente **uma de cada eixo** por PR.

**Tipo: o que o PR é.**

| Label | Quando |
|---|---|
| `cl:feat` | funcionalidade nova ou mudança de comportamento |
| `cl:fix` | correção de bug |
| `cl:perf` | ganho de desempenho sem mudança de comportamento |
| `cl:security` | correção ou reforço de segurança (inclui bump de dependência por CVE) |
| `cl:infra` | CI, build, deploy, Terraform, Helm |
| `cl:chore` | manutenção, refatoração, docs, testes |

**Impacto no parceiro: se o parceiro precisa saber.**

| Label | Quando | Exemplos |
|---|---|---|
| `partner:none` | o parceiro não percebe | rota interna, BMS, infra, refatoração, cálculo interno sem mudança no contrato |
| `partner:additive` | mudança compatível que vale comunicar. O parceiro precisa tolerar o novo, mas não precisa mudar nada | campo novo na resposta, endpoint novo, valor novo de enum, webhook novo |
| `partner:breaking` | o parceiro precisa mudar algo, ou quebra | remover ou renomear campo, mudar tipo ou formato, tornar obrigatório o que era opcional, validação mais restritiva, mudar status HTTP ou semântica, remover endpoint |

A escala é `none` < `additive` < `breaking`. A escalada automática **só sobe**. Rebaixar é sempre decisão humana.

As labels são criadas pelo script (idempotente, `gh label create --force`):

```bash
node scripts/changelog/setup-labels.js --dry-run   # mostra os comandos
node scripts/changelog/setup-labels.js             # aplica nos repos do config.json
```

### Fallback pelo título (só no digest)

Um PR sem label `cl:*` cai no prefixo Conventional Commits do título. O gate não usa esse fallback: para ele, PR sem label não passa.

| Prefixo | Tipo |
|---|---|
| `feat` | feat |
| `fix`, `hotfix` | fix |
| `perf` | perf |
| `security`, `sec` | security |
| `ci`, `infra`, `build` | infra |
| `chore`, `refactor`, `docs`, `test`, `style`, `revert` | chore |

Um PR sem label e sem prefixo reconhecível vai para a seção "❔ Sem classificação" do digest.

## Campos da descrição do PR

O template da org (`.github/PULL_REQUEST_TEMPLATE.md`) traz a seção `## Changelog`:

```
Changelog:
Parceiro:
Flag:
Docs:
```

| Campo | Obrigatório | Formato | Quem lê |
|---|---|---|---|
| `Changelog:` | não | uma frase para o time interno | digest. Vazio: usa o `summary` do classificador ou, sem ele, o título |
| `Parceiro:` | não. Sem ele com `additive`/`breaking`, o gate só anota | frase para o parceiro | etapas seguintes (/changelog, mudança programada) |
| `Flag:` | **sim, com `partner:breaking`** | `api.<nome>`: minúsculas, dígitos, `_` e `.` (ex.: `api.remove_campo_legado`). É o formato de chave do changes-api; hífen não vale | gate e ponte |
| `Docs:` | **sim, com `partner:breaking`** | link do PR em `BullCredTech/bull-api-docs-gitbook` (URL ou `BullCredTech/bull-api-docs-gitbook#123`) | gate |

Regras de leitura:

- O valor fica **na mesma linha**. Um campo vazio continua vazio: a linha de baixo nunca vira valor.
- Texto dentro de `<!-- -->` é ignorado. O template explica os campos num comentário, e esse comentário não conta.
- Aceita lista (`- Flag: ...`), negrito (`**Flag:** ...`) e crase em volta do valor.

Exemplo de PR breaking preenchido:

```
Changelog: GET /contracts deixa de devolver o campo legado `bank_code`
Parceiro: O campo `bank_code` sai da resposta de GET /contracts; use `bank.code`.
Flag: api.contracts_remove_bank_code
Docs: https://github.com/BullCredTech/bull-api-docs-gitbook/pull/123
```

**Templates locais:** um template no próprio repo tem precedência sobre o da org. Três repos do piloto têm template próprio e precisam da mesma seção `## Changelog`, com as quatro linhas:

- `bull-module-proposals/.github/pull_request_template.md`
- `bull-module-auction/.github/pull_request_template.md`
- `bull-module-receivables/.github/pull_request_template.md`

## O gate `changelog-gate`

O workflow é `.github/workflows/changelog.yml` e a lógica fica em `scripts/changelog/gate.js`. Ele roda no repo alvo, com o `GITHUB_TOKEN` de lá (`contents: read`, `pull-requests: read`). Os scripts vêm do `BullCredTech/.github`, que é público, no mesmo commit do workflow (`github.workflow_sha`).

O gate passa quando:

1. há **exatamente uma** label `cl:*` e **exatamente uma** `partner:*`. A mensagem diz o que falta ou o que sobra;
2. com `partner:breaking`, também:
   - `Flag:` tem uma chave no formato `api.<nome>`;
   - `Docs:` aponta para um PR do `BullCredTech/bull-api-docs-gitbook`.

Só isso. O gate **não** exige aprovação própria (a revisão normal do PR basta) e **não** verifica se a flag existe: no merge, a [ponte](#a-ponte-changelog-bridge) cria a mudança programada com essa flag no changes-api, ou anexa o PR à mudança viva que já tem a flag. Até a virada, a flag fica desligada e o código entra sem efeito.

PR com base diferente de `main` (ex.: `staging`) não é avaliado: o gate passa direto. O gate **não olha data**. A vigência de uma breaking change vive no registro de mudanças programadas.

Exemplo de falha:

```
changelog-gate: 2 pendência(s) no PR #212:
- `partner:breaking` exige o campo `Docs:` na descrição, com o link do PR em BullCredTech/bull-api-docs-gitbook.
- `partner:breaking` exige o campo `Flag:` na descrição, com a chave da feature flag (formato `api.<nome>`).
Como resolver: https://github.com/BullCredTech/.github/blob/main/docs/CHANGELOG_TECH.md
```

Num breaking que passa, o gate deixa um *notice* no resumo do check, para ninguém achar que o merge já avisou o parceiro:

```
changelog-gate: OK — PR #212 com cl:feat + partner:breaking.
Lembrete: a mudança só chega ao parceiro quando alguém clicar em Anunciar no BMS. No merge, a ponte cria o rascunho da mudança programada da flag `api.contracts_remove_bank_code` (ou anexa este PR à mudança que já tem a flag); até o anúncio, nada vai para o /changelog nem para o parceiro.
```

### Quando o gate roda (importante)

Como workflow de ruleset, o GitHub só dispara o gate em **`pull_request` `opened`, `synchronize` e `reopened`** e ignora os outros tipos e eventos do `on:`. A [documentação de rulesets](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) diz isso: *"The workflow is only triggered, and is always triggered, by the default activity types of the supported events"*. O histórico do `weekend-holiday-merge-gate` confirma: nenhuma execução por `pull_request_review`.

Na prática, **mudar label ou descrição não reavalia o gate sozinho.** Quem re-executa:

| Quem | Quando | Demora |
|---|---|---|
| **Classificador** | logo depois de aplicar ou trocar labels (veja o [contrato](#c-re-executar-o-gate-depois-de-mudar-labels)) | segundos: é o caminho rápido |
| **[Ponte](#a-ponte-changelog-bridge)** | quando labels, descrição ou reviews mudaram depois da última execução. Cobre as mudanças feitas por humanos | até ~5 min, o intervalo da Lambda |
| **Você**, para não esperar | quando quiser | na hora |

Para re-executar à mão:

- **Pela UI:** aba *Checks* do PR → `changelog-gate` → *Re-run*.
- **Pela API**, que é o que o classificador e a ponte fazem. Precisa de `actions: write` no repo, e o check precisa ter terminado:

```bash
REPO=BullCredTech/bull-module-proposals; PR=212
SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid)
JOB=$(gh api "repos/$REPO/commits/$SHA/check-runs?check_name=changelog-gate" --jq '.check_runs[0].id')
gh api -X POST "repos/$REPO/actions/jobs/$JOB/rerun"
```

O re-run usa o estado atual do PR, porque o gate relê labels e descrição na API em vez de confiar no payload do evento. Os tipos `labeled`, `unlabeled` e `edited` ficam no `on:` para o caso de o workflow rodar como workflow local.

## A ponte `changelog-bridge`

É uma Lambda agendada no `bull-module-devops`, `bull-devops-production-fn-changelog-bridge`, que roda a cada 5 min dentro da VPC, para alcançar o changes-api, e fala com o GitHub por um GitHub App próprio. **Está sendo construída agora**: até ela entrar no ar, as funções abaixo não acontecem.

Ela faz três coisas:

1. **Re-executa o gate.** Nos PRs abertos para `main` dos repos do piloto, quando labels, descrição ou reviews mudaram depois da última execução do `changelog-gate`, ela re-executa o job. É o que cobre as mudanças humanas, já que workflow de ruleset só roda em `opened`, `synchronize` e `reopened`. O classificador continua re-executando o gate depois de rotular, porque é mais rápido que esperar o ciclo da ponte.
2. **Cria o rascunho da mudança programada.** Num PR mergeado com `partner:breaking`, faz `POST /v1/admin/scheduled-changes` no changes-api com:
   - `flag_keys`: a chave do `Flag:`;
   - `source_prs`: a URL do PR;
   - `docs_pr_url`: o `Docs:`;
   - os textos do [comentário do classificador](#b-um-comentário-sempre-o-mesmo), quando existir (`partner_text`, `migration_guide`, `docs`).

   Se a flag já pertence a uma mudança viva, o changes-api só anexa o PR. A chamada é idempotente por URL de PR, então reprocessar não duplica nada.
3. **Guarda cursor e estado próprios** (DynamoDB ou SSM), para não reprocessar.

Depois do merge, o fluxo segue no BMS e no changes-api, fora desta esteira:

1. O rascunho nasce com a vigência no aviso mínimo (hoje, 60 dias depois da criação).
2. Alguém revisa no BMS o texto para o parceiro, o guia de migração, os endpoints e a data, e clica em **Anunciar**. É essa a aprovação voltada ao parceiro.
3. Com o anúncio, a mudança vai para o /changelog (pelo sync do `bull-api-docs-gitbook`), as respostas afetadas passam a levar os headers `Deprecation` e `Sunset`, e o changes-api começa a régua de lembretes no Slack (T-30 e T-7).

A ponte não usa secret deste repo: o GitHub App e o acesso ao changes-api ficam no `bull-module-devops`.

## O digest

O workflow é `.github/workflows/changelog-digest.yml` e a lógica fica em `scripts/changelog/digest.js`. Ele roda **neste** repo.

| Quando | O que posta | Janela |
|---|---|---|
| ter–sex, 09:00 BRT | diário | do dia útil anterior 09:00 até hoje 09:00 |
| segunda, 09:00 BRT | diário **e** semanal | diário: de sexta 09:00 até segunda 09:00. Semanal: 7 dias, de segunda a segunda 09:00 |
| `workflow_dispatch` | o `mode` escolhido (`daily`/`weekly`) | a do modo, ou de `since` (ISO 8601) até agora |

A janela termina às 09:00 de hoje, e não "agora". Assim um PR mergeado entre 09:00 e o horário real do cron, que o GitHub atrasa alguns minutos, sai só no digest do dia seguinte e não aparece duas vezes. Feriado não é tratado: o cron posta no feriado também, e a janela seguinte começa nele, sem buraco.

**Fonte:** uma busca por repo do piloto (`is:pr is:merged base:main merged:<janela>`), com o token `CHANGELOG_GH_TOKEN`.

**Agrupamento**, nesta ordem. O impacto no parceiro tem precedência sobre o tipo:

| Seção | Critério |
|---|---|
| 🔴 Quebra contrato com parceiro | `partner:breaking` |
| 🟡 Comunicar ao parceiro | `partner:additive` |
| ✨ Novidades | `cl:feat` |
| 🐛 Correções | `cl:fix` |
| ⚡ Performance | `cl:perf` |
| 🔒 Segurança | `cl:security` |
| ❔ Sem classificação | sem label de tipo e sem prefixo reconhecível |
| ⚙️ contagem | `cl:infra` e `cl:chore` aparecem só como número |

O resumo de cada PR vem, nesta ordem:

1. da linha `Changelog:` da descrição;
2. do `summary` do comentário do classificador;
3. do título sem o prefixo Conventional Commits.

Quando falta alguma label, o digest informa quantos PRs estão sem `cl:*` ou `partner:*`.

No **semanal**, a seção **🗓️ Breaking em aberto** lista os PRs abertos para `main` com `partner:breaking`.

**Slack:**

- posta por Incoming Webhook, com `unfurl_links: false`;
- os links ficam no formato `<url|repo#n>`, e `& < >` são escapados;
- **diário sem PR não posta**; o semanal posta sempre, como sinal de vida.

Exemplo, extraído de uma execução real em dry-run:

```
*Changelog tech — semanal* · 27/10 09:00 → 03/11 08:02 (BRT) · 70 PRs mergeados

*✨ Novidades*
• <https://github.com/BullCredTech/bull-module-proposals/pull/177|bull-module-proposals#177> publica celcoin_application_id no evento de contrato
...
*🐛 Correções*
• <https://github.com/BullCredTech/bull-module-proposals/pull/197|bull-module-proposals#197> use distinctOn for the batch margin lookup

⚙️ 5 infra · 15 chore

⚠️ 70 de 70 PRs sem label de changelog (falta `cl:*` ou `partner:*`): ...

*🗓️ Breaking em aberto*
_Nenhum PR aberto com `partner:breaking`._
```

## Contrato com o classificador

O classificador pode ser **qualquer LLM**, como o tech-agent ou o avaliador. A esteira só lê labels e um comentário com formato fixo, então trocar de classificador não muda nada aqui.

**Quando rodar:** em PR para `main` dos repos do piloto, nos eventos `opened`, `synchronize`, `reopened`, `ready_for_review` e `edited`.

**Permissões no repo alvo:**

- `pull-requests: write`, para labels e o comentário;
- `actions: write`, para re-executar o gate.

### (a) Labels: preencher o vazio e só escalar

| Situação no eixo | O que o classificador faz |
|---|---|
| Vazio | aplica a sua sugestão |
| Tipo (`cl:*`) já preenchido | **não mexe**, mesmo que discorde. Explica no `reason` |
| Impacto (`partner:*`) já preenchido, sugestão **mais grave** | troca pela mais grave: adiciona a nova e remove a antiga, deixando uma só no eixo |
| Impacto já preenchido, sugestão igual ou **menos grave** | **não mexe**. Rebaixar é sempre humano |
| Mais de uma label no eixo | não mexe. O gate já aponta, e quem resolve é humano |

Exemplos:

| Labels atuais | Sugestão | Ação |
|---|---|---|
| nenhuma | `feat` + `additive` | adiciona `cl:feat` e `partner:additive` |
| `cl:fix` + `partner:none` | `fix` + `additive` | troca `partner:none` por `partner:additive` |
| `cl:feat` + `partner:breaking` | `feat` + `additive` | nada. Diz no comentário que vê additive e por quê |
| `cl:chore` | `feat` + `none` | mantém `cl:chore` e adiciona `partner:none` |

Escalar para `partner:breaking` **bloqueia o merge** até ter `Flag:` e `Docs:`. É o lado seguro: na dúvida entre additive e breaking, escale e explique. Quem revisa o PR vê a classificação e, se discordar, rebaixa.

Use os endpoints de adicionar e remover label (`POST`/`DELETE /repos/{owner}/{repo}/issues/{n}/labels`). Nunca use o `PUT` que substitui todas as labels: ele apaga labels de outros fluxos, como `migration` e `dependencies`.

### (b) Um comentário, sempre o mesmo

- **Um** comentário por PR. A **primeira linha** é exatamente `<!-- changelog-bot -->`.
- Nas execuções seguintes, ache o comentário pelo marcador e **edite-o** (`PATCH`). Não crie outro. Se houver mais de um, a esteira lê o último.
- O comentário traz um bloco ` ```json ` com o objeto abaixo. A esteira lê o primeiro bloco ` ```json ` do comentário, que precisa passar em `JSON.parse`: sem comentários e sem vírgula sobrando. Depois do bloco vem o texto legível para humanos.

| Campo | Tipo | Conteúdo |
|---|---|---|
| `type` | `"feat" \| "fix" \| "perf" \| "security" \| "infra" \| "chore"` | o tipo que o classificador sugere |
| `partner` | `"none" \| "additive" \| "breaking"` | o impacto que o classificador sugere |
| `summary` | string | **uma frase**, em português, para o time interno, com até 280 caracteres. **É o que o digest usa** quando a descrição não tem `Changelog:` |
| `partner_text` | string | frase para o parceiro. `""` quando `partner` é `none` |
| `migration_guide` | string (markdown) | antes e depois, com exemplo de request e response. `""` quando não é breaking |
| `docs` | array de strings | caminhos no `bull-api-docs-gitbook` que mudam. `[]` se nenhum |
| `reason` | string | por que essa classificação, com a evidência: arquivos, endpoints, campos |

Os campos `type` e `partner` do JSON são a **sugestão**. O que vale para o gate e para o agrupamento são as **labels**. O digest lê só o `summary`. No merge de um breaking, a [ponte](#a-ponte-changelog-bridge) leva `partner_text`, `migration_guide` e `docs` para o rascunho da mudança programada, onde alguém revisa antes de anunciar.

Exemplo, additive:

````markdown
<!-- changelog-bot -->
### Changelog (classificador)

```json
{
  "type": "feat",
  "partner": "additive",
  "summary": "GET /contracts?proposal_id= passa a devolver seguro e seguradora do contrato",
  "partner_text": "A resposta de GET /contracts?proposal_id= ganha os campos `insurance` e `insurer`.",
  "migration_guide": "",
  "docs": ["api-reference/contracts/get-contracts.md"],
  "reason": "Campos novos no DTO de resposta (contracts.dto.ts); nenhum campo removido ou alterado."
}
```

**Tipo:** feat · **Impacto no parceiro:** additive. Campos novos na resposta; parceiro não precisa mudar nada.
````

Exemplo, breaking. O texto aponta o que falta para o gate passar:

````markdown
<!-- changelog-bot -->
### Changelog (classificador)

```json
{
  "type": "feat",
  "partner": "breaking",
  "summary": "Remove o campo legado bank_code de GET /contracts",
  "partner_text": "O campo `bank_code` sai da resposta de GET /contracts. Use `bank.code`.",
  "migration_guide": "**Antes:** `{\"bank_code\": \"341\"}`\n**Depois:** `{\"bank\": {\"code\": \"341\"}}`\nTeste em staging com a flag `api.contracts_remove_bank_code` ligada para a sua origem.",
  "docs": ["api-reference/contracts/get-contracts.md"],
  "reason": "Campo removido do DTO de resposta; parceiros que leem bank_code quebram."
}
```

**Tipo:** feat · **Impacto no parceiro:** breaking. Para o merge: `Flag:` (sugestão `api.contracts_remove_bank_code`) e `Docs:` com o PR de doc. O parceiro só fica sabendo quando alguém Anunciar no BMS.
````

Exemplo, sem impacto:

````markdown
<!-- changelog-bot -->
```json
{"type": "infra", "partner": "none", "summary": "Alarmes das lambdas do leilão passam a notificar o Slack em produção", "partner_text": "", "migration_guide": "", "docs": [], "reason": "Só Terraform de alarmes; nenhuma rota ou payload muda."}
```
````

### (c) Re-executar o gate depois de mudar labels

Como o gate não reage a `labeled` (veja [Quando o gate roda](#quando-o-gate-roda-importante)), o classificador, **depois de aplicar ou trocar labels**:

1. espera o check `changelog-gate` do commit de cabeça terminar (`status: completed`);
2. re-executa o job, com os [comandos acima](#quando-o-gate-roda-importante).

Sem isso, o PR fica vermelho até a ponte re-executar o gate, alguém clicar em *Re-run* ou fazer um push novo.

### (d) O que o classificador não faz

- Não edita a descrição do PR: os campos `Changelog:`, `Parceiro:`, `Flag:` e `Docs:` são de quem abre o PR.
- Não aprova, não faz merge, não abre PR e não posta no Slack.
- Não rebaixa impacto e não troca um tipo já marcado.

## Secrets e permissões

| Secret | Onde | Para quê | Como obter |
|---|---|---|---|
| `SLACK_CHANGELOG_WEBHOOK` | Actions secrets do `BullCredTech/.github` | postar o digest | Incoming Webhook de um app do Slack, apontando para o canal do changelog |
| `CHANGELOG_GH_TOKEN` | Actions secrets do `BullCredTech/.github` | o digest ler os PRs dos repos do piloto, que são privados. O `GITHUB_TOKEN` deste repo não os enxerga | **fine-grained PAT** (resource owner `BullCredTech`, só os repos do piloto, permissão *Pull requests: Read-only*) ou token de **GitHub App** com a mesma permissão |

O PAT expira, e o GitHub App não. Com PAT, anote a data de renovação. Repo novo no `config.json` também precisa entrar no token. Sem acesso, o digest falha com `422 ... cannot be searched` e cita o repo.

O gate não precisa de secret: usa o `GITHUB_TOKEN` do repo alvo, só leitura. A ponte também não usa secret daqui (veja [A ponte](#a-ponte-changelog-bridge)).

## Como ativar

Passos de admin, nesta ordem:

1. **Merge deste PR** no `BullCredTech/.github`.
2. **Labels:** rodar `node scripts/changelog/setup-labels.js --dry-run`, revisar e rodar sem `--dry-run`. Precisa de permissão *triage* ou mais nos repos.
3. **Templates locais:** adicionar a seção `## Changelog` nos três templates listados em [Campos da descrição do PR](#campos-da-descrição-do-pr).
4. **Dependabot:** o PR do Dependabot não tem quem classifique, porque workflows disparados por ele não recebem os secrets. Em cada `dependabot.yml` do piloto, coloque `labels: ["dependencies", "cl:chore", "partner:none"]`. A lista **substitui** as labels padrão, por isso `dependencies` vai junto.
5. **Secrets:** criar `SLACK_CHANGELOG_WEBHOOK` e `CHANGELOG_GH_TOKEN` neste repo (*Settings → Secrets and variables → Actions*).
6. **Testar o digest:** *Actions → changelog-digest → Run workflow*, com `mode: weekly` e `dry_run: true`, e ler a mensagem no log. Depois, uma vez com `dry_run: false`, para validar o canal.
7. **Ponte:** deploy da `changelog-bridge` no `bull-module-devops`, com o GitHub App instalado nos repos do piloto e o changes-api no ar. O App precisa ler PRs, reviews e checks e re-executar jobs (*Pull requests: Read*, *Checks: Read*, *Actions: Read and write*). Sem a ponte, o gate ainda funciona, mas mudança humana de label exige *Re-run* manual e o merge de um breaking não gera rascunho no BMS.
8. **Ruleset `changelog-required`** (*org Settings → Repository → Rulesets → New branch ruleset*):
   - **Enforcement:** **Evaluate** primeiro.
   - **Target repositories:** os repos do piloto **por nome**, sem wildcard, pelo mesmo motivo do [gate de fim de semana](MERGE_GATE_FIM_DE_SEMANA_FERIADO.md).
   - **Target branches:** default branch (`main`).
   - **Regra:** *Require workflows to pass before merging*, com o workflow `BullCredTech/.github` → `.github/workflows/changelog.yml`, ref `refs/heads/main`.
   - **Bypass list:** *Organization admin*, para override de emergência com rastro auditável.
   - Deixe em Evaluate por uma ou duas semanas e acompanhe em *Rule insights* quantos PRs falhariam e por quê. Confira também, na primeira execução, que o checkout dos scripts funciona.
   - Com o classificador e a ponte no ar, mude para **Active**. Um workflow que passou em Evaluate vale no Active sem rodar de novo.
   - A regra bloqueia push direto em `main`. Os repos do piloto já exigem PR, mas confira se nenhuma automação faz push direto na `main` deles.

Antes do Active, o classificador precisa estar no ar, ou o time precisa estar avisado de que aplica as labels à mão. Senão todo PR nasce bloqueado. Sem a ponte, avise também que, depois de mudar label ou descrição, é preciso clicar em *Re-run*.

## Como testar

Testes unitários (rodam no CI pelo `changelog-tests.yml` em PR que toca `scripts/changelog/**`):

```bash
node --test scripts/changelog/test/*.test.js
```

Gate, sem rede:

```bash
node -e "
const g = require('./scripts/changelog/gate');
console.log(g.evaluate({ labels: ['cl:feat', 'partner:breaking'], body: 'Flag: api.x\nDocs: BullCredTech/bull-api-docs-gitbook#1' }));
"
```

Digest de verdade, **só leitura** e sem postar, com o seu token do `gh`:

```bash
cd "$(mktemp -d)" && npm init -y >/dev/null && npm i @octokit/rest@21 >/dev/null
cat > run.js <<'EOF'
const { Octokit } = require('@octokit/rest');
const digest = require(process.env.REPO_DIR + '/scripts/changelog/digest.js');
const core = { info: console.log, warning: (m) => console.log('::warning::' + m), setFailed: (m) => console.log('::error::' + m) };
digest.run({ github: new Octokit({ auth: process.env.GH_TOKEN }), core,
  context: { eventName: 'workflow_dispatch', payload: { inputs: { mode: process.argv[2] || 'weekly', dry_run: 'true' } } } });
EOF
REPO_DIR=/caminho/do/clone/.github GH_TOKEN=$(gh auth token) node run.js weekly
```

No Actions: *changelog-digest → Run workflow* com `dry_run: true`, que é o padrão.

Para testar o gate no ruleset em **Evaluate**, abra um PR de teste num repo do piloto, veja o check `changelog-gate`, mude as labels e re-execute.

## Manutenção

| Campo do `config.json` | Uso |
|---|---|
| `owner`, `repos` | repos do piloto, para o digest e o `setup-labels` |
| `baseBranch` | branch avaliada pelo gate e buscada pelo digest (`main`) |
| `timezone`, `digestHour` | fuso e hora das janelas do digest. O cron do workflow precisa bater com eles |
| `docsRepo` | repo onde o `Docs:` precisa apontar um PR |

- Mudança aqui exige PR no `BullCredTech/.github`, protegido por CODEOWNERS.
- **Repo novo no piloto:** `config.json` + token do digest + ruleset + labels (`setup-labels.js --repo <nome>`) + seção no template local + instalação do GitHub App da ponte e o repo na lista dela, no `bull-module-devops`.

## FAQ

**Meu PR ficou vermelho logo ao abrir.**
O gate rodou antes do classificador aplicar as labels. O classificador re-executa o gate ao terminar. Se ele não rodou, aplique as labels e clique em *Re-run*.

**Mudei a label (ou a descrição) e o check não mudou.**
É o esperado em workflow de ruleset: veja [Quando o gate roda](#quando-o-gate-roda-importante). A ponte re-executa o check em até ~5 min. Para não esperar, clique em *Re-run*.

**Quem precisa aprovar um PR breaking?**
Qualquer pessoa, na revisão normal do PR. Não existe lista de aprovadores. O parceiro só fica sabendo quando alguém Anunciar a mudança programada no BMS.

**Mergeei um breaking. E agora?**
A ponte cria o rascunho da mudança programada no changes-api. Abra no BMS, revise o texto para o parceiro, o guia de migração e a data, e clique em **Anunciar**. Sem o anúncio, a flag nunca vira e o parceiro nunca é avisado.

**E PR para `staging`?**
O gate só avalia PR para `main`. Para outras bases ele passa direto.

**Hotfix urgente que é breaking?**
O caminho certo é a flag: o código entra desligado e a virada é programada. Num incidente real, um admin pode fazer o bypass do ruleset pela UI, que deixa rastro auditável, como no gate de fim de semana.

**Por que o gate não olha a data de vigência?**
Porque a data muda: antecipar e adiar por parceiro. Ela vive no registro de mudanças programadas, editado no BMS. O merge não espera a vigência: o código entra desligado.

**E merge queue?**
Nenhum repo do piloto usa. Se um passar a usar, o workflow precisa do evento `merge_group`, senão a fila trava esperando o check.
