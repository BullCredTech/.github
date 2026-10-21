#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/license.sh"
setup() { REPO="$(mktemp -d)"; SHIMS="$(mktemp -d)"; }
teardown() { rm -rf "$REPO" "$SHIMS"; }

@test "detect: monorepo com node, python, go e flutter" {
  mkdir -p "$REPO/apis/a" "$REPO/lambdas/b" "$REPO/svc" "$REPO/app" "$REPO/apis/a/node_modules/x"
  echo '{}' > "$REPO/apis/a/package.json"; echo '{}' > "$REPO/apis/a/package-lock.json"
  echo '{}' > "$REPO/apis/a/node_modules/x/package.json"
  echo 'x' > "$REPO/lambdas/b/requirements.txt"
  echo 'module m' > "$REPO/svc/go.mod"
  echo 'name: app' > "$REPO/app/pubspec.yaml"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"node=true"* ]] || return 1; [[ "$output" == *"python=true"* ]] || return 1
  [[ "$output" == *"go=true"* ]] || return 1; [[ "$output" == *"flutter=true"* ]] || return 1
}

@test "detect: repo sem dependência" {
  echo "# docs" > "$REPO/README.md"
  run bash "$SCRIPT" detect "$REPO"
  [[ "$output" == *"node=false"* ]] || return 1; [[ "$output" == *"python=false"* ]] || return 1
  [[ "$output" == *"go=false"* ]] || return 1; [[ "$output" == *"flutter=false"* ]] || return 1
}

@test "detect ignora a pasta .org-security" {
  mkdir -p "$REPO/.org-security/x"; echo '{}' > "$REPO/.org-security/x/package.json"
  run bash "$SCRIPT" detect "$REPO"
  [[ "$output" == *"node=false"* ]] || return 1
}

@test "check: repo sem subprojeto não falha" {
  echo "# docs" > "$REPO/README.md"
  run bash "$SCRIPT" check "$REPO" "$BATS_TEST_DIRNAME/../license-allowlist.txt" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a verificar"* ]] || return 1
}

@test "comando inválido sai com 2" {
  run bash "$SCRIPT" foo "$REPO"
  [ "$status" -eq 2 ]
}

ALLOW="$BATS_TEST_DIRNAME/../license-allowlist.txt"
WS="$BATS_TEST_DIRNAME/../scripts/workspaces.js"
shim() { printf '#!/bin/sh\n%s\n' "$2" > "$SHIMS/$1"; chmod +x "$SHIMS/$1"; }
mkpkg() { mkdir -p "$REPO/$1"; printf '{"name":"%s","version":"%s"}' "$2" "$3" > "$REPO/$1/package.json"; }
# npm falso: ci ok; query imprime o conteúdo de $SHIMS/query.json
shim_npm() { shim npm 'case "$1" in query) cat "'"$SHIMS"'/query.json" ;; *) exit 0 ;; esac'; }
node_proj() { # $1 = dir relativo; cria package.json + lockfile
  mkdir -p "$REPO/$1"; printf '{"name":"p","version":"1.0.0"}' > "$REPO/$1/package.json"; echo '{}' > "$REPO/$1/package-lock.json"
}
ws_root() { # raiz com workspaces packages/*, um workspace "a" sem lockfile
  mkdir -p "$REPO/packages/a"
  printf '{"name":"root","version":"1.0.0","private":true,"workspaces":["packages/*"],"dependencies":{"x":"1"}}' > "$REPO/package.json"
  echo '{}' > "$REPO/package-lock.json"
  printf '{"name":"a","version":"2.0.0","dependencies":{"y":"1"}}' > "$REPO/packages/a/package.json"
}

# ---------- workspaces.js ----------
@test "declared: array, objeto, ausente, vazio" {
  printf '{"workspaces":["a/*"]}' > "$REPO/package.json"; run node "$WS" declared "$REPO"; [ "$output" = true ]
  printf '{"workspaces":{"packages":["a/*"]}}' > "$REPO/package.json"; run node "$WS" declared "$REPO"; [ "$output" = true ]
  printf '{"name":"x"}' > "$REPO/package.json"; run node "$WS" declared "$REPO"; [ "$output" = false ]
  printf '{"workspaces":[]}' > "$REPO/package.json"; run node "$WS" declared "$REPO"; [ "$output" = false ]
}

