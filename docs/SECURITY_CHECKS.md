# Checks de segurança obrigatórios (org-security)

Este documento descreve o workflow central de segurança da organização: o que ele verifica, quais arquivos do repo ele lê, como pedir uma exceção e quais riscos continuam. Ele é público; os exemplos usam nomes genéricos.

## 1. O que é e onde vale

Um único workflow, `security-checks-required.yml` (neste repo, `.github`), é injetado por uma regra de organização (ruleset do tipo `workflows`) em **todo PR para a branch padrão e para `production`** dos repositórios cobertos. O repo não precisa ter nenhum arquivo de workflow de segurança: a regra traz o workflow.

Os scripts ficam em `security-checks/` e são testados em PRs deste repo (`security-checks-selftest.yml`). Mudanças no workflow, nos scripts e neste documento passam pelo CODEOWNERS (time `devops`).

O workflow roda nos eventos `pull_request` e `merge_group`, e tem um job de preparação (`org-security / prepare`) e quatro checks:

| Job | Ferramenta | Versão | Bloqueia quando |
|---|---|---|---|
| `org-security / gitleaks` | Gitleaks, binário com checksum conferido | 8.30.1 | acha segredo no histórico do PR (saída com `--redact`) |
| `org-security / semgrep` | Semgrep, imagem fixada por digest, `semgrep ci --config=auto` | 1.162.0 | acha problema novo em relação à branch de destino, sem suprimir erros |
| `org-security / trivy` | Trivy (action fixada por SHA), scan do sistema de arquivos | v0.36.0 da action | acha vulnerabilidade `CRITICAL` ou `HIGH` com correção disponível, ou segredo (scanners padrão do scan de sistema de arquivos) |
| `org-security / license` | `license.sh` e scripts deste repo | n/a | acha dependência de produção com licença fora da lista permitida (seção 7) |

Todas as `uses:` do workflow são fixadas por SHA de commit. Valores dinâmicos entram nos scripts só por variáveis de ambiente.

## 2. PR só de documentação

Se o PR mexe **só em documentação**, Semgrep, Trivy e licença são pulados (com uma linha no resumo do job). **O Gitleaks roda sempre.**

Um arquivo conta como documentação se a extensão (sem diferenciar maiúsculas) é uma destas: `md`, `txt`, `rst`, `adoc`, `png`, `jpg`, `jpeg`, `gif`, `svg`, `webp`, `pdf`, `drawio`, `puml` **e**:

- ele está em `docs/`, ou em um diretório declarado em `docs_paths` (seção 4); ou
- ele termina em `.md`, em qualquer lugar do repo.

**Nunca** contam como documentação, onde quer que estejam:

- arquivos cujo nome contém `requirements` ou `constraints` e termina em `.txt` (são manifestos);
- `.mdx` (pode conter código executável);
- links simbólicos;
- submódulos (gitlinks);
- qualquer arquivo com extensão fora da lista (por exemplo `docs/app.js`, `docs/package.json`, `docs/Dockerfile`).

Também vale como "não é só documentação" um PR sem nenhum arquivo alterado, ou quando o diff não pode ser calculado: na dúvida, escaneia.

## 3. Arquivos lidos da branch de destino, não do PR

Um PR não pode afrouxar os próprios checks. Por isso estes arquivos são lidos **da branch de destino (a base do PR)**; o que está no PR é descartado antes de cada ferramenta rodar (as ferramentas ignoram o do PR e usam o da base; se a base não tem o arquivo, ele é removido; o `.github/security-checks.yml` é lido da base para um diretório temporário, não do PR):

- `.github/security-checks.yml`
- `.gitleaks.toml`
- `.gitleaksignore`
- `.semgrepignore`
- `.semgrep.yml`
- `.trivyignore`
- `.trivyignore.yaml`
- `trivy.yaml`
- `trivy-secret.yaml`

Consequência prática, o padrão **"exceção primeiro"**: para liberar algo, o **primeiro PR** só adiciona ou muda a exceção e é revisado pelo time `devops`; depois do merge, a exceção passa a valer, e o **segundo PR** traz a mudança que dependia dela. Mudar esses arquivos e o código no mesmo PR não funciona: o PR é avaliado com as regras da base.

## 4. O arquivo `.github/security-checks.yml`

Opcional. Sem ele, valem os padrões da organização. Exemplo completo:

```yaml
version: 1
docs_paths:
  - handbook/**
  - notes/**
license:
  extra_allowed:
    - MPL-2.0
    - CC-BY-4.0
semgrep:
  extra_configs:
    - p/python
skip:
  - check: trivy
    reason: "Repositório só de documentação, sem dependências nem imagens"
```

Regras de validação (arquivo inválido reprova os checks, com a causa na anotação do job `prepare`):

