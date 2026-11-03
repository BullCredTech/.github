# BullCredTech `.github`

Repositório org-level que hospeda os community health files e workflows reutilizáveis aplicados por default em todos os repositórios da organização.

## Conteúdo

| Arquivo | Função |
|---|---|
| `profile/README.md` | Página inicial da org no GitHub (perfil público) |
| `CODE_OF_CONDUCT.md` | Código de conduta org-wide |
| `CONTRIBUTING.md` | Guia geral de contribuição |
| `SECURITY.md` | Política de reporte de vulnerabilidade |
| `SUPPORT.md` | Canais de suporte interno |
| `.github/PULL_REQUEST_TEMPLATE.md` | Template padrão de PR |
| `.github/ISSUE_TEMPLATE/*.yml` | Templates de issue (bug, feature) |
| `.github/workflows/weekend-holiday-merge-gate.yml` | Workflow do gate de merge em sáb-dom + feriado, e sexta e véspera de feriado a partir das 20h |
| `.github/workflows/changelog.yml` | Gate `changelog-gate` do changelog tech: exige uma label `cl:*` e uma `partner:*` e, em `partner:breaking`, `Flag:`, `Docs:` e aprovação de parcerias |
| `.github/workflows/changelog-digest.yml` | Digest do changelog tech no Slack: diário às 09:00 BRT e semanal na segunda |
| `.github/workflows/changelog-tests.yml` | Testes dos scripts do changelog (`node --test`) |
| `scripts/changelog/` | Scripts do changelog tech (taxonomia, gate, digest, criação das labels) e `config.json` com os repos do piloto e os aprovadores |
| `docs/CHANGELOG_TECH.md` | Como funciona o changelog tech, contrato com o classificador e passos para ativar |

## Como sobrescrever em repos específicos

Basta colocar o arquivo equivalente na raiz (ou em `.github/`) do repo de destino — a versão local sempre tem precedência sobre a default da org.

## Workflows reutilizáveis

O workflow `weekend-holiday-merge-gate.yml` precisa ser ativado em cada repo como **Required Workflow** via Settings → Code, planning, and automation → Required workflows (ou via API), e o status check `gate` referenciado no ruleset da org.

O workflow `changelog.yml` é ativado do mesmo jeito, pelo ruleset `changelog-required`, só nos repos do piloto (ver [docs/CHANGELOG_TECH.md](docs/CHANGELOG_TECH.md#como-ativar)). O `changelog-digest.yml` roda neste próprio repo e depende dos secrets `SLACK_CHANGELOG_WEBHOOK` e `CHANGELOG_GH_TOKEN`.
