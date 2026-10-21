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
