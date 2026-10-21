#!/usr/bin/env bash
# Checagem de licença por subprojeto.
#   license.sh detect <raiz>                       -> node=,python=,go=,flutter= (true|false)
#   license.sh check <raiz> <allowlist> <extras>   -> roda as ferramentas e falha se algo estiver fora
#   license.sh workspaces <dir> | pkgids | union <dir> -> auxiliares (diretórios dos workspaces; name@version do repo)
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

if [ "$cmd" = "workspaces" ] || [ "$cmd" = "pkgids" ] || [ "$cmd" = "union" ]; then
  case "$cmd" in
    workspaces) node "$here/workspaces.js" dirs "$root" ;;
    pkgids) node "$here/workspaces.js" ids "$root" ;;
    union) node "$here/workspaces.js" union "$root" ;;
  esac
  exit 0
fi

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

# npm e yarn. Raiz com workspaces: instala uma vez e checa a raiz e cada workspace.
# Pacotes do próprio repo (name@version do root e dos workspaces) ficam fora da checagem.
lc() { # $1 = diretório inicial, $2 = ids dos pacotes do próprio repo
  local args=(--start "$1" --production --onlyAllow "$allow" --excludePrivatePackages --out /dev/null)
  [ -z "$2" ] || args+=(--excludePackages "$2")
  npx --yes license-checker-rseidelsohn@5.0.1 "${args[@]}"
}
node_checar() { # $1 = dir, $2 = rótulo (npm|yarn)
  local d="$1" ids wsdirs rc=0
  ids="$(node "$here/workspaces.js" ids "$d")"
  wsdirs="$(node "$here/workspaces.js" dirs "$d")"
  NWS=0
  [ -z "$wsdirs" ] || NWS=$(printf '%s\n' "$wsdirs" | wc -l | tr -d ' ')
  if [ "$2" = npm ]; then
    (cd "$d" && npm ci --ignore-scripts --omit=dev --no-audit --no-fund >/dev/null) || return 1
  else
    (cd "$d" && yarn install --frozen-lockfile --ignore-scripts --production >/dev/null) || return 1
  fi
  if [ "$NWS" -eq 0 ]; then
    (cd "$d" && lc "$d" "$ids") || return 1
    return 0
  fi
  # Workspaces: o license-checker só lê as deps do package.json inicial. Troca-se o da raiz, só durante
  # a checagem, por um sintético com as deps de produção de todos os workspaces (restaurado sempre).
  local bak
  bak="$(mktemp)"
  cp "$d/package.json" "$bak"
  # gera o sintético ANTES de sobrescrever (o redirecionamento direto truncaria o arquivo que o node lê)
  node "$here/workspaces.js" union "$d" > "$bak.union"
  cp "$bak.union" "$d/package.json"; rm -f "$bak.union"
  (cd "$d" && lc "$d" "$ids") || rc=1
  cp "$bak" "$d/package.json"; rm -f "$bak"
  return $rc
}

# Diretórios cobertos por um workspace root (com lockfile): não precisam de lockfile próprio.
cobertos=""
while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if [ -f "$d/package-lock.json" ] || [ -f "$d/yarn.lock" ]; then
    cobertos="$cobertos
$(node "$here/workspaces.js" dirs "$d")"
  fi
done < <(achar package.json)

while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if printf '%s\n' "$cobertos" | grep -Fxq -- "$d"; then continue; fi
  if [ -f "$d/package-lock.json" ]; then rot=npm
  elif [ -f "$d/yarn.lock" ]; then rot=yarn
  else
    resumo "⚠️ $d: package.json sem lockfile, licença não verificada"
    continue
  fi
  NWS=0
  if node_checar "$d" "$rot"; then
    resumo "✅ licença: $d ($rot, $NWS workspaces)"
  else
    resumo "❌ licença: $d ($rot)"; falhou=1
  fi
  checados=$((checados+1))
done < <(achar package.json)

# Python (venv descartável; o pip não tem equivalente de --ignore-scripts).
# Dentro de `( ... ) || ...` o set -e não vale, então cada passo tem `|| return 1` explícito:
# sem isso, uma instalação que falha viraria "0 pacotes, tudo ok".
py_checar() { # $1 = dir do projeto, $2 = dir temporário (já criado)
  local d="$1" tmpd="$2" r
  python3 -m venv "$tmpd/venv" || return 1
  # shellcheck disable=SC1091
  . "$tmpd/venv/bin/activate"
  cd "$d" || return 1
  pip install -q --upgrade pip >/dev/null || return 1
  if [ -f uv.lock ]; then
    pip install -q uv || return 1
    uv export --frozen --no-dev --no-hashes -o "$tmpd/req.txt" >/dev/null || return 1
    pip install -q -r "$tmpd/req.txt" || return 1
  elif ls requirements*.txt >/dev/null 2>&1; then
    for r in requirements*.txt; do
      case "$r" in *dev*|*test*) continue ;; esac
      pip install -q -r "$r" || return 1
    done
  else
    pip install -q . || return 1
  fi
  pip install -q pip-licenses==5.5.5 || return 1
  pip-licenses --format=json --from=mixed | python3 "$here/licenses.py" pip --allow "$allow"
}

while IFS= read -r d; do
  tmpd="$(mktemp -d)"
  if (py_checar "$d" "$tmpd"); then
    resumo "✅ licença: $d (python)"
  else
    resumo "❌ licença: $d (python)"; falhou=1
  fi
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
