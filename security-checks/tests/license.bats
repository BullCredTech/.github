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
  [[ "$output" == *"node=true"* ]]; [[ "$output" == *"python=true"* ]]
  [[ "$output" == *"go=true"* ]]; [[ "$output" == *"flutter=true"* ]]
}

@test "detect: repo sem dependência" {
  echo "# docs" > "$REPO/README.md"
  run bash "$SCRIPT" detect "$REPO"
  [[ "$output" == *"node=false"* ]]; [[ "$output" == *"python=false"* ]]
  [[ "$output" == *"go=false"* ]]; [[ "$output" == *"flutter=false"* ]]
}

@test "detect ignora a pasta .org-security" {
  mkdir -p "$REPO/.org-security/x"; echo '{}' > "$REPO/.org-security/x/package.json"
  run bash "$SCRIPT" detect "$REPO"
  [[ "$output" == *"node=false"* ]]
}

@test "check: repo sem subprojeto não falha" {
  echo "# docs" > "$REPO/README.md"
  run bash "$SCRIPT" check "$REPO" "$BATS_TEST_DIRNAME/../license-allowlist.txt" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a verificar"* ]]
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
# npx falso: guarda os argumentos em $SHIMS/npx.args e sai com o código dado
shim_npx() { shim npx 'echo "$@" > "'"$SHIMS"'/npx.args"; exit '"$1"; }
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
  run bash -c "echo '[{\"path\":\"$REPO/packages/a\"},{\"location\":\"packages/b\",\"path\":\"$REPO/packages/b\"}]' | node '$WS' npmdirs '$REPO'"
  [ "$status" -eq 0 ]; [ "$output" = "$REPO/packages/a"$'\n'"$REPO/packages/b" ]
  run bash -c "printf 'yarn workspaces v1.22.22\n{\"a\":{\"location\":\"packages/a\"}}\nDone in 0.01s.\n' | node '$WS' yarndirs '$REPO'"
  [ "$status" -eq 0 ]; [ "$output" = "$REPO/packages/a" ]
  run bash -c "echo 'lixo' | node '$WS' npmdirs '$REPO'"; [ "$status" -eq 1 ]
  run bash -c "echo 'lixo' | node '$WS' yarndirs '$REPO'"; [ "$status" -eq 1 ]
}

@test "ids e union com os diretórios informados" {
  printf '{"name":"root","version":"1.0.0","private":true,"workspaces":["packages/*"],"dependencies":{"left-pad":"1","a":"1.0.0"},"devDependencies":{"typescript":"5"}}' > "$REPO/package.json"
  mkdir -p "$REPO/packages/a" "$REPO/packages/b"
  printf '{"name":"a","version":"1.0.0","dependencies":{"pg":"8","b":"1.0.0"},"devDependencies":{"jest":"1"}}' > "$REPO/packages/a/package.json"
  printf '{"name":"b","version":"1.0.0","dependencies":{"fastify":"5"},"optionalDependencies":{"fsevents":"2"}}' > "$REPO/packages/b/package.json"
  run node "$WS" ids "$REPO" "$REPO/packages/a" "$REPO/packages/b"
  [ "$output" = "root@1.0.0;a@1.0.0;b@1.0.0" ]
  run node "$WS" union "$REPO" "$REPO/packages/a" "$REPO/packages/b"
  [ "$status" -eq 0 ]
  echo "$output" | node -e '
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const d = Object.keys(p.dependencies).sort().join(",");
    if (d !== "fastify,fsevents,left-pad,pg") { console.error("deps: " + d); process.exit(1); }
    if (p.devDependencies || p.workspaces || p.name !== "root" || p.private !== true) process.exit(2);'
  run node "$WS" union "$REPO" "$REPO/packages/naoexiste"
  [ "$status" -eq 1 ]
}

# ---------- npm/yarn: falha fechado ----------
@test "node: shim do node que falha reprova" {
  node_proj app; shim node 'exit 1'; shim_npm; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]]
}

@test "node: shim do npx que falha reprova" {
  node_proj app; shim_npm; shim_npx 1
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]]
}

@test "node: npx ok aprova" {
  node_proj app; shim_npm; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"✅"* ]]
}

@test "workspaces: raiz declara mas o npm não retorna nenhum => reprova" {
  ws_root; shim_npm; echo '[]' > "$SHIMS/query.json"; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"workspaces"* ]]
}

@test "workspaces: npm query que falha reprova" {
  ws_root; shim npm 'case "$1" in query) exit 1 ;; *) exit 0 ;; esac'; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
}

