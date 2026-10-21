#!/usr/bin/env bash
# Checagem de licença por subprojeto. FALHA FECHADO: nunca fica verde sem ter inventariado o que o repo declara.
#   license.sh detect <raiz>                       -> node=,python=,go=,flutter= (true|false)
#   license.sh check <raiz> <allowlist> <extras>   -> roda as ferramentas e falha se algo estiver fora
#   license.sh pyfiltro <nome-de-arquivo>          -> skip|install (arquivos requirements de dev/test são pulados)
# Extras: SPDX separados por ';' (license.extra_allowed do repo, já validado por config.sh).
# Nada do repo escaneado é executado via eval/source; o npm/yarn rodam com --ignore-scripts.
# Importante: dentro de `if f` / `f || ...` o `set -e` NÃO vale, então toda função usada assim
# tem `|| return 1` explícito depois de cada comando que importa.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:?}"

minusculo() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Arquivos requirements de desenvolvimento/teste (não vão para produção), com fronteira de palavra:
# requirements-dev.txt sim, requirements-devops.txt não.
py_filtro() {
  local n
  n="$(minusculo "$1")"
  if [[ "$n" =~ ^requirements[-_.](dev|test|lint|docs)([-_.].*)?\.txt$ ]] \
    || [[ "$n" =~ ^(dev|test)-requirements([-_.].*)?\.txt$ ]]; then
    echo skip
  else
    echo install
  fi
}

if [ "$cmd" = "pyfiltro" ]; then py_filtro "${2:?}"; exit 0; fi

root="${2:?}"

