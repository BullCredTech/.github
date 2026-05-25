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
| `.github/workflows/weekend-holiday-merge-gate.yml` | Workflow do gate de merge em sex-sáb-dom + feriado + véspera |

## Como sobrescrever em repos específicos

Basta colocar o arquivo equivalente na raiz (ou em `.github/`) do repo de destino — a versão local sempre tem precedência sobre a default da org.

## Workflows reutilizáveis

O workflow `weekend-holiday-merge-gate.yml` precisa ser ativado em cada repo como **Required Workflow** via Settings → Code, planning, and automation → Required workflows (ou via API), e o status check `gate` referenciado no ruleset da org.
