#!/usr/bin/env bash
# Diz se o PR mexe só em documentação.
# Uso: changes.sh <raiz-do-repo> <base-sha> <head-sha> <diretórios extras, ex.: "handbook/**", separados por vírgula>
# Saída: docs_only=true|false. Sem arquivo mudado -> false (na dúvida, escaneia).
# Falha (código != 0) se os SHAs forem inválidos ou o git diff falhar: nunca imprime true nesse caso.
#
# Um arquivo só é documentação se a extensão está na lista abaixo (sem diferenciar maiúsculas)
# E (está em docs/, ou num diretório extra, ou termina em .md em qualquer lugar).
# Nunca é documentação: requirements*.txt, constraints*.txt, gitlinks (submódulos), .mdx.
set -euo pipefail

root="${1:?}"; base="${2:?}"; head="${3:?}"; extra="${4:-}"

for s in "$base" "$head"; do
  [[ "$s" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { echo "::error::SHA inválido" >&2; exit 2; }
done

padroes=("docs/**")
if [ -n "$extra" ]; then
  IFS=',' read -r -a mais <<< "$extra"
  for p in "${mais[@]}"; do
    [ -n "$p" ] && padroes+=("$p")
  done
fi

minusculo() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Em [[ == ]], '*' também casa '/'; então '**' equivale a '*'.
em_dir_de_docs() {
  local arq="$1" p q pre='**/'
  for p in "${padroes[@]}"; do
    q="${p//\*\*/*}"
    # shellcheck disable=SC2053 # o padrão precisa ficar sem aspas para casar glob
    [[ "$arq" == $q ]] && return 0
    if [[ "$p" == "$pre"* ]]; then
      q="${p#"$pre"}"; q="${q//\*\*/*}"
      # shellcheck disable=SC2053
      [[ "$arq" == $q ]] && return 0
    fi
  done
  return 1
}

casa_docs() {
  local arq="$1" nome ext
  nome=$(minusculo "${arq##*/}")
  case "$nome" in
    requirements*.txt|constraints*.txt) return 1 ;;
  esac
  [[ "$nome" == *.* ]] || return 1
  ext="${nome##*.}"
  case "$ext" in
    md|txt|rst|adoc|png|jpg|jpeg|gif|svg|webp|pdf|drawio|puml) ;;
    *) return 1 ;;
  esac
  [ "$ext" = md ] && return 0
  em_dir_de_docs "$arq"
}

# Arquivo temporário (o bash não guarda NUL em variável). Formato do --raw -z:
# ":modo-antigo modo-novo sha-antigo sha-novo status" NUL caminho NUL
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
git -C "$root" diff --raw --no-renames -z --end-of-options "$base...$head" > "$tmp"

visto=false
while IFS= read -r -d '' meta && IFS= read -r -d '' a; do
  visto=true
  read -r om nm _ <<< "${meta#:}"
  if [ "$om" = 160000 ] || [ "$nm" = 160000 ]; then echo "docs_only=false"; exit 0; fi
  casa_docs "$a" || { echo "docs_only=false"; exit 0; }
done < "$tmp"

if [ "$visto" = false ]; then echo "docs_only=false"; exit 0; fi
echo "docs_only=true"