@test "declared: JSON inválido ou workspaces malformado falha (nunca 'sem workspaces')" {
  printf '{nao e json' > "$REPO/package.json"; run node "$WS" declared "$REPO"; [ "$status" -eq 1 ]
  for w in '5' '"packages/*"' '{"nope":1}' '[1,2]' '{"packages":"x"}'; do
    printf '{"workspaces":%s}' "$w" > "$REPO/package.json"
    run node "$WS" declared "$REPO"
    [ "$status" -eq 1 ] || { echo "passou: $w"; return 1; }
  done
  rm -f "$REPO/package.json"; run node "$WS" declared "$REPO"; [ "$status" -eq 1 ]
}

@test "npmdirs e yarndirs leem a resposta do gerenciador" {
  run bash -c "echo '[{\"path\":\"$REPO/packages/a\"},{\"location\":\"packages/b\",\"path\":\"/mangled\"}]' | node '$WS' npmdirs '$REPO'"
  [ "$status" -eq 0 ]; [ "$output" = "$REPO/packages/a"$'\n'"$REPO/packages/b" ]
  run bash -c "printf 'yarn workspaces v1.22.22\n{\"a\":{\"location\":\"packages/a\"}}\nDone in 0.01s.\n' | node '$WS' yarndirs '$REPO'"
  [ "$status" -eq 0 ]; [ "$output" = "$REPO/packages/a" ]
  run bash -c "echo 'lixo' | node '$WS' npmdirs '$REPO'"; [ "$status" -eq 1 ]
  run bash -c "echo 'lixo' | node '$WS' yarndirs '$REPO'"; [ "$status" -eq 1 ]
}

@test "hasdeps: dependencies/optionalDependencies, e falha com JSON inválido" {
  printf '{"name":"x"}' > "$REPO/package.json"; run node "$WS" hasdeps "$REPO"; [ "$output" = false ]
  printf '{"dependencies":{}}' > "$REPO/package.json"; run node "$WS" hasdeps "$REPO"; [ "$output" = false ]
  printf '{"dependencies":{"a":"1"}}' > "$REPO/package.json"; run node "$WS" hasdeps "$REPO"; [ "$output" = true ]
  printf '{"optionalDependencies":{"a":"1"}}' > "$REPO/package.json"; run node "$WS" hasdeps "$REPO"; [ "$output" = true ]
  printf '{"devDependencies":{"a":"1"}}' > "$REPO/package.json"; run node "$WS" hasdeps "$REPO"; [ "$output" = false ]
  printf 'quebrado' > "$REPO/package.json"; run node "$WS" hasdeps "$REPO"; [ "$status" -eq 1 ]
}

# ---------- npmwalk (sem rede: node_modules montado à mão) ----------
LIC="$BATS_TEST_DIRNAME/../scripts/licenses.py"
nm() { mkdir -p "$1"; printf '{"name":"%s","version":"%s"%s}' "$2" "$3" "$4" > "$1/package.json"; }
walk_fixture() {
  OUT="$(mktemp -d)"
  printf '{"name":"root","version":"1.0.0","workspaces":["packages/*"],"dependencies":{"a":"1"}}' > "$REPO/package.json"
  N="$REPO/node_modules"
  nm "$N/a" a 1.0.0 ',"license":"MIT"'
  nm "$N/@s/b" @s/b 1.0.0 ',"license":"Apache-2.0"'
  nm "$N/c" c 1.0.0 ',"licenses":[{"type":"MIT"},{"type":"BSD-3-Clause"}]'
  nm "$N/d" d 1.0.0 ',"license":{"type":"ISC"}'
  nm "$N/e" e 1.0.0 ''
  nm "$N/p" p 1.0.0 ',"private":true'
  nm "$N/a/node_modules/is-odd" is-odd 2.0.0 ',"license":"GPL-3.0"'
  nm "$REPO/packages/w" w 1.0.0 ',"license":"UNLICENSED"'
  ln -s ../packages/w "$N/w"
  nm "$REPO/packages/w/node_modules/wdep" wdep 1.0.0 ',"license":"MIT"'
  nm "$OUT/pkg" out-pkg 1.0.0 ',"license":"AGPL-3.0"'
  ln -s "$OUT/pkg" "$N/out-pkg"
  mkdir -p "$N/.bin" "$N/.cache/x"; echo '{}' > "$N/.package-lock.json"; echo '{"name":"lixo"}' > "$N/.cache/x/package.json"
}

