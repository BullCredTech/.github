#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/changes.sh"

setup() {
  REPO="$(mktemp -d)"; cd "$REPO"
  git init -q -b main; git config user.email t@t; git config user.name t
  mkdir -p docs src; echo a > README.md; echo x > src/app.js; git add -A; git commit -qm base
  BASE=$(git rev-parse HEAD)
}
teardown() { rm -rf "$REPO"; }
commit() { git add -A; git commit -qm c; HEAD_SHA=$(git rev-parse HEAD); }

@test "só docs: docs_only=true" {
  echo b >> docs/guia.md; echo c >> README.md; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=true"* ]]
}

@test "código: docs_only=false" {
  echo y >> src/app.js; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]]
}

@test "docs e código juntos: docs_only=false" {
  echo b >> docs/guia.md; echo y >> src/app.js; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]]
}

@test "padrão extra do repo conta como docs" {
  mkdir -p handbook; echo z > handbook/x.txt; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" "handbook/**"
  [[ "$output" == *"docs_only=true"* ]]
}

@test "utils não é docs" {
  mkdir -p utils; echo z > utils/run.sh; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]]
}

@test "sem mudança: docs_only=false (escaneia)" {
  run bash "$SCRIPT" "$REPO" "$BASE" "$BASE" ""
  [[ "$output" == *"docs_only=false"* ]]
}

@test "rename de src/ para docs/ conta como código" {
  git mv src/app.js docs/app.md; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]]
}

@test "arquivo de código apagado: docs_only=false" {
  git rm -q src/app.js; echo b >> docs/guia.md; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]]
}

@test "base inexistente: falha (não imprime true)" {
  echo b >> docs/guia.md; commit
  run bash "$SCRIPT" "$REPO" "0000000000000000000000000000000000000001" "$HEAD_SHA" ""
  [ "$status" -ne 0 ]
  [[ "$output" != *"docs_only=true"* ]]
}

@test "entradas extras vazias são ignoradas" {
  echo y >> src/app.js; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ",,"
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]]
}

@test "nome de arquivo com quebra de linha é lido inteiro (docs/a<NL>b.js é docs)" {
  echo z > "$(printf 'docs/a\nb.js')"; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=true"* ]]
}
