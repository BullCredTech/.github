#!/usr/bin/env bash
# Lê e valida o .github/security-checks.yml do repo do PR.
# Uso: config.sh <raiz-do-repo>   (qualquer diretório que contenha .github/security-checks.yml)
# Saída (stdout): linhas chave=valor para o $GITHUB_OUTPUT. Só sai em stdout se o arquivo for válido.
# Código de saída 2 = arquivo inválido; a mensagem vai só para stderr.
set -euo pipefail

root="${1:?uso: config.sh <raiz-do-repo>}"
f="$root/.github/security-checks.yml"

erro() {
  local m="${1//[[:cntrl:]]/ }"
  echo "::error file=.github/security-checks.yml::${m:0:120}" >&2
  exit 2
}

# q <expressão yq>: avalia no arquivo; falha do yq vira erro (nunca valor vazio silencioso)
q() { yq "$1" "$f" 2>/dev/null || erro "não foi possível ler o YAML (${2:-estrutura inválida})"; }

if [ -L "$f" ]; then erro "o arquivo não pode ser symlink"; fi

if [ ! -e "$f" ]; then
  printf '%s\n' config_present=false docs_paths= license_extra= semgrep_extra= skip=
  exit 0
fi

[ -s "$f" ] || erro "arquivo vazio (remova-o ou use version: 1)"
yq -e '.' "$f" >/dev/null 2>&1 || erro "YAML inválido"

# Caracteres de controle em qualquer string ou chave
n_ctl=$(q '[.. | select(tag == "!!str") | select(test("[[:cntrl:]]"))] | length' "strings")
[ "$n_ctl" = "0" ] || erro "caracteres de controle não permitidos"
n_ctl=$(q '[.. | select(tag == "!!map") | keys | .[] | select(test("[[:cntrl:]]"))] | length' "chaves")
[ "$n_ctl" = "0" ] || erro "caracteres de controle não permitidos"

# Tipos
[ "$(q 'tag')" = "!!map" ] || erro "a raiz precisa ser um mapa"
[ "$(q '.version | tag')" = "!!int" ] && [ "$(q '.version')" = "1" ] || erro "version precisa ser o inteiro 1"

for p in license semgrep; do
  [ "$(q ".$p == null or (.$p | tag) == \"!!map\"")" = "true" ] || erro "$p precisa ser um mapa"
done
for p in .docs_paths .license.extra_allowed .semgrep.extra_configs; do
  [ "$(q "($p == null) or ((($p | tag) == \"!!seq\") and ([${p}[] | select(tag != \"!!str\")] | length == 0))")" = "true" ] \
    || erro "${p#.} precisa ser uma lista de textos"
done
[ "$(q '.skip == null or ((.skip | tag) == "!!seq" and ([.skip[] | select(tag != "!!map")] | length == 0))')" = "true" ] \
  || erro "skip precisa ser uma lista de itens"
[ "$(q '[(.skip // [])[] | ((keys - ["check","reason"]) | length)] | map(select(. > 0)) | length')" = "0" ] \
  || erro "chave desconhecida em skip"
[ "$(q '[(.skip // [])[] | (.check, .reason) | select(. != null and tag != "!!str")] | length')" = "0" ] \
  || erro "skip: check e reason precisam ser texto"

desconhecidas=$(q '(keys - ["version","docs_paths","license","semgrep","skip"]) | join(",")')
[ -z "$desconhecidas" ] || erro "chave desconhecida: $desconhecidas"
lic_desc=$(q '((.license // {}) | keys - ["extra_allowed"]) | join(",")')
[ -z "$lic_desc" ] || erro "chave desconhecida em license: $lic_desc"
sg_desc=$(q '((.semgrep // {}) | keys - ["extra_configs"]) | join(",")')
[ -z "$sg_desc" ] || erro "chave desconhecida em semgrep: $sg_desc"

# docs_paths: só "dir/**" (segmentos literais + **). O ".md" em qualquer lugar já é regra embutida.
while IFS= read -r c; do
  [[ "$c" =~ ^([A-Za-z0-9._-]+/)+\*\*$ ]] || erro "docs_paths: use só o formato dir/** : '$c'"
  [[ "$c" != /* && ! "$c" =~ (^|/)\.+(/|$) ]] || erro "docs_paths: sem / inicial nem segmentos '.' ou '..': '$c'"
done < <(q '(.docs_paths // [])[]')

# license.extra_allowed: ids SPDX
while IFS= read -r c; do
  [[ "$c" =~ ^[A-Za-z0-9.+-]+$ ]] || erro "license.extra_allowed: id inválido: '$c'"
done < <(q '(.license.extra_allowed // [])[]')

# semgrep.extra_configs: só regras do registro
while IFS= read -r c; do
  [[ "$c" =~ ^[pr]/[A-Za-z0-9._/-]+$ ]] || erro "semgrep.extra_configs aceita só regras do registro (p/... ou r/...): '$c'"
  [[ "$c" != *..* && "$c" != */ && ${#c} -le 100 ]] || erro "semgrep.extra_configs: valor inválido: '$c'"
done < <(q '(.semgrep.extra_configs // [])[]')

n=$(q '(.skip // []) | length')
skips=()
for ((i = 0; i < n; i++)); do
  check=$(q ".skip[$i].check // \"\"")
  reason=$(q ".skip[$i].reason // \"\"")
  case "$check" in
    semgrep|trivy|license) ;;
    gitleaks) erro "skip do gitleaks não é permitido" ;;
    *) erro "skip com check inválido: '$check'" ;;
  esac
  compact="${reason//[[:space:]]/}"
  [ "${#compact}" -ge 10 ] || erro "skip de $check: reason precisa ter ao menos 10 caracteres"
  skips+=("$check")
done

docs_paths=$(q '(.docs_paths // []) | join(",")')
license_extra=$(q '(.license.extra_allowed // []) | join(";")')
semgrep_extra=$(q '(.semgrep.extra_configs // []) | map("--config " + .) | join(" ")')
skip_out=""
if [ "${#skips[@]}" -gt 0 ]; then
  skip_out=$(printf '%s\n' "${skips[@]}" | sort -u | paste -sd, -)
fi

echo "config_present=true"
echo "docs_paths=$docs_paths"
echo "license_extra=$license_extra"
echo "semgrep_extra=$semgrep_extra"
echo "skip=$skip_out"