@test "npmwalk: percorre aninhados, escopo, licenses legado, objeto, sem licença; pula workspace e raiz" {
  walk_fixture
  run bash "$SCRIPT" npmwalk "$REPO" --expect "$REPO/packages/w"
  rm -rf "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Name":"is-odd","Version":"2.0.0","Path":"node_modules/a/node_modules/is-odd","License":"GPL-3.0"'* ]] || return 1
  [[ "$output" == *'"Name":"@s/b"'* ]] || return 1
  [[ "$output" == *'"License":"MIT OR BSD-3-Clause"'* ]] || return 1
  [[ "$output" == *'"Name":"d","Version":"1.0.0","Path":"node_modules/d","License":"ISC"'* ]] || return 1
  [[ "$output" == *'"Name":"e","Version":"1.0.0","Path":"node_modules/e","License":""'* ]] || return 1
  [[ "$output" == *'"Name":"p"'* ]] || return 1
  [[ "$output" == *'"Name":"wdep"'* ]] || return 1
  [[ "$output" == *'"Name":"out-pkg"'* ]] || return 1
  [[ "$output" != *'"Name":"w"'* ]] || return 1
  [[ "$output" != *'"Name":"root"'* ]] || return 1
  [[ "$output" != *'lixo'* ]] || return 1
}

@test "npmwalk + licenses.py npm: GPL aninhado, symlink para fora e sem licença reprovam" {
  walk_fixture
  bash "$SCRIPT" npmwalk "$REPO" --expect "$REPO/packages/w" > "$REPO/inv.json"
  run python3 "$LIC" npm --allow "MIT;Apache-2.0;BSD-3-Clause;ISC" < "$REPO/inv.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is-odd"* ]] || return 1; [[ "$output" == *"out-pkg"* ]] || return 1
  [[ "$output" == *"sem licença declarada: e@1.0.0"* ]] || return 1
  [[ "$output" == *"peça exceção"* ]] || return 1
  rm -rf "$REPO/node_modules/a/node_modules/is-odd" "$REPO/node_modules/out-pkg" "$REPO/node_modules/e" "$REPO/node_modules/p"
  bash "$SCRIPT" npmwalk "$REPO" --expect "$REPO/packages/w" > "$REPO/inv.json"
  run python3 "$LIC" npm --allow "MIT;Apache-2.0;BSD-3-Clause;ISC" < "$REPO/inv.json"
  rm -rf "$OUT"
  [ "$status" -eq 0 ]
}

@test "npmwalk: falha fechado com symlink quebrado, pacote sem json, workspace ausente e minimo" {
  walk_fixture
  ln -s /caminho/que/nao/existe "$REPO/node_modules/quebrado"
  run bash "$SCRIPT" npmwalk "$REPO"; [ "$status" -eq 1 ]
  rm "$REPO/node_modules/quebrado"
  mkdir -p "$REPO/node_modules/semjson"
  run bash "$SCRIPT" npmwalk "$REPO"; [ "$status" -eq 1 ]
  rmdir "$REPO/node_modules/semjson"
  run node "$BATS_TEST_DIRNAME/../scripts/npmwalk.js" "$REPO" --expect "$REPO/packages/naoligado"; [ "$status" -eq 1 ]
  mkdir -p "$REPO/packages/semlink"
  run node "$BATS_TEST_DIRNAME/../scripts/npmwalk.js" "$REPO" --expect "$REPO/packages/semlink"; [ "$status" -eq 1 ]
  run node "$BATS_TEST_DIRNAME/../scripts/npmwalk.js" "$REPO" --expect "$REPO/packages/w"; [ "$status" -eq 0 ]
  rm -rf "$OUT" "$REPO/node_modules"
  run node "$BATS_TEST_DIRNAME/../scripts/npmwalk.js" "$REPO" --min 1; [ "$status" -eq 1 ]
  run node "$BATS_TEST_DIRNAME/../scripts/npmwalk.js" "$REPO"; [ "$status" -eq 0 ]; [ "$output" = "[]" ]
}

