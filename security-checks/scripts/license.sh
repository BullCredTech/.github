#!/usr/bin/env bash
# Checagem de licença por subprojeto.
#   license.sh detect <raiz>                       -> node=,python=,go=,flutter= (true|false)
#   license.sh check <raiz> <allowlist> <extras>   -> roda as ferramentas e falha se algo estiver fora
# Extras: SPDX separados por ';' (license.extra_allowed do repo, já validado por config.sh).
# Nada do repo escaneado é executado via eval/source; o npm/yarn rodam com --ignore-scripts.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:?}"; root="${2:?}"

achar() { # $1 = padrão de nome (find -name)
  find "$root" \( -name node_modules -o -name .venv -o -name venv -o -name dist -o -name .git \
    -o -name .terraform -o -name .terragrunt-cache -o -name .org-security -o -name build \) -prune \
    -o -type f -name "$1" -print
}

if [ "$cmd" = "detect" ]; then
  tem() { if [ -n "$(achar "$1" | head -1)" ]; then echo true; else echo false; fi; }
  echo "node=$(tem package.json)"
  py=false; for p in pyproject.toml 'requirements*.txt'; do [ "$(tem "$p")" = true ] && py=true; done
  echo "python=$py"
  echo "go=$(tem go.mod)"
  echo "flutter=$(tem pubspec.yaml)"
  exit 0
fi

[ "$cmd" = "check" ] || { echo "comando inválido: $cmd" >&2; exit 2; }
allowfile="${3:?}"; extras="${4:-}"
allow="$(grep -vE '^[[:space:]]*(#|$)' "$allowfile" | paste -sd ';' -)"
[ -z "$extras" ] || allow="$allow;$extras"
falhou=0; checados=0
resumo() { echo "$1" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# npm e yarn
while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if [ -f "$d/package-lock.json" ]; then
    (cd "$d" && npm ci --ignore-scripts --omit=dev --no-audit --no-fund >/dev/null \
      && npx --yes license-checker-rseidelsohn@5.0.1 --production --onlyAllow "$allow" --excludePrivatePackages --summary) \
      || { resumo "❌ licença: $d (npm)"; falhou=1; }
    checados=$((checados+1))
  elif [ -f "$d/yarn.lock" ]; then
    (cd "$d" && yarn install --frozen-lockfile --ignore-scripts --production >/dev/null \
      && npx --yes license-checker-rseidelsohn@5.0.1 --production --onlyAllow "$allow" --excludePrivatePackages --summary) \
      || { resumo "❌ licença: $d (yarn)"; falhou=1; }
    checados=$((checados+1))
  else
    resumo "⚠️ $d: package.json sem lockfile, licença não verificada"
  fi
done < <(achar package.json)

# Python (venv descartável; o pip não tem equivalente de --ignore-scripts)
while IFS= read -r d; do
  tmpd="$(mktemp -d)"; v="$tmpd/venv"; python3 -m venv "$v"
  (
    # shellcheck disable=SC1091
    . "$v/bin/activate"; cd "$d"
    pip install -q --upgrade pip >/dev/null
    if [ -f uv.lock ]; then
      pip install -q uv && uv export --frozen --no-dev --no-hashes -o "$tmpd/req.txt" >/dev/null && pip install -q -r "$tmpd/req.txt"
    elif ls requirements*.txt >/dev/null 2>&1; then
      for r in requirements*.txt; do
        case "$r" in *dev*|*test*) continue ;; esac
        pip install -q -r "$r"
      done
    else
      pip install -q .
    fi
    pip install -q pip-licenses==5.5.5
    pip-licenses --format=json --from=mixed | python3 "$here/licenses.py" pip --allow "$allow"
  ) || { resumo "❌ licença: $d (python)"; falhou=1; }
  rm -rf "$tmpd"
  checados=$((checados+1))
done < <( { achar pyproject.toml; achar 'requirements*.txt'; } | while IFS= read -r x; do dirname "$x"; done | sort -u)

# Go
while IFS= read -r gm; do
  d="$(dirname "$gm")"
  (cd "$d" && go run github.com/google/go-licenses/v2@v2.0.1 check ./... \
    --allowed_licenses="${allow//;/,}" --ignore "$(go list -m)") \
    || { resumo "❌ licença: $d (go)"; falhou=1; }
  checados=$((checados+1))
done < <(achar go.mod)

# Flutter
while IFS= read -r ps; do
  d="$(dirname "$ps")"
  (flutter pub get --directory "$d" >/dev/null && python3 "$here/licenses.py" dart --allow "$allow" "$d") \
    || { resumo "❌ licença: $d (flutter)"; falhou=1; }
  checados=$((checados+1))
done < <(achar pubspec.yaml)

[ "$checados" -gt 0 ] || resumo "Nenhum subprojeto com dependências: nada a verificar."
exit $falhou