- o arquivo não pode ser vazio, nem link simbólico, nem YAML inválido, e a raiz precisa ser um mapa;
- `version` precisa ser o **inteiro** `1` (não a string `"1"`);
- chaves desconhecidas (no topo, em `license`, em `semgrep` e em cada item de `skip`) são recusadas;
- nenhuma string ou chave pode conter caracteres de controle (quebras de linha, por exemplo);
- `docs_paths`: lista de textos, cada um no formato `diretorio/**`, com um ou mais segmentos literais (`A-Z a-z 0-9 . _ -`) seguidos de `**`; sem `/` inicial e sem segmento `.` ou `..`. Padrões amplos como `**`, `*`, `**/*`, `*.js` ou `handbook/*` são recusados (o `.md` em qualquer lugar já é regra embutida);
- `license.extra_allowed`: lista de identificadores SPDX (`A-Z a-z 0-9 . + -`, ou `LicenseRef-...`); sem `*`, vírgula, ponto e vírgula, espaço ou texto vazio;
- `semgrep.extra_configs`: só regras do registro, no formato `p/...` ou `r/...`, com até 100 caracteres, sem `..` e sem barra no final (nada de opções ou caminhos locais);
- `skip`: lista de itens com `check` (`semgrep`, `trivy` ou `license`) e `reason` com **pelo menos 10 caracteres que não sejam espaço**. **`gitleaks` não pode ser desligado.** Entradas repetidas são unificadas.

Um `skip` desliga o check inteiro naquele repo; prefira `license.extra_allowed` (uma licença específica) ou `docs_paths` quando bastar.

## 5. Supressões inline

Supressões no próprio código continuam permitidas: `gitleaks:allow`, `nosemgrep` e `trivy:ignore` (sem diferenciar maiúsculas). Para ficarem **visíveis na revisão**, os jobs `gitleaks` e `semgrep` listam as linhas **adicionadas pelo PR** que contêm essas marcas, com uma seção "supressões adicionadas neste PR" no resumo do job e uma anotação de aviso por linha. Isso **nunca reprova** o job: o controle real é a revisão humana de quem aprova o PR.

## 6. Como pedir uma exceção

1. Abra um PR no repo afetado que altere **só** o arquivo de exceção (`.github/security-checks.yml`, `.gitleaksignore`, `.trivyignore`...), com o motivo escrito.
2. O time `devops` revisa (o arquivo é protegido por CODEOWNERS).
3. Depois do merge, a exceção vale. Abra então o PR com a mudança que dependia dela.

Para uma exceção válida para toda a organização (por exemplo, uma licença permissiva que deveria estar na lista padrão), o pedido é um PR neste repo mudando `security-checks/license-allowlist.txt`.

## 7. Verificação de licenças