@test "E1: dois pacotes com o mesmo nome@versão em caminhos diferentes, um GPL: reprova" {
  printf '{"name":"root","version":"1.0.0"}' > "$REPO/package.json"
  N="$REPO/node_modules"
  nm "$N/a" a 1.0.0 ',"license":"MIT"'; nm "$N/b" b 1.0.0 ',"license":"MIT"'
  nm "$N/a/node_modules/dup" dup 1.0.0 ',"license":"MIT"'
  nm "$N/b/node_modules/dup" dup 1.0.0 ',"license":"GPL-3.0"'
  bash "$SCRIPT" npmwalk "$REPO" > "$REPO/inv.json"
  [ "$(grep -o '"Name":"dup"' "$REPO/inv.json" | wc -l | tr -d ' ')" -eq 2 ]
  run python3 "$LIC" npm --allow "MIT" < "$REPO/inv.json"
  [ "$status" -eq 1 ]; [[ "$output" == *"GPL-3.0"* ]] || return 1
}

@test "E2: só a raiz e os workspaces esperados são próprios; link para vendor/ com GPL reprova" {
  printf '{"name":"root","version":"1.0.0"}' > "$REPO/package.json"
  N="$REPO/node_modules"
  nm "$REPO/vendor/gpl-lib" gpl-lib 1.0.0 ',"license":"GPL-3.0"'
  mkdir -p "$N"; ln -s ../vendor/gpl-lib "$N/gpl-lib"
  bash "$SCRIPT" npmwalk "$REPO" > "$REPO/inv.json"
  [[ "$(cat "$REPO/inv.json")" == *'"Name":"gpl-lib"'* ]] || return 1
  run python3 "$LIC" npm --allow "MIT" < "$REPO/inv.json"
  [ "$status" -eq 1 ]; [[ "$output" == *"gpl-lib"* ]] || return 1
  # link para pasta de workspace que NÃO foi esperada também é checado
  nm "$REPO/packages/w" w 1.0.0 ',"license":"GPL-3.0"'; ln -s ../packages/w "$N/w"
  run bash "$SCRIPT" npmwalk "$REPO"
  [[ "$output" == *'"Name":"w"'* ]] || return 1
  run bash "$SCRIPT" npmwalk "$REPO" --expect "$REPO/packages/w"
  [[ "$output" != *'"Name":"w"'* ]] || return 1
}

@test "E3: licença ausente no package.json: arquivo LICENSE reconhecido vale; sem arquivo reprova" {
  printf '{"name":"root","version":"1.0.0"}' > "$REPO/package.json"
  N="$REPO/node_modules"
  nm "$N/com-arquivo" com-arquivo 1.0.0 ''
  printf 'MIT License\n\nPermission is hereby granted, free of charge, to any person obtaining a copy' > "$N/com-arquivo/LICENSE"
  bash "$SCRIPT" npmwalk "$REPO" > "$REPO/inv.json"
  run python3 "$LIC" npm --allow "MIT" < "$REPO/inv.json"
  [ "$status" -eq 0 ]
  nm "$N/sem-arquivo" sem-arquivo 2.0.0 ''
  bash "$SCRIPT" npmwalk "$REPO" > "$REPO/inv.json"
  run python3 "$LIC" npm --allow "MIT" < "$REPO/inv.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sem licença declarada: sem-arquivo@2.0.0 (node_modules/sem-arquivo)"* ]] || return 1
  [[ "$output" == *"peça exceção"* ]] || return 1
}

@test "E3: licença presente mas estranha (número, lista, objeto sem type) reprova" {
  printf '{"name":"root","version":"1.0.0"}' > "$REPO/package.json"
  N="$REPO/node_modules"
  for v in '5' '["GPL-3.0"]' '{"url":"x"}'; do
    rm -rf "$N"; nm "$N/estranho" estranho 1.0.0 ",\"license\":$v"
    bash "$SCRIPT" npmwalk "$REPO" > "$REPO/inv.json"
    run python3 "$LIC" npm --allow "MIT;GPL-3.0" < "$REPO/inv.json"
    [ "$status" -eq 1 ] || { echo "passou: $v"; return 1; }
  done
}

