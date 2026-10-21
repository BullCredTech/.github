#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/license.sh"
setup() { REPO="$(mktemp -d)"; }
teardown() { rm -rf "$REPO"; }

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

mkpkg() { mkdir -p "$REPO/$1"; printf '{"name":"%s","version":"%s"}' "$2" "$3" > "$REPO/$1/package.json"; }

@test "workspaces: forma de array com glob packages/*" {
  mkdir -p "$REPO/packages/sem-pkg"
  printf '{"name":"root","version":"1.0.0","workspaces":["packages/*","tools/cli"]}' > "$REPO/package.json"
  mkpkg packages/a a 1.0.0; mkpkg packages/b b 2.0.0; mkpkg tools/cli cli 0.1.0
  run bash "$SCRIPT" workspaces "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$REPO/packages/a"* ]]; [[ "$output" == *"$REPO/packages/b"* ]]
  [[ "$output" == *"$REPO/tools/cli"* ]]
  [[ "$output" != *"sem-pkg"* ]]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "workspaces: forma de objeto {packages: [...]}" {
  printf '{"name":"root","workspaces":{"packages":["apps/*"]}}' > "$REPO/package.json"
  mkpkg apps/web web 1.0.0
  run bash "$SCRIPT" workspaces "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/apps/web" ]
}

@test "workspaces: sem workspaces não imprime nada" {
  printf '{"name":"root"}' > "$REPO/package.json"
  run bash "$SCRIPT" workspaces "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "workspaces: ignora node_modules e negações" {
  printf '{"name":"root","workspaces":["packages/*","!packages/b"]}' > "$REPO/package.json"
  mkpkg packages/a a 1.0.0; mkpkg packages/b b 1.0.0; mkpkg packages/node_modules x 1.0.0
  run bash "$SCRIPT" workspaces "$REPO"
  [ "$output" = "$REPO/packages/a" ]
}

@test "pkgids: name@version do root e dos workspaces, separados por ;" {
  printf '{"name":"root","version":"1.0.0","workspaces":["packages/*"]}' > "$REPO/package.json"
  mkpkg packages/a a 2.0.0
  run bash "$SCRIPT" pkgids "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "root@1.0.0;a@2.0.0" ]
}

@test "union: junta as dependências de produção da raiz e dos workspaces, sem os pacotes do próprio repo" {
  printf '{"name":"root","version":"1.0.0","private":true,"workspaces":["packages/*"],"dependencies":{"left-pad":"1"},"devDependencies":{"typescript":"5"}}' > "$REPO/package.json"
  mkdir -p "$REPO/packages/a" "$REPO/packages/b"
  printf '{"name":"a","version":"1.0.0","dependencies":{"pg":"8","b":"1.0.0"},"devDependencies":{"jest":"1"}}' > "$REPO/packages/a/package.json"
  printf '{"name":"b","version":"1.0.0","dependencies":{"fastify":"5"},"optionalDependencies":{"fsevents":"2"}}' > "$REPO/packages/b/package.json"
  run bash "$SCRIPT" union "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | node -e '
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const d = Object.keys(p.dependencies).sort().join(",");
    if (d !== "fastify,fsevents,left-pad,pg") { console.error("deps: " + d); process.exit(1); }
    if (p.devDependencies || p.workspaces || p.name !== "root" || p.private !== true) process.exit(2);'
}

@test "check python: falha de instalação reprova (não vira 'ok' com 0 pacotes)" {
  mkdir -p "$REPO/svc"
  echo "pacote-que-nao-existe-org-security-xyz==0.0.1" > "$REPO/svc/requirements.txt"
  run bash "$SCRIPT" check "$REPO" "$BATS_TEST_DIRNAME/../license-allowlist.txt" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"licença"* ]]
}