Lista permitida por padrão (SPDX): `MIT`, `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `0BSD`, `CC0-1.0`, `Unlicense`, `BlueOak-1.0.0`, `Python-2.0`, `MIT-0`, `MIT-CMU`, `Zlib`, `PSF-2.0`. Licenças adicionais por repo, como a `MPL-2.0` (copyleft por arquivo), entram em `license.extra_allowed`.

Em licenças compostas, **todo termo** (`AND` e `OR`) precisa estar permitido: é conservador de propósito. Cada subprojeto do repo é verificado (monorepos têm vários); `node_modules`, `.git`, ambientes virtuais e caches de Terraform são ignorados, mas `build/` e `dist/` **não**.

O job **não executa código do repo**: não roda `npm`/`yarn` com scripts, não faz `pip install .`, não compila nada a partir de código-fonte de pacote. Antes de cada avaliação, confere que o diretório central do verificador está no SHA esperado e sem alterações.

### npm e yarn (v1)

- Precisa de `package-lock.json` ou `yarn.lock`. Um `package.json` que declara dependências **sem lockfile reprova** ("sem lockfile: dependências não verificáveis"). Sem dependências, passa.
- Instala só dependências de produção, **sem scripts** (`npm ci --ignore-scripts --omit=dev`, ou o equivalente do yarn v1) e percorre **todo o `node_modules`, em qualquer profundidade**, incluindo as versões aninhadas que não subiram.
- Configurações do repo que fariam o gerenciador executar um programa do próprio repo são neutralizadas: `yarn-path` do `.yarnrc` (`YARN_IGNORE_PATH=1`) e `git=` do `.npmrc` (`--git=git`).
- Workspaces: a lista vem do próprio `npm query` (ou `yarn workspaces info`); cada workspace precisa estar dentro do repo e instalado em `node_modules`. São "do próprio repo" só a raiz e esses workspaces.
- Todo o resto é verificado como terceiro, **inclusive pacotes `private: true`, dependências `file:` e links simbólicos** (por exemplo para uma pasta `vendor/` do próprio repo). Cada pacote é identificado pelo caminho, não por nome e versão: duas cópias da mesma versão são duas verificações.
- **Sem licença declarada** no `package.json`: usa o arquivo `LICENSE`, `LICENSE.md`, `LICENSE.txt` ou `COPYING` do pacote, se for reconhecível; se não, **reprova**, com a mensagem "sem licença declarada: nome@versão (caminho) — se for aceitável, peça exceção". Um valor de licença presente mas estranho (número, lista, objeto sem `type`) também reprova.
- Não suportado: `pnpm` (`pnpm-lock.yaml` reprova com "pnpm não suportado") e yarn berry.

### Python

- Só **wheels** (`pip install --only-binary=:all:`). Se alguma dependência não tem wheel, o check reprova com "dependência sem wheel ... peça exceção"; não há fallback para compilar a partir de código-fonte.
- **Limitação conhecida:** hoje a única exceção para uma dependência sem wheel é `skip: license` no `.github/security-checks.yml`, que desliga a verificação de licença do repo inteiro (com `reason` escrito, revisado pelo `devops`). Não existe exceção por pacote; se isso virar um problema recorrente, peça ao `devops` para considerar uma exceção por pacote.
- O inventário de licenças é feito lendo só os metadados (`.dist-info`) do ambiente, com o interpretador do sistema em modo isolado (`-I -S`): nada instalado é importado nem executado, e arquivos `.pth` de wheels não são processados durante a avaliação. Os requisitos são instalados numa **única instalação** (as instalações das próprias ferramentas, `pip` e `uv`, acontecem antes dela); instalar é a etapa que pode rodar código de terceiros, e a integridade do verificador é conferida antes e depois.
- Arquivos `requirements*.txt` (e `requirements/*.txt`) de produção são lidos; arquivos de desenvolvimento e teste são pulados (`requirements-dev.txt`, `requirements-test*.txt`, `dev-requirements*.txt`, e `dev.txt`, `test.txt`, `lint.txt`, `docs.txt` dentro de `requirements/`). Nomes como `requirements-devops.txt` **são** instalados.
- Cada linha dos requirements passa por uma **lista de permissão**: especificadores de versão (`pacote`, `pacote[extra]==1.0`, `Django>=4.2,<5`, marcadores de ambiente após `;` e `--hash=...`) e inclusões `-r`/`-c` para arquivos dentro do mesmo projeto. Qualquer outra coisa reprova mostrando a linha: opções (`-e`, `--index-url`, `--extra-index-url`, `--find-links`, `--pre`, `--no-binary`...), URLs e referências diretas (`@`, `git+`, `file:`), caminhos locais e arquivos binários locais.
- `pyproject.toml`: `[project].dependencies` e `[tool.poetry.dependencies]` (sem `python`, com as restrições do poetry convertidas) são extraídos **sem executar o projeto**. Suportado também `uv.lock` (via `uv export`, sem emitir o próprio projeto).
- Não suportado, reprova: dependências dinâmicas (`dynamic = ["dependencies"]`), projetos só com `setup.py`/`setup.cfg` e `Pipfile` (pipenv). Declare as dependências em requirements ou peça exceção.
- Licença ausente (`UNKNOWN`) em Python **só gera aviso**.

### Go

`go-licenses` com `CGO_ENABLED=0`, `GOWORK=off` e `GOTOOLCHAIN=local`, uma vez por `go.mod`; o próprio módulo é ignorado.

### Flutter / Dart

`flutter pub get` e leitura do `LICENSE` de cada pacote resolvido (o pub não declara licença em nenhum outro lugar). Licença não reconhecida (`UNKNOWN`) só gera aviso.

## 8. Riscos que continuam

- O job de licença ainda **instala pacotes de terceiros** no runner (sem executar scripts de instalação, mas wheels podem carregar arquivos que são colocados no ambiente) e roda ferramentas que resolvem dependências. A mitigação é: só wheels, sem scripts, runner descartável, credenciais não persistidas e verificação de integridade do verificador antes de avaliar.
- Supressões inline são permitidas e só **visíveis**, não bloqueadas: o controle real é a revisão do PR.
- Os checks dependem do registro de pacotes e dos downloads das ferramentas (seção 9).
- A lista de licenças é um insumo técnico, não uma decisão jurídica: licenças com restrições devem ser avaliadas caso a caso e entrar por exceção.

## 9. Se o download de uma ferramenta falhar

Instalações de ferramentas (Gitleaks, Trivy, imagens, pacotes) podem falhar por indisponibilidade momentânea. Rode o job de novo. Se persistir, avise o time `devops`; não desligue o check no PR.