@test "F1: hasdeps desconta dependências em pacotes irmãos do workspace" {
  printf '{"name":"root","workspaces":["packages/*"]}' > "$REPO/package.json"
  mkdir -p "$REPO/packages/a" "$REPO/packages/b"
  printf '{"name":"a","version":"1.0.0","dependencies":{"b":"1.0.0"}}' > "$REPO/packages/a/package.json"
  printf '{"name":"b","version":"1.0.0"}' > "$REPO/packages/b/package.json"
  run node "$WS" hasdeps "$REPO" "$REPO/packages/a" "$REPO/packages/b"; [ "$output" = false ]
  printf '{"name":"b","version":"1.0.0","dependencies":{"left-pad":"1"}}' > "$REPO/packages/b/package.json"
  run node "$WS" hasdeps "$REPO" "$REPO/packages/a" "$REPO/packages/b"; [ "$output" = true ]
}

# ---------- npm/yarn: falha fechado ----------
@test "node: shim do node que falha reprova" {
  node_proj app; shim node 'exit 1'; shim_npm
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]] || return 1
}

@test "node: npm ci que falha reprova" {
  node_proj app; shim npm 'exit 1'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]] || return 1
}

@test "node: instalado e tudo permitido aprova; GPL aninhado reprova" {
  node_proj app; shim_npm
  printf '{"name":"p","version":"1.0.0","dependencies":{"a":"1"}}' > "$REPO/app/package.json"
  nm "$REPO/app/node_modules/a" a 1.0.0 ',"license":"MIT"'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"✅"* ]] || return 1
  nm "$REPO/app/node_modules/a/node_modules/is-odd" is-odd 2.0.0 ',"license":"GPL-3.0"'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"is-odd"* ]] || return 1
}

@test "node: declara dependências mas nada foi instalado reprova; sem dependências passa" {
  node_proj app; shim_npm
  printf '{"name":"p","version":"1.0.0","dependencies":{"a":"1"}}' > "$REPO/app/package.json"
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
  printf '{"name":"p","version":"1.0.0"}' > "$REPO/app/package.json"
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]
}

@test "node: package.json com dependências e sem lockfile reprova; sem dependências é ok" {
  mkdir -p "$REPO/x" "$REPO/y"
  printf '{"name":"y"}' > "$REPO/y/package.json"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]
  printf '{"name":"x","dependencies":{"a":"1"}}' > "$REPO/x/package.json"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"sem lockfile: dependências não verificáveis"* ]] || return 1
}

@test "pnpm não é suportado: reprova" {
  mkdir -p "$REPO/x"; printf '{"name":"x"}' > "$REPO/x/package.json"; echo 'lockfileVersion: 9' > "$REPO/x/pnpm-lock.yaml"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"pnpm não suportado"* ]] || return 1
}

@test "node: package.json inválido reprova" {
  mkdir -p "$REPO/x"; printf '{quebrado' > "$REPO/x/package.json"; echo '{}' > "$REPO/x/package-lock.json"
  shim_npm
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
}

@test "node: workspaces malformado reprova" {
  mkdir -p "$REPO/x"; printf '{"name":"x","workspaces":5}' > "$REPO/x/package.json"; echo '{}' > "$REPO/x/package-lock.json"
  shim_npm
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
}

@test "workspaces: raiz declara mas o npm não retorna nenhum => reprova" {
  ws_root; shim_npm; echo '[]' > "$SHIMS/query.json"
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"workspaces"* ]] || return 1
}

@test "workspaces: npm query que falha reprova" {
  ws_root; shim npm 'case "$1" in query) exit 1 ;; *) exit 0 ;; esac'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
}

@test "workspaces: diretório fora da raiz reprova" {
  ws_root; out="$(mktemp -d)"; printf '{"name":"z","version":"1.0.0"}' > "$out/package.json"
  shim_npm; printf '[{"path":"%s"}]' "$out" > "$SHIMS/query.json"
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  rm -rf "$out"
  [ "$status" -ne 0 ]; [[ "$output" == *"fora da raiz"* ]] || return 1
}

