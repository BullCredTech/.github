#!/usr/bin/env bash
# Checagem de licença por subprojeto. FALHA FECHADO: nunca fica verde sem ter inventariado o que o repo declara.
#   license.sh detect <raiz>                       -> node=,python=,go=,flutter= (true|false)
#   license.sh check <raiz> <allowlist> <extras>   -> roda as ferramentas e falha se algo estiver fora
#   license.sh pyfiltro <nome-de-arquivo> [dir]    -> skip|install (arquivos requirements de dev/test são pulados)
#   license.sh npmwalk <raiz>                      -> inventário JSON do node_modules (sem rede, sem instalar)
# Extras: SPDX separados por ';' (license.extra_allowed do repo, já validado por config.sh).
# Nada do repo escaneado é executado via eval/source; o npm/yarn rodam com --ignore-scripts.
# Importante: dentro de `if f` / `f || ...` o `set -e` NÃO vale, então toda função usada assim
# tem `|| return 1` explícito depois de cada comando que importa.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:?}"

minusculo() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Arquivos requirements de desenvolvimento/teste (não vão para produção), com fronteira de palavra:
# requirements-dev.txt sim, requirements-devops.txt não. Dentro de uma pasta requirements/ (2º argumento
# "dir") também valem dev.txt, test.txt, lint.txt e docs.txt.
py_filtro() { # $1 = nome do arquivo, $2 = "dir" (opcional)
  local n
  n="$(minusculo "$1")"
  if [[ "$n" =~ ^requirements[-_.](dev|test|lint|docs)([-_.].*)?\.txt$ ]] \
    || [[ "$n" =~ ^(dev|test)-requirements([-_.].*)?\.txt$ ]] \
    || { [ "${2:-}" = dir ] && [[ "$n" =~ ^(dev|test|lint|docs)([-_.].*)?\.txt$ ]]; }; then
    echo skip
  else
    echo install
  fi
}

if [ "$cmd" = "pyfiltro" ]; then py_filtro "${2:?}" "${3:-}"; exit 0; fi

root="${2:?}"

if [ "$cmd" = "npmwalk" ]; then node "$here/npmwalk.js" "$root" "${@:3}"; exit; fi

# Só node_modules, .git, venvs e caches de terraform ficam de fora (build/ e dist/ NÃO: não dá para
# esconder um subprojeto ali).
achar() { # $1 = padrão de nome (find -name)
  find "$root" \( -name node_modules -o -name .venv -o -name venv -o -name .git \
    -o -name .terraform -o -name .terragrunt-cache -o -name .org-security \) -prune \
    -o -type f -name "$1" -print
}
dirs_de() { local f; while IFS= read -r f; do dirname "$f"; done; }

# Diretórios de projetos Python: pyproject.toml, setup.py, setup.cfg com [metadata]/[options], requirements*.txt,
# requirements/*.txt (o projeto é o pai da pasta requirements) e Pipfile/Pipfile.lock.
py_dirs() {
  {
    achar pyproject.toml | dirs_de
    achar setup.py | dirs_de
    achar 'requirements*.txt' | dirs_de
    achar Pipfile | dirs_de
    achar Pipfile.lock | dirs_de
    { achar setup.cfg | while IFS= read -r f; do if grep -qE '^\[(metadata|options)' "$f"; then echo "$f"; fi; done; } | dirs_de
    { achar '*.txt' | while IFS= read -r f; do if [[ "${f#"$root"}" =~ /requirements/[^/]+\.txt$ ]]; then echo "$f"; fi; done; } | dirs_de | dirs_de
  } | sort -u
}

if [ "$cmd" = "detect" ]; then
  tem() { if [ -n "$(achar "$1" | head -1)" ]; then echo true; else echo false; fi; }
  echo "node=$(tem package.json)"
  if [ -n "$(py_dirs | head -1)" ]; then echo "python=true"; else echo "python=false"; fi
  echo "go=$(tem go.mod)"
  echo "flutter=$(tem pubspec.yaml)"
  exit 0
