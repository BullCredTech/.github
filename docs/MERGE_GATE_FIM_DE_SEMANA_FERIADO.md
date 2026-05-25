# Gate de Merge em Fim de Semana e Feriado

Esse documento descreve o gate org-wide que restringe merges na `main` durante janelas de maior risco operacional (fim de semana, feriados nacionais e vésperas de feriado).

## Por que existe

Mudanças em produção fora do horário comercial concentram risco:

- Time reduzido pra reagir a regressão.
- Janela de detecção e mitigação maior (em média horas, não minutos).
- Reviews tendem a ser superficiais (PRs aprovados e mergeados em minutos sem checklist completa).

O gate adiciona um ponto de fricção deliberado: nessas janelas, qualquer merge em `main` exige a aprovação explícita do responsável pelo gate (definido no próprio workflow). Em dias úteis o gate é transparente — não há fricção.

## Quando o gate dispara

O gate trava o merge se **qualquer** uma das condições for verdadeira, avaliada no fuso `America/Sao_Paulo`:

| Condição | Exemplo |
|---|---|
| O dia atual é **sexta**, **sábado** ou **domingo** | PR aberto sábado às 15h BRT |
| O dia atual é **feriado nacional** | Corpus Christi, 7 de setembro, etc. |
| O dia seguinte é **feriado nacional** (véspera) | Quarta-feira anterior a Corpus Christi |

Quando mais de uma condição se aplica, todas são listadas na mensagem (ex.: `Sun BRT + véspera de feriado (2026-09-07)`).

Fonte dos feriados: **[BrasilAPI](https://brasilapi.com.br/api/feriados/v1)** — feriados nacionais oficiais do ano corrente. Feriados estaduais e municipais não são considerados.

## Como funciona tecnicamente

- O workflow vive em `BullCredTech/.github/.github/workflows/weekend-holiday-merge-gate.yml` e é injetado em todo PR aberto contra `main` de qualquer repositório da organização via Ruleset org-wide.
- O status check chamado `gate` precisa terminar com sucesso pra que o merge seja liberado.
- O workflow é disparado nos eventos `pull_request` (open/sync/reopen/ready_for_review) e `pull_request_review` (submitted/dismissed) — ou seja, qualquer aprovação ou novo push recalcula o gate.
- Se a janela **não** for restrita, o gate passa automaticamente sem ação humana.
- Se a janela **for** restrita, o gate verifica se há uma review do tipo `APPROVED` cuja autoria seja o owner definido no workflow. **A última review desse owner é a que vale** — se ele aprovou e depois pediu mudanças, conta como pedido de mudança.

## O que fazer quando o gate bloqueia seu PR

1. **Avalie se realmente precisa ir agora.** A pergunta certa é "o custo de esperar segunda é maior que o risco de subir agora?". Quase sempre a resposta é "não" — o ponto desse gate é forçar essa avaliação.
2. Se a resposta for **não**, deixe o PR aberto. Na segunda o gate passa automaticamente.
3. Se a resposta for **sim** (hotfix crítico, incidente em produção, deploy programado), **peça aprovação ao responsável pelo gate** no canal de incidentes/engenharia. Ele vai revisar e aprovar — o status check é reavaliado automaticamente após a aprovação e o merge é liberado.

A mensagem do gate sempre informa o motivo do bloqueio e quem precisa aprovar.

## Override pra emergência

Em incidente real em produção fora do horário comercial, quando não dá pra esperar a aprovação humana, **administradores da organização podem fazer override pela UI do GitHub**:

1. No PR bloqueado, clicar em "Merge pull request".
2. Selecionar "Merge without waiting for requirements to be met (bypass rules)".
3. Confirmar.

Esse override **deixa rastro auditável** no log da org. Use só quando o impacto de esperar é maior que o risco da revisão acelerada — e abra retroativamente um post-mortem leve explicando o motivo.

## Como o gate é mantido

- Mudança no workflow exige PR no repo `BullCredTech/.github` — protegido por CODEOWNERS, apenas o responsável pelo gate aprova.
- A mudança do **owner** (login do GitHub) é feita editando a constante `OWNER` no script do workflow. Trocar de pessoa requer um PR aprovado pelo owner atual.
- O ruleset que torna o status check obrigatório vive na configuração de rulesets da organização (`Settings → Code, planning, and automation → Rulesets`).
- Em caso de indisponibilidade da BrasilAPI, o gate falha fechado — bloqueia o merge por precaução. Re-executar a check depois que a API voltar costuma resolver.

## Testando o gate antes de uma mudança real

O workflow expõe um `workflow_dispatch` com inputs `fake_date` (ex.: `2026-12-24T18:00:00`) e `fake_pr_number`. Disparando manualmente pela aba Actions, é possível simular qualquer cenário sem precisar esperar a data real. Em modo dispatch, o gate roda em "dry-run" — apenas loga o resultado, nunca falha o run.

## FAQ

**Esse gate vai me atrapalhar pra mergear coisas urgentes de seg-qui?**
Não. Em dias úteis o gate passa em <5 segundos sem nenhuma ação humana.

**Hotfix de produção em sábado é sempre bloqueado?**
Sim, **por design**. A intenção é forçar uma segunda leitura antes de subir. A aprovação acontece pelo Slack/WhatsApp em minutos pra hotfixes reais.

**E se eu sou o próprio owner do gate?**
A revisão de um PR pelo próprio autor não conta no GitHub (regra padrão da plataforma). Use o override administrativo pela UI nesse caso.

**Feriados estaduais/municipais (ex.: dia da padroeira de São Paulo) bloqueiam?**
Não. Só feriados nacionais. Se quiser cobrir, basta estender o workflow com uma lista local — abre PR no repo `.github`.

**O gate funciona com merge queue?**
Sim. Cada PR na fila é reavaliado individualmente.

**Posso desabilitar o gate pro meu repo?**
Não unilateralmente. O ruleset é org-wide e managed via configuração centralizada. Exceção via PR no `.github` adicionando o repo à lista de excluídos do ruleset, aprovada pelo owner.