@test "workspaces: symlink que escapa da raiz reprova" {
  ws_root; out="$(mktemp -d)"; printf '{"name":"z","version":"1.0.0"}' > "$out/package.json"
  rm -rf "$REPO/packages/a"; ln -s "$out" "$REPO/packages/a"
  shim_npm; printf '[{"location":"packages/a"}]' > "$SHIMS/query.json"
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  rm -rf "$out"
  [ "$status" -ne 0 ]; [[ "$output" == *"fora da raiz"* ]] || return 1
}

@test "workspaces: declarado mas não instalado em node_modules reprova" {
  ws_root; shim_npm; printf '[{"location":"packages/a"}]' > "$SHIMS/query.json"
  nm "$REPO/node_modules/x" x 1.0.0 ',"license":"MIT"'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"workspace não instalado"* ]] || return 1
}

@test "workspaces: instalado => aprova, não avisa do workspace sem lockfile; dep não içada do workspace é checada" {
  ws_root; shim_npm; printf '[{"location":"packages/a"}]' > "$SHIMS/query.json"
  nm "$REPO/node_modules/x" x 1.0.0 ',"license":"MIT"'
  ln -s ../packages/a "$REPO/node_modules/a"
  nm "$REPO/packages/a/node_modules/y" y 1.0.0 ',"license":"MIT"'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 workspaces"* ]] || return 1
  [[ "$output" == *"2 pacotes inventariados"* ]] || return 1
  [[ "$output" != *"sem lockfile"* ]] || return 1
  nm "$REPO/packages/a/node_modules/y" y 1.0.0 ',"license":"AGPL-3.0"'
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"AGPL"* ]] || return 1
}

@test "achar: subprojeto em build/ e dist/ não fica escondido" {
  mkdir -p "$REPO/build/x" "$REPO/dist/y"; echo '{}' > "$REPO/build/x/package.json"; echo 'module m' > "$REPO/dist/y/go.mod"
  run bash "$SCRIPT" detect "$REPO"
  [[ "$output" == *"node=true"* ]] || return 1; [[ "$output" == *"go=true"* ]] || return 1
}

# ---------- python ----------
@test "pyfiltro: só arquivos de dev/test exatos são pulados" {
  for n in requirements-dev.txt Requirements_DEV.txt requirements.test.txt requirements-dev-extra.txt dev-requirements.txt test-requirements-x.txt requirements-lint.txt requirements-docs.txt; do
    run bash "$SCRIPT" pyfiltro "$n"; [ "$output" = skip ] || { echo "devia pular: $n"; return 1; }
  done
  for n in requirements.txt requirements-devops.txt requirements-contest.txt requirements-latest.txt requirements-prod.txt requirements-testing.txt; do
    run bash "$SCRIPT" pyfiltro "$n"; [ "$output" = install ] || { echo "devia instalar: $n"; return 1; }
  done
}

@test "python: só requirements-dev.txt => nada instalado, nada a verificar" {
  mkdir -p "$REPO/svc"; echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements-dev.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]
}

@test "python: requirements-devops.txt é instalado (pacote inexistente => reprova)" {
  mkdir -p "$REPO/svc"; echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements-devops.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]] || return 1
}

@test "python: pyproject é instalado mesmo com requirements-dev.txt" {
  mkdir -p "$REPO/svc"
  printf '[project]\nname = "x"\nversion = "0.1"\ndependencies = ["pacote-que-nao-existe-org-security-xyz==0.0.1"]\n' > "$REPO/svc/pyproject.toml"
  echo "pytest" > "$REPO/svc/requirements-dev.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]] || return 1
}

@test "python: falha de instalação reprova" {
  mkdir -p "$REPO/svc"
  echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"licença"* ]] || return 1
}

@test "python: opções e URLs perigosas em requirements são recusadas" {
  mkdir -p "$REPO/svc"
  for l in '-e .' '--editable ./x' '--index-url https://evil.example/simple' '--extra-index-url https://evil.example' '-i https://evil.example' '--find-links https://evil.example' '-f /tmp/x' 'pkg @ https://evil.example/p.whl' 'git+https://github.com/x/y.git#egg=y' 'pkg @ file:///tmp/p.whl' 'http://evil.example/p.tar.gz' 'six @ GIT+HTTPS://x/y' 'six @ HTTPS://x/y.zip' 'six @ ${GITHUB_SERVER_URL}/x' 'six @ ./local.whl' '--pre' '--no-binary :all:' '--only-binary :none:' '--config-settings x=y' './local.whl' 'local.whl' 'pkg ; python_version >= "3" and x @ y' '-r../outside/o.txt' '-r ../outside/o.txt' '-r=../outside/o.txt' '--requirement=../outside/o.txt' '-c ../outside/o.txt' '--constraint ../outside/o.txt' 'pkg==%s'; do
    mkdir -p "$REPO/outside"; echo requests > "$REPO/outside/o.txt"
    printf '# comentario\nrequests\n%s\n' "$l" > "$REPO/svc/requirements.txt"
    run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
    [ "$status" -ne 0 ] || { echo "passou: $l"; return 1; }
    [[ "$output" == *"não permitido"* ]] || { echo "sem mensagem: $l"; return 1; }
  done
}