fi

resumo() { echo "$1" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
# caminho relativo à raiz do repo (nunca o caminho absoluto do runner nas mensagens)
rel() { local x="${1#"$root"}"; x="${x#/}"; echo "${x:-.}"; }
msg() { echo "$1" >&2; echo "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# $1 está dentro de $2 (resolvendo symlinks e ..)?
dentro_de() {
  local r p
  r="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  p="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  case "$p/" in "$r"/*) return 0 ;; esac
  return 1
}

# Parser de requirements por LISTA DE PERMISSÃO: só entra o que é reconhecido; o resto reprova com a linha.
PY_SPEC_RE='^[a-z0-9][a-z0-9._-]*(\[[a-z0-9,._-]+\])?[[:space:]]*(([<>=!~]=?|===)[[:space:]]*[a-z0-9*][^;@[:space:]]*([[:space:]]*,[[:space:]]*([<>=!~]=?|===)[[:space:]]*[a-z0-9*][^;@[:space:]]*)*)?([[:space:]]*;.*)?$'
# alfabeto permitido no marcador de ambiente (depois do primeiro ';')
PY_MARCADOR_RE="^[a-z0-9_.'\"[:space:]()<>=!~,*-]*\$"
PY_INC_RE='^(--requirement|--constraint|-r|-c)[[:space:]=]*(.+)$'
# shellcheck disable=SC2016 # literal de propósito
PY_DOLAR='${'
PY_VISTOS=""

# Confere um arquivo requirements (e os que ele inclui com -r/-c, em qualquer forma, dentro do projeto).
# Imprime em stdout as linhas de requisito aceitas (para a contagem). Continuação com \ é juntada antes.
py_conferir() { # $1 = arquivo, $2 = raiz do projeto, $3 = profundidade
  local f="$1" proj="$2" prof="$3" linha acum="" real
  [ "$prof" -le 5 ] || { msg "requirements: inclusões demais em $(rel "$f")"; return 1; }
  [ -f "$f" ] || { msg "requirements: arquivo incluído não existe: $(rel "$f")"; return 1; }
  # shellcheck disable=SC2094 # só lê $f
  if ! tr -d '\000' < "$f" | cmp -s - "$f"; then msg "requirements: não permitido em $(rel "$f"): byte NUL"; return 1; fi
  real="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
  case "$PY_VISTOS" in *"|$real|"*) return 0 ;; esac   # ciclo ou arquivo já conferido
  PY_VISTOS="$PY_VISTOS|$real|"
  # shellcheck disable=SC2094 # $f só é lido
  while IFS= read -r linha || [ -n "$linha" ]; do
    if [[ "$linha" == *\\ ]]; then acum="$acum${linha%\\} "; continue; fi
    linha="$acum$linha"; acum=""
    py_linha "$linha" "$f" "$proj" "$prof" || return 1
  done < "$f"
  if [ -n "$acum" ]; then py_linha "$acum" "$f" "$proj" "$prof" || return 1; fi
}

py_linha() { # $1 = linha, $2 = arquivo, $3 = projeto, $4 = profundidade
  local linha="$1" f="$2" proj="$3" prof="$4" ll nome antes inc marcador
  linha="${linha#$'\xEF\xBB\xBF'}"   # BOM UTF-8
  linha="${linha//$'\t'/ }"
  case "$linha" in \#*) linha="" ;; esac
  linha="${linha%%[[:space:]]#*}"
  linha="$(printf '%s' "$linha" | sed -E 's/--hash=[A-Za-z0-9_]+:[A-Za-z0-9]+//g')"
  linha="${linha#"${linha%%[![:space:]]*}"}"; linha="${linha%"${linha##*[![:space:]]}"}"
  [ -n "$linha" ] || return 0
  ll="$(minusculo "$linha")"
  if [[ "$linha" =~ $PY_INC_RE ]]; then
    inc="${BASH_REMATCH[2]}"
    inc="${inc#"${inc%%[![:space:]]*}"}"
    if [[ "$inc" == *://* || "$inc" == *"$PY_DOLAR"* || "$inc" == *%* ]]; then
      msg "requirements: não permitido em $(rel "$f"): $linha"; return 1
    fi
    case "$inc" in /*) ;; *) inc="$(dirname "$f")/$inc" ;; esac
    dentro_de "$(dirname "$inc")" "$proj" || { msg "requirements: não permitido em $(rel "$f") (inclusão fora do projeto): $linha"; return 1; }
    py_conferir "$inc" "$proj" $((prof+1)) || return 1
    return 0
  fi
  if [[ "$ll" == *://* || "$ll" == *"$PY_DOLAR"* || "$ll" == *%* || "$ll" == *@* ]]; then
    msg "requirements: não permitido em $(rel "$f"): $linha"; return 1
  fi
  if ! [[ "$ll" =~ $PY_SPEC_RE ]]; then
    msg "requirements: não permitido em $(rel "$f"): $linha"; return 1
  fi
  antes="${ll%%;*}"
  if [[ "$ll" == *\;* ]]; then
    marcador="${ll#*;}"
    [[ "$marcador" =~ $PY_MARCADOR_RE ]] || { msg "requirements: não permitido em $(rel "$f") (marcador com caracteres fora do alfabeto): $linha"; return 1; }
  fi
  if [[ "$ll" =~ [[:space:]]- ]]; then msg "requirements: não permitido em $(rel "$f") (opção depois do requisito): $linha"; return 1; fi
  [[ "$ll" =~ ^([a-z0-9][a-z0-9._-]*) ]] && nome="${BASH_REMATCH[1]}"
  if [[ "$antes" == */* || "$nome" =~ \.(whl|zip|gz|tgz|tar|bz2|egg)$ ]]; then
    msg "requirements: não permitido em $(rel "$f") (caminho/arquivo local): $linha"; return 1
  fi
  echo "$ll"
}

