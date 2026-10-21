#!/usr/bin/env bash
# Diz se o PR mexe só em documentação.
# Uso: changes.sh <raiz-do-repo> <base-sha> <head-sha> <padrões-extras separados por vírgula>
# Saída: docs_only=true|false. Sem arquivo mudado -> false (na dúvida, escaneia).
# Falha (código != 0) se o git diff falhar: nunca imprime true nesse caso.
set -euo pipefail

root="${1:?}"; base="${2:?}"; head="${3:?}"; extra="${4:-}"
padroes=("docs/**" "**/*.md")
if [ -n "$extra" ]; then
  IFS=',' read -r -a mais <<< "$extra"
  for p in "${mais[@]}"; do
    [ -n "$p" ] && padroes+=("$p")
  done
fi

# Em [[ == ]], '*' também casa '/'; então '**' equivale a '*'.
# Um '**/' inicial também pode casar zero diretórios (ex.: README.md na raiz).
casa_docs() {
  local arq="$1" p q
  for p in "${padroes[@]}"; do
    q="${p//\*\*/*}"
    # shellcheck disable=SC2053 # o padrão precisa ficar sem aspas para casar glob
    [[ "$arq" == $q ]] && return 0
    if [[ "$p" == '**/'* ]]; then
      q="${p#'**/'}"; q="${q//\*\*/*}"
      # shellcheck disable=SC2053
      [[ "$arq" == $q ]] && return 0
    fi
  done
  return 1
}

# Arquivo temporário com nomes separados por NUL (o bash não guarda NUL em variável).
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
git -C "$root" diff --name-only --no-renames -z "$base...$head" > "$tmp"

visto=false
while IFS= read -r -d '' a; do
  visto=true
  casa_docs "$a" || { echo "docs_only=false"; exit 0; }
done < "$tmp"

if [ "$visto" = false ]; then echo "docs_only=false"; exit 0; fi
echo "docs_only=true"