@test "python: -r para arquivo com URL também é recusado" {
  mkdir -p "$REPO/svc"
  printf -- '-r base.txt\n' > "$REPO/svc/requirements.txt"; echo 'git+https://github.com/x/y.git' > "$REPO/svc/base.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"não permitido"* ]] || return 1
}

# ---------- go ----------
@test "go: go.mod sem go instalado/funcional reprova com causa no resumo" {
  mkdir -p "$REPO/svc"; echo 'module m' > "$REPO/svc/go.mod"
  shim go 'echo "boom go" >&2; exit 1'
  GITHUB_STEP_SUMMARY="$SHIMS/summary" PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; grep -q 'boom go' "$SHIMS/summary"
}

@test "pyreq: linhas válidas são aceitas (specifiers, extras, marcadores, hashes com continuação, includes)" {
  mkdir -p "$REPO/svc"
  printf 'Django>=4.2,<5\nrequests[security]==2.31.0 ; python_version >= "3.8"\nsix\n# c\n\n-rother.txt\n' > "$REPO/svc/requirements.txt"
  printf 'flask==3.0.0 \\\n    --hash=sha256:abc123 \\\n    --hash=sha256:def456\n--hash=sha256:solta\n' > "$REPO/svc/other.txt"
  run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"django>=4.2,<5"* ]] || return 1
  [[ "$output" == *'requests[security]==2.31.0 ; python_version >= "3.8"'* ]] || return 1
  [[ "$output" == *"flask==3.0.0"* ]] || return 1
  [[ "$output" == *"six"* ]] || return 1
}

@test "pyreq: -rother.txt dentro do projeto é seguido (e o conteúdo dele é conferido); ciclo não trava" {
  mkdir -p "$REPO/svc"
  printf -- '-rother.txt\n' > "$REPO/svc/requirements.txt"
  printf 'six\n-r requirements.txt\n--pre\n' > "$REPO/svc/other.txt"
  run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
  [ "$status" -ne 0 ]; [[ "$output" == *"--pre"* ]] || return 1
  printf 'six\n-r requirements.txt\n' > "$REPO/svc/other.txt"
  run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
  [ "$status" -eq 0 ]
}

@test "python: layout requirements/ aplica o filtro de dev/test pelo nome base" {
  for n in dev.txt test.txt lint.txt docs.txt requirements-dev.txt; do
    run bash "$SCRIPT" pyfiltro "$n" dir; [ "$output" = skip ] || { echo "devia pular: $n"; return 1; }
  done
  for n in base.txt prod.txt production.txt common.txt; do
    run bash "$SCRIPT" pyfiltro "$n" dir; [ "$output" = install ] || { echo "devia instalar: $n"; return 1; }
  done
  run bash "$SCRIPT" pyfiltro dev.txt; [ "$output" = install ]   # fora de requirements/ não vale
}

@test "python: requirements/dev.txt sozinho não instala nada; requirements/base.txt é instalado" {
  mkdir -p "$REPO/svc/requirements"
  echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements/dev.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]
  echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements/base.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]] || return 1
}

@test "python: Pipfile sem pyproject reprova (pipenv não suportado)" {
  mkdir -p "$REPO/svc"; printf '[packages]\nrequests = "*"\n' > "$REPO/svc/Pipfile"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"pipenv não suportado"* ]] || return 1
}