# license.sh pyreq <dir-do-projeto> <arquivo>: confere um requirements e imprime as linhas aceitas (para testes)
if [ "$cmd" = "pyreq" ]; then PY_VISTOS=""; py_conferir "${3:?}" "$root" 0; exit; fi

[ "$cmd" = "check" ] || { echo "comando inválido: $cmd" >&2; exit 2; }
allowfile="${3:?}"; extras="${4:-}"
allow="$(grep -vE '^[[:space:]]*(#|$)' "$allowfile" | paste -sd ';' -)"
[ -z "$extras" ] || allow="$allow;$extras"
falhou=0; checados=0
# ---------------- npm e yarn ----------------
# Instala só as dependências de produção (sem scripts) e percorre o node_modules inteiro com o npmwalk.js:
# o license-checker só seguia as deps do package.json inicial e perdia os pacotes aninhados.
COBERTOS=""   # diretórios de workspace que o npm/yarn reportou (cobertos pela raiz)
NWS=0

node_checar() { # $1 = dir, $2 = rótulo (npm|yarn)
  local d="$1" rot="$2" decl hasd wsdirs="" w inv
  local -a arr=() wargs=() margs=()
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
        || { msg "workspaces: não consegui listar os workspaces de $(rel "$d") com 'npm query'"; return 1; }
    else
      wsdirs="$(cd "$d" && yarn workspaces info --json | node "$here/workspaces.js" yarndirs "$d")" \
        || { msg "workspaces: não consegui listar os workspaces de $(rel "$d") com 'yarn workspaces info'"; return 1; }
    fi
    [ -n "$wsdirs" ] || { msg "workspaces: declarados em $(rel "$d"), mas o gerenciador não listou nenhum"; return 1; }
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      dentro_de "$w" "$d" || { msg "workspaces: um workspace resolve para fora da raiz do repo (${w##*/})"; return 1; }
      arr+=("$w")
      wargs+=(--expect "$w")
    done <<< "$wsdirs"
    NWS=${#arr[@]}
    for w in "${arr[@]}"; do COBERTOS="$COBERTOS
$w"; done
  fi
  hasd="$(node "$here/workspaces.js" hasdeps "$d" ${arr[@]+"${arr[@]}"})" || return 1
  [ "$hasd" != true ] || margs=(--min 1)
  inv="$(mktemp)" || return 1
  node "$here/npmwalk.js" "$d" ${margs[@]+"${margs[@]}"} ${wargs[@]+"${wargs[@]}"} > "$inv" || { rm -f "$inv"; return 1; }
  python3 "$here/licenses.py" npm --allow "$allow" < "$inv" || { rm -f "$inv"; return 1; }
  rm -f "$inv"
}

registrar_node() { # $1 = dir, $2 = rótulo
  if node_checar "$1" "$2"; then
    resumo "✅ licença: $(rel "$1") ($2, $NWS workspaces)"
  else
    resumo "❌ licença: $(rel "$1") ($2)"; falhou=1
  fi
  checados=$((checados+1))
}

FEITOS=""
# pnpm não é suportado: falha fechado em vez de ignorar.
while IFS= read -r pl; do
  resumo "❌ licença: $(rel "$(dirname "$pl")"): pnpm não suportado (pnpm-lock.yaml)"; falhou=1; checados=$((checados+1))
done < <(achar pnpm-lock.yaml)

# 1ª passada: raízes com lockfile. Elas dizem (via npm/yarn) quais diretórios são workspaces.
while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if [ -f "$d/pnpm-lock.yaml" ]; then continue; fi
  if [ -f "$d/package-lock.json" ]; then rot=npm; elif [ -f "$d/yarn.lock" ]; then rot=yarn; else continue; fi
  FEITOS="$FEITOS
$d"
  registrar_node "$d" "$rot"
done < <(achar package.json)

# 2ª passada: o que sobrou. Workspace reportado pela raiz está coberto. Sem lockfile e declarando
# dependências, as dependências não são verificáveis: reprova.
while IFS= read -r pj; do
  d="$(dirname "$pj")"
  if printf '%s\n' "$FEITOS" | grep -Fxq -- "$d"; then continue; fi
  if printf '%s\n' "$COBERTOS" | grep -Fxq -- "$d"; then continue; fi
  if [ -f "$d/pnpm-lock.yaml" ]; then continue; fi
  if h="$(node "$here/workspaces.js" hasdeps "$d")"; then
    if [ "$h" = true ]; then
      resumo "❌ licença: $(rel "$d"): sem lockfile: dependências não verificáveis"; falhou=1; checados=$((checados+1))
    fi
  else
    resumo "❌ licença: $(rel "$d"): package.json ilegível"; falhou=1; checados=$((checados+1))
  fi
done < <(achar package.json)

# ---------------- Python ----------------
py_checar() { # $1 = dir do projeto, $2 = dir temporário (já criado)
  local d="$1" tmpd="$2" r n=0 lines pj_n=0 total=0 inv usa_pyproject=false
  local -a arqs=()
  cd "$d" || return 1

  for r in requirements*.txt; do
    [ -f "$r" ] || continue
    [ "$(py_filtro "$r")" = skip ] && continue
    arqs+=("$r")
  done
  if [ -d requirements ]; then
    for r in requirements/*.txt; do
      [ -f "$r" ] || continue
      [ "$(py_filtro "$(basename "$r")" dir)" = skip ] && continue
      arqs+=("$r")
    done
  fi
  for r in ${arqs[@]+"${arqs[@]}"}; do
    PY_VISTOS=""
    lines="$(py_conferir "$d/$r" "$d" 0)" || return 1
    [ -z "$lines" ] || n=$((n + $(printf '%s\n' "$lines" | wc -l)))
  done
  if [ -f pyproject.toml ]; then
    pj_n="$(python3 "$here/pyproject_deps.py" pyproject.toml)" || return 1
    [ "$pj_n" -eq 0 ] || usa_pyproject=true
  fi
  # setup.py (ou setup.cfg com [metadata]/[options]) declara dependências que não dá para contar sem executar:
  # instala o projeto e conta como 1.
  if [ -f setup.py ] || { [ -f setup.cfg ] && grep -qE '^\[(metadata|options)' setup.cfg; }; then
    usa_pyproject=true; [ "$pj_n" -gt 0 ] || pj_n=1
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
      msg "⚠️ instalado a partir de código-fonte: $(rel "$d") ($r)"
    fi
  done
  pip install -q pip-licenses==5.5.5 || return 1
  inv="$tmpd/inv.json"
  pip-licenses --format=json --from=mixed > "$inv" || return 1
  # Declarou dependências e o inventário veio vazio: falha fechado.
  [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$inv")" -gt 0 ] \
    || { msg "python: $(rel "$d") declara dependências, mas o inventário veio vazio"; return 1; }
  python3 "$here/licenses.py" pip --allow "$allow" < "$inv"
}

while IFS= read -r d; do
  if { [ -f "$d/Pipfile" ] || [ -f "$d/Pipfile.lock" ]; } && [ ! -f "$d/pyproject.toml" ]; then
    resumo "❌ licença: $(rel "$d"): pipenv não suportado (Pipfile)"; falhou=1; checados=$((checados+1)); continue
  fi
  tmpd="$(mktemp -d)"
  if saida="$(py_checar "$d" "$tmpd" 2>&1)"; then
    if [ "$(printf '%s\n' "$saida" | tail -1)" = NADA ]; then
      resumo "ℹ️ $(rel "$d"): nenhuma dependência de produção declarada (python), nada a verificar"
    else
      printf '%s\n' "$saida"
      resumo "✅ licença: $(rel "$d") (python)"
      checados=$((checados+1))
    fi
  else
    printf '%s\n' "$saida"
    resumo "❌ licença: $(rel "$d") (python)"; falhou=1
    checados=$((checados+1))
  fi
  rm -rf "$tmpd"
done < <(py_dirs)

# ---------------- Go ----------------
go_checar() { # $1 = dir
  local mod
  cd "$1" || return 1
  export GOWORK=off GOTOOLCHAIN=local
  mod="$(go list -m)" || { echo "go: 'go list -m' falhou"; return 1; }
  [ -n "$mod" ] || { echo "go: 'go list -m' não retornou o módulo"; return 1; }
  go run github.com/google/go-licenses/v2@v2.0.1 check ./... \
    --allowed_licenses="${allow//;/,}" --ignore "$mod"
}
while IFS= read -r gm; do
  d="$(dirname "$gm")"
  if saida="$(go_checar "$d" 2>&1)"; then
    resumo "✅ licença: $(rel "$d") (go)"
  else
    printf '%s\n' "$saida"
    resumo "❌ licença: $(rel "$d") (go): $(printf '%s\n' "$saida" | tail -3 | tr '\n' ' ')"; falhou=1
  fi
  checados=$((checados+1))
done < <(achar go.mod)

# ---------------- Flutter ----------------
while IFS= read -r ps; do
  d="$(dirname "$ps")"
  (flutter pub get --directory "$d" >/dev/null && python3 "$here/licenses.py" dart --allow "$allow" "$d") \
    || { resumo "❌ licença: $(rel "$d") (flutter)"; falhou=1; }
  checados=$((checados+1))
done < <(achar pubspec.yaml)

[ "$checados" -gt 0 ] || resumo "Nenhum subprojeto com dependências: nada a verificar."
exit $falhou
