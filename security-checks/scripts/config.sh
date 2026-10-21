#!/usr/bin/env bash
# Lê e valida o .github/security-checks.yml do repo do PR.
# Uso: config.sh <raiz-do-repo>
# Saída (stdout): linhas chave=valor para o $GITHUB_OUTPUT.
# Código de saída 2 = arquivo inválido (os checks que leem o arquivo reprovam).
set -euo pipefail

root="${1:?uso: config.sh <raiz-do-repo>}"
f="$root/.github/security-checks.yml"
erro() { echo "::error file=.github/security-checks.yml::$1" >&2; echo "erro: $1"; exit 2; }

if [ ! -f "$f" ]; then
  printf '%s\n' config_present=false docs_paths= license_extra= semgrep_extra= skip=
  exit 0
fi

yq -e '.' "$f" >/dev/null 2>&1 || erro "YAML inválido"
[ "$(yq '.version // ""' "$f")" = "1" ] || erro "version precisa ser 1"

desconhecidas=$(yq '(keys - ["version","docs_paths","license","semgrep","skip"]) | join(",")' "$f")
[ -z "$desconhecidas" ] || erro "chave desconhecida: $desconhecidas"
lic_desc=$(yq '((.license // {}) | keys - ["extra_allowed"]) | join(",")' "$f")
[ -z "$lic_desc" ] || erro "chave desconhecida em license: $lic_desc"
sg_desc=$(yq '((.semgrep // {}) | keys - ["extra_configs"]) | join(",")' "$f")
[ -z "$sg_desc" ] || erro "chave desconhecida em semgrep: $sg_desc"

while IFS= read -r c; do
  [ -z "$c" ] && continue
  [[ "$c" =~ ^[pr]/[A-Za-z0-9._/-]+$ ]] || erro "semgrep.extra_configs aceita só regras do registro (p/... ou r/...): '$c'"
done < <(yq '(.semgrep.extra_configs // [])[]' "$f")

n=$(yq '(.skip // []) | length' "$f")
skips=()
for ((i = 0; i < n; i++)); do
  check=$(yq ".skip[$i].check // \"\"" "$f")
  reason=$(yq ".skip[$i].reason // \"\"" "$f")
  case "$check" in
    semgrep|trivy|license) ;;
    gitleaks) erro "skip do gitleaks não é permitido" ;;
    *) erro "skip com check inválido: '$check'" ;;
  esac
  [ -n "$reason" ] || erro "skip de $check sem reason"
  skips+=("$check")
done

echo "config_present=true"
echo "docs_paths=$(yq '(.docs_paths // []) | join(",")' "$f")"
echo "license_extra=$(yq '(.license.extra_allowed // []) | join(";")' "$f")"
echo "semgrep_extra=$(yq '(.semgrep.extra_configs // []) | map("--config " + .) | join(" ")' "$f")"
echo "skip=$(IFS=,; echo "${skips[*]:-}")"