# Só node_modules, .git, venvs e caches de terraform ficam de fora (build/ e dist/ NÃO: não dá para
# esconder um subprojeto ali).
achar() { # $1 = padrão de nome (find -name)
  find "$root" \( -name node_modules -o -name .venv -o -name venv -o -name .git \
    -o -name .terraform -o -name .terragrunt-cache -o -name .org-security \) -prune \
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
msg() { echo "$1" >&2; echo "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# $1 está dentro de $2 (resolvendo symlinks e ..)?
dentro_de() {
  local r p
  r="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  p="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  case "$p/" in "$r"/*) return 0 ;; esac
  return 1
}

# ---------------- npm e yarn ----------------
lc() { # $1 = diretório inicial, $2 = ids dos pacotes do próprio repo
  local args=(--start "$1" --production --onlyAllow "$allow" --excludePrivatePackages --out /dev/null)
  [ -z "$2" ] || args+=(--excludePackages "$2")
  npx --yes license-checker-rseidelsohn@5.0.1 "${args[@]}"
}

# Checagem com o package.json da raiz trocado por um sintético (deps de produção de todos os workspaces).
# Um node_modules em symlink não serve: o license-checker só percorre as deps transitivas quando o
# package.json está ao lado do node_modules de verdade. O original é restaurado SEMPRE (EXIT/INT/TERM).
lc_union() { # $1 = raiz, $2 = ids, $3... = diretórios dos workspaces
  local d="$1" ids="$2"; shift 2
  (
    bak="$(mktemp)" || exit 1
    cp "$d/package.json" "$bak" || exit 1
    # shellcheck disable=SC2329 # chamada pelo trap
    restaurar() { cp "$bak" "$d/package.json"; rm -f "$bak" "$bak.union"; }
    trap restaurar EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    node "$here/workspaces.js" union "$d" "$@" > "$bak.union" || exit 1
    cp "$bak.union" "$d/package.json" || exit 1
    cd "$d" || exit 1
    lc "$d" "$ids"
  )
}

COBERTOS=""   # diretórios de workspace que o npm/yarn reportou (cobertos pela raiz)
NWS=0

node_checar() { # $1 = dir, $2 = rótulo (npm|yarn)
  local d="$1" rot="$2" decl wsdirs="" ids w
  local -a arr=()
  decl="$(node "$here/workspaces.js" declared "$d")" || return 1
  if [ "$rot" = npm ]; then
    (cd "$d" && npm ci --ignore-scripts --omit=dev --no-audit --no-fund >/dev/null) || return 1
  else
    (cd "$d" && yarn install --frozen-lockfile --ignore-scripts --production >/dev/null) || return 1
  fi
  NWS=0
  if [ "$decl" = true ]; then
    if [ "$rot" = npm ]; then
      wsdirs="$(cd "$d" && npm query .workspace | node "$here/workspaces.js" npmdirs "$d")" \
        || { msg "workspaces: não consegui listar os workspaces de $d com 'npm query'"; return 1; }
    else
      wsdirs="$(cd "$d" && yarn workspaces info --json | node "$here/workspaces.js" yarndirs "$d")" \
        || { msg "workspaces: não consegui listar os workspaces de $d com 'yarn workspaces info'"; return 1; }
    fi
    [ -n "$wsdirs" ] || { msg "workspaces: declarados em $d, mas o gerenciador não listou nenhum"; return 1; }
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      dentro_de "$w" "$d" || { msg "workspaces: $w está fora da raiz $d"; return 1; }
      arr+=("$w")
    done <<< "$wsdirs"
    NWS=${#arr[@]}
    for w in "${arr[@]}"; do COBERTOS="$COBERTOS
$w"; done
  fi
  ids="$(node "$here/workspaces.js" ids "$d" ${arr[@]+"${arr[@]}"})" || return 1
  if [ "$NWS" -eq 0 ]; then
    (cd "$d" && lc "$d" "$ids") || return 1
  else
    lc_union "$d" "$ids" "${arr[@]}" || return 1
  fi
}

registrar_node() { # $1 = dir, $2 = rótulo
  if node_checar "$1" "$2"; then
    resumo "✅ licença: $1 ($2, $NWS workspaces)"
  else
    resumo "❌ licença: $1 ($2)"; falhou=1
  fi
  checados=$((checados+1))
}

FEITOS=""
# 1ª passada: raízes com lockfile. Elas dizem (via npm/yarn) quais diretórios são workspaces.
while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if [ -f "$d/package-lock.json" ]; then rot=npm; elif [ -f "$d/yarn.lock" ]; then rot=yarn; else continue; fi
  FEITOS="$FEITOS
$d"
  registrar_node "$d" "$rot"
done < <(achar package.json)

# 2ª passada: o que sobrou. Workspace reportado pela raiz está coberto; o resto sem lockfile avisa.
while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if printf '%s\n' "$FEITOS" | grep -Fxq -- "$d"; then continue; fi
  if printf '%s\n' "$COBERTOS" | grep -Fxq -- "$d"; then continue; fi
  resumo "⚠️ $d: package.json sem lockfile, licença não verificada"
done < <(achar package.json)

# ---------------- Python ----------------
# Linhas de requirements que o gate não aceita (instalação fora do PyPI/da config do runner).
py_proibida() { # $1 = linha
  local l="$1"
  [[ "$l" =~ ^[[:space:]]*(-e|--editable|--index-url|--extra-index-url|-i|--find-links|-f|--trusted-host|--no-index)([[:space:]=]|$) ]] && return 0
  [[ "$l" =~ (git|hg|svn|bzr)\+ ]] && return 0
  [[ "$l" == *file:* || "$l" == *http://* || "$l" == *https://* ]] && return 0
  return 1
}

# Confere um arquivo requirements (e os que ele inclui com -r/-c, dentro do mesmo projeto).
# Imprime em stdout as linhas de requisito (sem comentários nem vazias) para a contagem.
py_conferir() { # $1 = arquivo, $2 = raiz do projeto, $3 = profundidade
  local f="$1" proj="$2" prof="$3" linha inc
  [ "$prof" -le 5 ] || { msg "requirements: inclusões demais em $f"; return 1; }
  [ -f "$f" ] || { msg "requirements: arquivo incluído não existe: $f"; return 1; }
  # shellcheck disable=SC2094 # $f só é lido
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%%#*}"
    [[ "$linha" =~ [^[:space:]] ]] || continue
    if [[ "$linha" =~ ^[[:space:]]*(-r|--requirement|-c|--constraint)[[:space:]=]+([^[:space:]]+) ]]; then
      inc="$(dirname "$f")/${BASH_REMATCH[2]}"
      dentro_de "$(dirname "$inc")" "$proj" || { msg "requirements: inclusão fora do projeto: $linha"; return 1; }
      py_conferir "$inc" "$proj" $((prof+1)) || return 1
      continue
    fi
    if py_proibida "$linha"; then
      msg "requirements: opção/origem não permitido em $f: $linha"
      return 1
    fi
    echo "$linha"
  done < "$f"
}

py_checar() { # $1 = dir do projeto, $2 = dir temporário (já criado)
  local d="$1" tmpd="$2" r n=0 lines pj_n=0 total=0 inv usa_pyproject=false
  local -a arqs=()
  cd "$d" || return 1

  for r in requirements*.txt; do
    [ -f "$r" ] || continue
    [ "$(py_filtro "$r")" = skip ] && continue
    arqs+=("$r")
  done
  for r in ${arqs[@]+"${arqs[@]}"}; do
    lines="$(py_conferir "$d/$r" "$d" 0)" || return 1
    [ -z "$lines" ] || n=$((n + $(printf '%s\n' "$lines" | wc -l)))
  done
  if [ -f pyproject.toml ]; then
    pj_n="$(python3 "$here/pyproject_deps.py" pyproject.toml)" || return 1
    [ "$pj_n" -eq 0 ] || usa_pyproject=true
  fi
  total=$((n + pj_n))
  [ -f uv.lock ] && total=$((total + 1))
  if [ "$total" -eq 0 ]; then
    echo "NADA"   # nada declarado para produção neste diretório
    return 0
  fi

  python3 -m venv "$tmpd/venv" || return 1
  # shellcheck disable=SC1091
  . "$tmpd/venv/bin/activate"
  pip install -q --upgrade pip >/dev/null || return 1
  if [ -f uv.lock ]; then
    pip install -q uv || return 1
    uv export --frozen --no-dev --no-hashes -o "$tmpd/req.txt" >/dev/null || return 1
    pip install -q -r "$tmpd/req.txt" || return 1
  fi
  if [ "$usa_pyproject" = true ] && [ ! -f uv.lock ]; then
    pip install -q . || return 1
  fi
  for r in ${arqs[@]+"${arqs[@]}"}; do
    if ! pip install -q --only-binary=:all: -r "$r"; then
      # sem wheel? tenta de novo a partir do código-fonte; se falhar de novo, é erro de verdade
      pip install -q -r "$r" || return 1
      msg "⚠️ instalado a partir de código-fonte: $d ($r)"
    fi
  done
  pip install -q pip-licenses==5.5.5 || return 1
  inv="$tmpd/inv.json"
  pip-licenses --format=json --from=mixed > "$inv" || return 1
  # Declarou dependências e o inventário veio vazio: falha fechado.
  [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$inv")" -gt 0 ] \
    || { msg "python: $d declara dependências, mas o inventário veio vazio"; return 1; }
  python3 "$here/licenses.py" pip --allow "$allow" < "$inv"
}

while IFS= read -r d; do
  tmpd="$(mktemp -d)"
  if saida="$(py_checar "$d" "$tmpd" 2>&1)"; then
    if [ "$(printf '%s\n' "$saida" | tail -1)" = NADA ]; then
      resumo "ℹ️ $d: nenhuma dependência de produção declarada (python), nada a verificar"
    else
      printf '%s\n' "$saida"
      resumo "✅ licença: $d (python)"
      checados=$((checados+1))
    fi
  else
    printf '%s\n' "$saida"
    resumo "❌ licença: $d (python)"; falhou=1
    checados=$((checados+1))
  fi
  rm -rf "$tmpd"
done < <( { achar pyproject.toml; achar 'requirements*.txt'; } | while IFS= read -r x; do dirname "$x"; done | sort -u)

# ---------------- Go ----------------
go_checar() { # $1 = dir
  local mod
  cd "$1" || return 1
  mod="$(GOWORK=off go list -m)" || { echo "go: 'go list -m' falhou"; return 1; }
  [ -n "$mod" ] || { echo "go: 'go list -m' não retornou o módulo"; return 1; }
  GOWORK=off go run github.com/google/go-licenses/v2@v2.0.1 check ./... \
    --allowed_licenses="${allow//;/,}" --ignore "$mod"
}
while IFS= read -r gm; do
  d="$(dirname "$gm")"
  if saida="$(go_checar "$d" 2>&1)"; then
    resumo "✅ licença: $d (go)"
  else
    printf '%s\n' "$saida"
    resumo "❌ licença: $d (go): $(printf '%s\n' "$saida" | tail -3 | tr '\n' ' ')"; falhou=1
  fi
  checados=$((checados+1))
done < <(achar go.mod)

# ---------------- Flutter ----------------
while IFS= read -r ps; do
  d="$(dirname "$ps")"
  (flutter pub get --directory "$d" >/dev/null && python3 "$here/licenses.py" dart --allow "$allow" "$d") \
    || { resumo "❌ licença: $d (flutter)"; falhou=1; }
  checados=$((checados+1))
done < <(achar pubspec.yaml)

[ "$checados" -gt 0 ] || resumo "Nenhum subprojeto com dependências: nada a verificar."
exit $falhou
