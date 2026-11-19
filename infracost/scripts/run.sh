#!/usr/bin/env bash
# Estima a mudança de custo de um PR com o Infracost e monta o comentário.
# Uso: run.sh <árvore do PR> <árvore da base> <arquivo name-status do git diff> <dir de saída>
#
# Variáveis (todas opcionais menos INFRACOST_API_KEY, que quem chama já conferiu):
#   IAC_PATH            raiz do IaC dentro do repo (padrão: .)
#   CONFIG_FILE         config do Infracost versionado no repo; desliga a escolha automática
#   MAX_PROJECTS        teto de workspaces estimados (padrão: 40)
#   INCLUDE_DEPENDENTS  true|false: estima também os dependentes diretos (padrão: true)
#   USAGE_FILE_NAME     nome do arquivo de uso por workspace (padrão: infracost-usage.yml)
#
# Saída em <dir de saída>: comment.md (corpo do comentário), has_projects (true|false).
# Nunca manda nada para o Infracost Cloud: só a Pricing API é chamada.
set -euo pipefail

head_dir="$(cd "${1:?}" && pwd)"
base_dir="$(cd "${2:?}" && pwd)"
changes="${3:?}"
out="${4:?}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IAC_PATH="${IAC_PATH:-.}"
CONFIG_FILE="${CONFIG_FILE:-}"
MAX_PROJECTS="${MAX_PROJECTS:-40}"
INCLUDE_DEPENDENTS="${INCLUDE_DEPENDENTS:-true}"
USAGE_FILE_NAME="${USAGE_FILE_NAME:-infracost-usage.yml}"