@test "python: setup.py sem pyproject é projeto Python (instala com pip install .)" {
  mkdir -p "$REPO/svc"
  printf 'from setuptools import setup\nsetup(name="x", version="0.1", install_requires=["pacote-que-nao-existe-org-security-xyz==0.0.1"])\n' > "$REPO/svc/setup.py"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌ licença"* ]] || return 1
}

@test "detect: setup.py, setup.cfg com [metadata], Pipfile e requirements/ contam como python" {
  mkdir -p "$REPO/a" "$REPO/b" "$REPO/c" "$REPO/d/requirements" "$REPO/e"
  echo 'x' > "$REPO/a/setup.py"; run bash "$SCRIPT" detect "$REPO"; [[ "$output" == *"python=true"* ]] || return 1; rm "$REPO/a/setup.py"
  printf '[metadata]\nname=x\n' > "$REPO/b/setup.cfg"; run bash "$SCRIPT" detect "$REPO"; [[ "$output" == *"python=true"* ]] || return 1; rm "$REPO/b/setup.cfg"
  printf '[flake8]\nmax-line-length=100\n' > "$REPO/e/setup.cfg"; run bash "$SCRIPT" detect "$REPO"; [[ "$output" == *"python=false"* ]] || return 1
  echo 'x' > "$REPO/c/Pipfile"; run bash "$SCRIPT" detect "$REPO"; [[ "$output" == *"python=true"* ]] || return 1; rm "$REPO/c/Pipfile"
  echo 'six' > "$REPO/d/requirements/base.txt"; run bash "$SCRIPT" detect "$REPO"; [[ "$output" == *"python=true"* ]] || return 1
}

@test "go: GOTOOLCHAIN=local e GOWORK=off são usados" {
  mkdir -p "$REPO/svc"; echo 'module m' > "$REPO/svc/go.mod"
  shim go 'echo "TC=$GOTOOLCHAIN WORK=$GOWORK" >&2; exit 1'
  GITHUB_STEP_SUMMARY="$SHIMS/summary" PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"TC=local WORK=off"* ]] || return 1
}

@test "B1b: marcador só com o alfabeto permitido e sem token -opção" {
  mkdir -p "$REPO/svc"
  for l in 'six ; python_version >= "3" --index-url=http://x' 'six==1 ; python_version >= "3" -e .' 'six ; python_version >= "3" ; --pre' 'six ; $(id)' 'six ; a|b' 'six ; a`b`' 'six ; x{y}' 'six==1.0 --trusted-host x' 'six ; a\\b' 'six ; python_version >= "3" --no-binary :all:' 'six ; os_name == "a" -c ../x'; do
    printf '%s\n' "$l" > "$REPO/svc/requirements.txt"
    run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
    [ "$status" -ne 0 ] || { echo "passou: $l"; return 1; }
  done
  printf 'requests==2.31.0 ; python_version >= "3.8" and sys_platform != "win32"\n' > "$REPO/svc/requirements.txt"
  run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
  [ "$status" -eq 0 ]
}

@test "F2: requirements com byte NUL é recusado" {
  mkdir -p "$REPO/svc"; printf 'six\0\n--pre\n' > "$REPO/svc/requirements.txt"
  run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
  [ "$status" -ne 0 ]; [[ "$output" == *"NUL"* ]] || return 1
}

@test "F3: BOM UTF-8 no inicio do requirements e ignorado" {
  mkdir -p "$REPO/svc"; printf '\xEF\xBB\xBFsix==1.16.0\n' > "$REPO/svc/requirements.txt"
  run bash "$SCRIPT" pyreq "$REPO/svc" "$REPO/svc/requirements.txt"
  [ "$status" -eq 0 ]; [ "$output" = "six==1.16.0" ]
}

@test "F4: o layout requirements/ vale pelo caminho relativo à raiz (raiz dentro de pasta requirements)" {
  base="$(mktemp -d)"; r="$base/requirements"; mkdir -p "$r/docs"
  echo "um texto qualquer" > "$r/docs/notes.txt"; echo "x" > "$r/lista.txt"
  run bash "$SCRIPT" detect "$r"
  [[ "$output" == *"python=false"* ]] || return 1
  mkdir -p "$r/svc/requirements"; echo six > "$r/svc/requirements/base.txt"
  run bash "$SCRIPT" detect "$r"
  rm -rf "$base"
  [[ "$output" == *"python=true"* ]] || return 1
}
