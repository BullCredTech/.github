#!/usr/bin/env bash
# Lista as supressões INLINE adicionadas pelo PR (linhas novas com gitleaks:allow, nosemgrep ou trivy:ignore).
# Uso: suppressions.sh <base-sha> <head-sha>
# São permitidas, mas ficam visíveis: seção no $GITHUB_STEP_SUMMARY e uma annotation ::warning por linha.
# NUNCA falha o job: qualquer problema vira um aviso e o código de saída é 0.
set -uo pipefail

aviso() { echo "::warning::suppressions.sh: $1"; exit 0; }

base="${1:-}"; head="${2:-}"
for s in "$base" "$head"; do
  [[ "$s" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || aviso "SHA ausente ou inválido, supressões não listadas"
done

# nome de arquivo seguro para o log: sem caracteres de controle, no máximo 200, e com os separadores
# do comando de workflow (% : ,) codificados
seguro() {
  local n
  n="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  n="${n:0:200}"
  n="${n//%/%25}"; n="${n//:/%3A}"; n="${n//,/%2C}"
  printf '%s' "$n"
}

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
git diff --name-only --no-renames -z --end-of-options "$base...$head" > "$tmp" 2>/dev/null || aviso "git diff falhou, supressões não listadas"

achados=()
while IFS= read -r -d '' arq; do
  n=0; cab=1   # cab=1: ainda no cabeçalho do diff (antes do primeiro @@)
  while IFS= read -r linha; do
    case "$linha" in
      @@*)
        cab=0
        # @@ -a,b +c,d @@
        n="${linha#*+}"; n="${n%% *}"; n="${n%%,*}"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        ;;
      *) [ "$cab" -eq 0 ] || continue ;;
    esac
    case "$linha" in
      +*)
        if printf '%s' "$linha" | LC_ALL=C grep -qiE 'gitleaks:allow|nosemgrep|trivy:ignore'; then
          achados+=("$(seguro "$arq")|$n")
        fi
        n=$((n+1))
        ;;
    esac
  done < <(git diff -U0 --no-color --no-renames --end-of-options "$base...$head" -- ":(literal)$arq" 2>/dev/null)
done < "$tmp"

[ "${#achados[@]}" -gt 0 ] || exit 0

{
  echo "### ⚠️ supressões adicionadas neste PR"
  echo
  echo "Supressões inline continuam permitidas, mas precisam de um olhar na revisão:"
  echo
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
for a in "${achados[@]}"; do
  f="${a%|*}"; l="${a##*|}"
  echo "::warning file=$f,line=$l::supressão inline adicionada neste PR (gitleaks:allow, nosemgrep ou trivy:ignore); confira na revisão"
  echo "- \`$f:$l\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
done
exit 0