@test "workspaces: diretório fora da raiz reprova" {
  ws_root; out="$(mktemp -d)"; printf '{"name":"z","version":"1.0.0"}' > "$out/package.json"
  shim_npm; printf '[{"path":"%s"}]' "$out" > "$SHIMS/query.json"; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  rm -rf "$out"
  [ "$status" -ne 0 ]; [[ "$output" == *"fora da raiz"* ]]
}

@test "workspaces: symlink que escapa da raiz reprova" {
  ws_root; out="$(mktemp -d)"; printf '{"name":"z","version":"1.0.0"}' > "$out/package.json"
  rm -rf "$REPO/packages/a"; ln -s "$out" "$REPO/packages/a"
  shim_npm; printf '[{"path":"%s/packages/a"}]' "$REPO" > "$SHIMS/query.json"; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  rm -rf "$out"
  [ "$status" -ne 0 ]; [[ "$output" == *"fora da raiz"* ]]
}

@test "workspaces: ok => checa a raiz, exclui os pacotes do repo, restaura o package.json e não avisa lockfile" {
  ws_root; cp "$REPO/package.json" "$SHIMS/orig.json"
  shim_npm; printf '[{"path":"%s/packages/a"}]' "$REPO" > "$SHIMS/query.json"; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 workspaces"* ]]
  [[ "$output" != *"sem lockfile"* ]]
  cmp "$REPO/package.json" "$SHIMS/orig.json"
  grep -q -- '--excludePackages root@1.0.0;a@2.0.0' "$SHIMS/npx.args"
}

@test "workspaces: npx que falha reprova e restaura o package.json" {
  ws_root; cp "$REPO/package.json" "$SHIMS/orig.json"
  shim_npm; printf '[{"path":"%s/packages/a"}]' "$REPO" > "$SHIMS/query.json"; shim_npx 1
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
  cmp "$REPO/package.json" "$SHIMS/orig.json"
}

@test "node: package.json sem lockfile fora de workspace mantém o aviso" {
  mkdir -p "$REPO/x"; printf '{"name":"x"}' > "$REPO/x/package.json"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"sem lockfile"* ]]
}

@test "node: package.json inválido reprova" {
  mkdir -p "$REPO/x"; printf '{quebrado' > "$REPO/x/package.json"; echo '{}' > "$REPO/x/package-lock.json"
  shim_npm; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
}

@test "node: workspaces malformado reprova" {
  mkdir -p "$REPO/x"; printf '{"name":"x","workspaces":5}' > "$REPO/x/package.json"; echo '{}' > "$REPO/x/package-lock.json"
  shim_npm; shim_npx 0
  PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]
}

@test "achar: subprojeto em build/ e dist/ não fica escondido" {
  mkdir -p "$REPO/build/x" "$REPO/dist/y"; echo '{}' > "$REPO/build/x/package.json"; echo 'module m' > "$REPO/dist/y/go.mod"
  run bash "$SCRIPT" detect "$REPO"
  [[ "$output" == *"node=true"* ]]; [[ "$output" == *"go=true"* ]]
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
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]]
}

@test "python: pyproject é instalado mesmo com requirements-dev.txt" {
  mkdir -p "$REPO/svc"
  printf '[project]\nname = "x"\nversion = "0.1"\ndependencies = ["pacote-que-nao-existe-org-security-xyz==0.0.1"]\n' > "$REPO/svc/pyproject.toml"
  echo "pytest" > "$REPO/svc/requirements-dev.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"❌"* ]]
}

@test "python: falha de instalação reprova" {
  mkdir -p "$REPO/svc"
  echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements.txt"
  run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; [[ "$output" == *"licença"* ]]
}

@test "python: opções e URLs perigosas em requirements são recusadas" {
  mkdir -p "$REPO/svc"
  for l in '-e .' '--editable ./x' '--index-url https://evil.example/simple' '--extra-index-url https://evil.example' '-i https://evil.example' '--find-links https://evil.example' '-f /tmp/x' 'pkg @ https://evil.example/p.whl' 'git+https://github.com/x/y.git#egg=y' 'pkg @ file:///tmp/p.whl' 'http://evil.example/p.tar.gz'; do
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
  [ "$status" -ne 0 ]; [[ "$output" == *"não permitido"* ]]
}

# ---------- go ----------
@test "go: go.mod sem go instalado/funcional reprova com causa no resumo" {
  mkdir -p "$REPO/svc"; echo 'module m' > "$REPO/svc/go.mod"
  shim go 'echo "boom go" >&2; exit 1'
  GITHUB_STEP_SUMMARY="$SHIMS/summary" PATH="$SHIMS:$PATH" run bash "$SCRIPT" check "$REPO" "$ALLOW" ""
  [ "$status" -ne 0 ]; grep -q 'boom go' "$SHIMS/summary"
}
