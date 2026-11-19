# Infracost: custo estimado no PR de infraestrutura

Workflow reutilizável `.github/workflows/infracost.yml`. Em todo PR que mexe em Terraform/Terragrunt, ele
comenta a **mudança de custo mensal estimada** (antes × depois, por recurso e por workspace), usando o
[Infracost](https://github.com/infracost/infracost) CLI (open source, Apache-2.0).

- **Informativo:** não é check obrigatório e nunca falha por falta de chave. Não bloqueia merge.
- **Um comentário só por PR**, atualizado a cada push (reconhecido pelo marcador `<!-- bull-infracost -->`).
- **Sem credencial AWS e sem `terraform plan`:** o Infracost lê o HCL direto (modo "HCL parsing").
- **Só a Pricing API do Infracost.** Nada vai para o Infracost Cloud/dashboard (ver [Privacidade](#o-que-sai-para-o-infracost)).

## Como ligar num repo

1. O secret `INFRACOST_API_KEY` precisa estar visível para o repo (secret da org, ver [Passo manual](#passo-manual-chave-e-secret)).
2. Crie `.github/workflows/infracost.yml` no repo:

```yaml
name: infracost

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
    paths:
      - '**/*.tf'
      - '**/*.hcl'
      - '**/*.tfvars'
      - '**/infracost-usage.yml'

permissions:
  contents: read
  pull-requests: write

jobs:
  infracost:
    uses: BullCredTech/.github/.github/workflows/infracost.yml@main
    with:
      path: .                      # raiz do IaC no repo
    secrets:
      INFRACOST_API_KEY: ${{ secrets.INFRACOST_API_KEY }}
      # Só se houver módulo em repo git privado (git@github.com:...):
      # TERRAFORM_MODULES_SSH_KEY: ${{ secrets.<CHAVE_SSH_SO_LEITURA> }}
```

**Módulo de domínio (`bull-module-*`)**, com o IaC em `infra/` e código de aplicação no mesmo repo: filtre
`paths` em `infra/**` e passe `path: infra`. Assim o workflow nem sobe em PR que só mexe em `apis/` ou
`lambdas/`:

```yaml
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
    paths:
      - 'infra/**'
# ...
    with:
      path: infra
```

### Entradas

| Entrada | Padrão | Para quê |
|---|---|---|
| `path` | `.` | Raiz do IaC dentro do repo. Arquivo fora dela é ignorado. |
| `config-file` | vazio | Um [config do Infracost](https://www.infracost.io/docs/features/config_file/) versionado no repo. Desliga a escolha automática de workspaces (o mesmo arquivo vale para base e PR). |
| `max-projects` | `40` | Teto de workspaces por PR. Acima dele, o comentário lista o que ficou de fora. |
| `include-dependents` | `true` | Estima também quem depende (bloco `dependency` do Terragrunt) dos workspaces alterados, 1 nível. |
| `usage-file-name` | `infracost-usage.yml` | Nome do arquivo de uso procurado em cada workspace. |

| Secret | Obrigatório | Para quê |
|---|---|---|
| `INFRACOST_API_KEY` | não (sem ele o job avisa e sai verde) | Chave gratuita da Pricing API. |
| `TERRAFORM_MODULES_SSH_KEY` | não | Chave SSH só leitura para baixar módulo de repo git privado. |

## Como escolhe os workspaces

Rodar o Infracost no monorepo inteiro levaria dezenas de minutos (a base-infra tem ~480 workspaces). O
script `infracost/scripts/projects.py` olha os arquivos do PR (`git diff` entre o merge commit e a base) e
monta dois configs do Infracost (base e PR) só com os workspaces afetados:

1. **Workspace** = diretório com `terragrunt.hcl` que tem bloco `include` ou `terraform`. Repo sem Terragrunt:
   diretório com `.tf` que não é usado como módulo local por outro.
2. Arquivo dentro de um workspace (inclusive `infracost-usage.yml`, JSON de policy etc.): esse workspace.
3. Arquivo dentro de um **módulo local** (`modules/x`, ou qualquer diretório com `.tf` usado por um `source`
   local): todo workspace que usa o módulo, inclusive via outro módulo. Fonte com interpolação
   (`${get_repo_root()}/x`, `${dirname(find_in_parent_folders("root.hcl"))}/x`) é procurada a partir da
   raiz do repo e de cada ancestral do workspace, porque o `root.hcl` de um módulo de domínio fica em
   `infra/`. Fonte com subdiretório (`dir//stacks/x`, o formato dos `bull-module-*`) aponta para `dir/stacks/x`.
4. Outro `.hcl`/`.tf`/`.tfvars`/`.json` fora de workspace (`account.hcl`, `region.hcl`...): todos os
   workspaces abaixo dele, se couberem no teto. Se não couberem (ex.: `root.hcl`), o arquivo é listado como
   **não estimado**: na prática esses arquivos mexem em provider, state e tags, sem efeito de preço.
5. **Dependentes diretos** dos workspaces acima, lendo o `config_path` dos blocos `dependency` (os formatos
   `find_in_parent_folders("...")`, `${get_repo_root()}/...`, `${dirname(find_in_parent_folders("region.hcl"))}/...`,
   `${get_terragrunt_dir()}/../x` e caminho relativo). `config_path` com `${local.x}` não é resolvido.
6. Acima do teto, corta primeiro os dependentes. Workspace novo ou removido no PR aparece como adicionado
   ou removido no diff.

Arquivo que não é IaC (`docs/`, `README.md`, workflows) não dispara estimativa. Sem nenhum workspace
afetado, o job não comenta (e, se já havia comentário de um push anterior, atualiza para dizer isso).

## Terragrunt no modo HCL: o que o Infracost faz

O CLI 0.10 embute uma cópia da biblioteca do Terragrunt e avalia o HCL ele mesmo (não precisa do binário
`terragrunt` nem de credencial). Confirmado na [doc](https://www.infracost.io/docs/features/terragrunt/) e no
código da v0.10.50 (`internal/providers/terraform/terragrunt_hcl_provider.go`):

- **`include`, `find_in_parent_folders`, `read_terragrunt_config`, `locals`, `inputs`:** avaliados como no
  Terragrunt. Os `inputs` viram as variáveis do módulo.
- **`dependency`:** o Infracost **não lê o state remoto** e **não usa os `mock_outputs`** do arquivo. Ele
  avalia o HCL do workspace de que se depende e usa os outputs calculados dali; o que só se conhece depois do
  apply (ID, ARN) vira um valor fictício. Preço quase nunca depende disso; quando depende (ex.: `count` que
  vem de um output), o recurso pode sumir ou duplicar na estimativa.
- **`run_cmd`, `sops_decrypt_file`, `get_aws_account_id`, `get_aws_caller_identity_*`:** não executam;
  devolvem valor fictício.
- **`tfr:///`** (Terraform Registry público): baixado normalmente.
- **Módulo git privado via SSH:** baixado com a chave de `TERRAFORM_MODULES_SSH_KEY` (carregada no
  ssh-agent). O formato SCP (`git@github.com:Org/repo.git//x?ref=y`) no `terraform { source }` do Terragrunt
  quebra o parser do Infracost (`first path segment in URL cannot contain colon`); o workflow reescreve para
  `git::ssh://git@github.com/Org/repo.git//x?ref=y` (mesmo endereço) só na cópia do CI, nas duas árvores.
- Endereço de rede privada (10.x, 192.168.x) não é baixado; não se aplica ao GitHub.

## Limites: o número não é a fatura

- **Preço de tabela (on-demand, list price) em USD.** Não desconta crédito AWS, Savings Plans, Reserved
  Instances nem desconto negociado.
- **Custo por uso fica em US$ 0** ("Monthly cost depends on usage") sem arquivo de uso: CloudWatch Logs
  (ingestão, armazenamento, Logs Insights), Lambda (requisições e GB-s), transferência de dados, NAT Gateway
  por GB processado, requisições de S3/SQS/API Gateway. A parte fixa (instância, hora de NAT, cluster EKS)
  aparece.
- Recurso que o Infracost não conhece aparece como "not supported" no detalhe; recurso sem preço (IAM, SG)
  como "free".
- Valor que só existe depois do apply não entra (ver `dependency` acima).

### Arquivo de uso por workspace

Um `infracost-usage.yml` dentro do diretório do workspace é usado só naquele workspace
([formato](https://www.infracost.io/docs/features/usage_based_resources/)). Exemplo:

```yaml
version: 0.1
resource_usage:
  aws_cloudwatch_log_group.namespace["proposals"]:
    monthly_data_ingested_gb: 945
    storage_gb: 415
  aws_nat_gateway.this[0]:
    monthly_data_processed_gb: 2000
```

O endereço é o do recurso dentro do workspace (aparece no detalhe do comentário). Base e PR usam cada um o
seu arquivo, então mudar só o arquivo de uso também mostra diferença.

## O que sai para o Infracost

O CLI manda para a Pricing API (`pricing.api.infracost.io`) só os **filtros de preço** de cada recurso
(fornecedor, serviço, região, família, tipo/classe de instância, `usagetype`) e um evento de execução com
**contagens por tipo de recurso** e contexto (SO, versão do CLI, tipo de CI). Não manda o HCL, valores de
variável, nomes de recurso, ARNs, IDs de conta nem segredos. Doc oficial:

- [What data is sent to the Cloud Pricing API?](https://www.infracost.io/docs/faq/#what-data-is-sent-to-the-cloud-pricing-api)
  ("No cloud credentials or secrets are sent to the Cloud Pricing API.")
- [How does Infracost work?](https://www.infracost.io/docs/faq/#how-does-infracost-work)

Conferido também na prática (19/11/2026): rodando o CLI contra uma Pricing API falsa local com 3
workspaces de produção da base-infra, as requisições só tinham filtros como
`{"service": "AmazonRDS", "region": "sa-east-1", "instanceType": "db.t4g.medium", ...}`; nenhuma ocorrência de
nome de recurso, `bull-`, ARN ou ID de conta.

O workflow força `INFRACOST_ENABLE_CLOUD=false`, `INFRACOST_ENABLE_CLOUD_UPLOAD=false` e
`INFRACOST_ENABLE_DASHBOARD=false`. No CLI 0.10 a variável explícita vence a configuração da org no lado do
Infracost, então nada é enviado ao dashboard mesmo que alguém o ligue lá.

**Versão do CLI:** fixa em `0.10.50`. A linha 2.x do CLI (e as actions `infracost/actions/diff` e `scan`)
exige login no Infracost Cloud e grava os resultados lá; por isso não é usada.

## Passo manual: chave e secret

Feito uma vez, por alguém com admin da org:

1. Gerar a chave (gratuita) com uma conta de serviço/e-mail do time. Use o CLI **0.10.x** (o mesmo do
   workflow): o 2.x trocou a chave por login no Infracost Cloud e não tem mais `configure`.
   ```bash
   infracost auth login            # abre o navegador; cria a conta e grava a chave localmente
   infracost configure get api_key # mostra a chave (formato ico-...)
   ```
   (Ou em https://dashboard.infracost.io → Org Settings → API key. Não precisa ligar nada no dashboard.)
2. Criar o secret da org (exige admin da org e o escopo `admin:org` no `gh`). Com `--visibility all`
   (como foi criado em 19/11/2026), ligar o workflow num repo novo não exige passo de admin:
   ```bash
   gh auth refresh -h github.com -s admin:org
   gh secret set INFRACOST_API_KEY --org BullCredTech --visibility all   # cola a chave quando pedir
   ```
3. Nada a configurar no `.github`: o caller repassa o secret.

## Tempo

Medido localmente (19/11/2026, base-infra): um workspace leva 6–20 s (a maior parte é baixar módulo do
registry/git); um PR que afeta 8 workspaces (5 alterados + 3 dependentes) levou ~1min45 para base + PR. No CI,
somando checkout e instalação do CLI, um PR típico fica em 2–4 min; o teto de 40 workspaces fica em
~10–15 min. Sem o filtro, os ~480 workspaces passariam de 1 h.

## Manutenção

- Testes: `infracost/tests/` (pytest), rodados pelo `infracost-selftest.yml` com shellcheck e actionlint.
- Atualizar o CLI: trocar `version:` no workflow (conferir o changelog da linha 0.10) e o SHA da
  `infracost/actions/setup` se mudar.