caminho_seguro() {
  # Relativo, sem '..', sem caractere estranho: vai para argumento de comando.
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$1" != /* ]] && [[ "/$1/" != */../* ]]
}
caminho_seguro "$IAC_PATH" || { echo "::error::path inválido: $IAC_PATH"; exit 2; }
[[ "$MAX_PROJECTS" =~ ^[0-9]+$ ]] && [ "$MAX_PROJECTS" -gt 0 ] || { echo "::error::max-projects inválido: $MAX_PROJECTS"; exit 2; }
[[ "$USAGE_FILE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::usage-file-name inválido: $USAGE_FILE_NAME"; exit 2; }

# Nada vai para o dashboard do Infracost Cloud, nem se a org ligar isso do lado de lá.
export INFRACOST_ENABLE_CLOUD=false INFRACOST_ENABLE_CLOUD_UPLOAD=false INFRACOST_ENABLE_DASHBOARD=false
export INFRACOST_SKIP_UPDATE_CHECK=true INFRACOST_NO_COLOR=true

# 1. Projetos a estimar.
summary="$out/summary.md"
if [ -n "$CONFIG_FILE" ]; then
  caminho_seguro "$CONFIG_FILE" || { echo "::error::config-file inválido: $CONFIG_FILE"; exit 2; }
  [ -f "$head_dir/$CONFIG_FILE" ] || { echo "::error::config-file não existe no PR: $CONFIG_FILE"; exit 2; }
  cp "$head_dir/$CONFIG_FILE" "$out/head.yml"
  if [ -f "$base_dir/$CONFIG_FILE" ]; then cp "$base_dir/$CONFIG_FILE" "$out/base.yml"; else cp "$out/head.yml" "$out/base.yml"; fi
  # shellcheck disable=SC2016 # crase é markdown, não expansão
  printf 'Projetos do arquivo `%s` (escolha automática desligada).\n' "$CONFIG_FILE" > "$summary"
  printf 'has_projects=true\nhead_count=1\nbase_count=1\n' > "$out/env"
else
  dep_flag=()
  [ "$INCLUDE_DEPENDENTS" = "true" ] || dep_flag=(--no-dependents)
  python3 -I "$scripts/projects.py" --head "$head_dir" --base "$base_dir" --changes "$changes" \
    --root "$IAC_PATH" --max-projects "$MAX_PROJECTS" --usage-file-name "$USAGE_FILE_NAME" ${dep_flag[@]+"${dep_flag[@]}"} \
    --out-head "$out/head.yml" --out-base "$out/base.yml" --out-summary "$summary" --out-env "$out/env"
fi
has_projects="$(sed -n 's/^has_projects=//p' "$out/env")"
head_count="$(sed -n 's/^head_count=//p' "$out/env")"
base_count="$(sed -n 's/^base_count=//p' "$out/env")"
echo "has_projects=$has_projects" > "$out/has_projects"
echo "Workspaces: PR=$head_count base=$base_count"

marker='<!-- bull-infracost -->'
rodape() {
  cat <<'EOF'

---
**Como ler:** preço de tabela da AWS (on-demand, em USD/mês), consultado na Pricing API do Infracost. **Não é o que pagamos:** não desconta crédito, Savings Plans, Reserved Instances nem desconto negociado. Custo **por uso** (CloudWatch Logs, Lambda, transferência de dados, NAT por GB, requisições) aparece como US$ 0 / "depends on usage", a não ser que o workspace tenha um `infracost-usage.yml`. Informativo: não bloqueia o merge. [Como funciona](https://github.com/BullCredTech/.github/blob/main/docs/INFRACOST.md)
EOF
}

if [ "$has_projects" != "true" ]; then
  {
    echo "$marker"
    echo "#### Infracost"
    echo "Nenhum workspace de IaC com efeito de custo nesta versão do PR."
    echo
    cat "$summary"
    rodape
  } > "$out/comment.md"
  exit 0
fi

# 2. Fontes git no formato SCP (git@host:org/repo) quebram o parser do Infracost para o
#    `terraform { source }` do Terragrunt (url.Parse). Reescreve para git::ssh://, que é o
#    mesmo endereço, só na cópia do CI e nas duas árvores (o diff não muda).
for tree in "$head_dir" "$base_dir"; do
  [ -d "$tree/$IAC_PATH" ] || continue
  # shellcheck disable=SC2016 # $1 é do perl
  find "$tree/$IAC_PATH" -name '*.hcl' -type f -not -path '*/.terragrunt-cache/*' -not -path '*/.infracost/*' -print0 |
    xargs -0 -r perl -pi -e 's#"git\@([A-Za-z0-9.-]+):#"git::ssh://git\@$1/#g'
done

# 3. Base, depois diff do PR contra a base. Os nomes dos projetos são iguais nas duas
#    configs (o caminho do workspace), é por eles que o diff casa um com o outro.
if [ "$base_count" != "0" ]; then
  (cd "$base_dir" && infracost breakdown --config-file "$out/base.yml" --format json --out-file "$out/base.json")
else
  printf '{"version":"0.2","currency":"USD","projects":[],"totalHourlyCost":"0","totalMonthlyCost":"0","timeGenerated":"%s","summary":{}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/base.json"
fi

if [ "$head_count" != "0" ]; then
  (cd "$head_dir" && infracost diff --config-file "$out/head.yml" --compare-to "$out/base.json" --format json --out-file "$out/diff.json")
  infracost output --path "$out/diff.json" --format github-comment --show-skipped --out-file "$out/infracost.md"
  # A nota padrão manda configurar uso no Infracost Cloud, que não usamos; o rodapé explica.
  grep -v 'Infracost Cloud settings' "$out/infracost.md" > "$out/infracost.clean.md" || true
else
  # O PR só remove workspaces: o diff precisa de pelo menos um projeto, então o texto é nosso.
  python3 -I - "$out/base.json" > "$out/infracost.clean.md" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
total = float(d.get("totalMonthlyCost") or 0)
print("#### 💰 Infracost")
print(f"O PR só remove workspaces. Custo mensal estimado que deixa de existir: **US$ {total:,.2f}**")
PY
fi

{
  echo "$marker"
  cat "$out/infracost.clean.md"
  echo
  echo "<details><summary>Workspaces estimados neste PR</summary>"
  echo
  cat "$summary"
  echo
  echo "</details>"
  rodape
} > "$out/comment.md"

cp "$out/comment.md" "$out/full.md"

# Limite de 65.536 caracteres do comentário no GitHub.
max=60000
if [ "$(wc -c < "$out/comment.md")" -gt "$max" ]; then
  {
    head -c "$max" "$out/comment.md"
    echo
    echo
    echo "_Comentário cortado no limite do GitHub. O relatório completo está no resumo do job._"
    rodape
  } > "$out/comment.trunc.md"
  mv "$out/comment.trunc.md" "$out/comment.md"
fi
