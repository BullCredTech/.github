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
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=true"* ]] || return 1
}

@test "código: docs_only=false" {
  echo y >> src/app.js; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "docs e código juntos: docs_only=false" {
  echo b >> docs/guia.md; echo y >> src/app.js; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "padrão extra do repo conta como docs" {
  mkdir -p handbook; echo z > handbook/x.txt; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" "handbook/**"
  [[ "$output" == *"docs_only=true"* ]] || return 1
}

@test "utils não é docs" {
  mkdir -p utils; echo z > utils/run.sh; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "sem mudança: docs_only=false (escaneia)" {
  run bash "$SCRIPT" "$REPO" "$BASE" "$BASE" ""
  [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "rename de src/ para docs/ conta como código" {
  git mv src/app.js docs/app.md; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "arquivo de código apagado: docs_only=false" {
  git rm -q src/app.js; echo b >> docs/guia.md; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "base inexistente: falha (não imprime true)" {
  echo b >> docs/guia.md; commit
  run bash "$SCRIPT" "$REPO" "0000000000000000000000000000000000000001" "$HEAD_SHA" ""
  [ "$status" -ne 0 ]
  [[ "$output" != *"docs_only=true"* ]] || return 1
}

@test "entradas extras vazias são ignoradas" {
  echo y >> src/app.js; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ",,"
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "nome de arquivo com quebra de linha é lido inteiro (docs/a<NL>b.md é docs)" {
  echo z > "$(printf 'docs/a\nb.md')"; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=true"* ]] || return 1
}

# --- extensão de documentação, gitlink, validação de SHA ---

@test "docs/ com arquivo que não é documentação: false" {
  for f in code.js package.json Dockerfile requirements.txt Requirements-dev.TXT constraints.txt app.mdx; do
    git reset -q --hard "$BASE"; mkdir -p docs src
    echo z > "docs/$f"; commit
    run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"docs_only=false"* ]] || { echo "deu true: docs/$f"; return 1; }
  done
}

@test "gitlink (submódulo) em docs/ conta como código" {
  git update-index --add --cacheinfo 160000,"$BASE",docs/sub
  git commit -qm sub; HEAD_SHA=$(git rev-parse HEAD)
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "extensões de documentação em docs/ e .md em qualquer lugar: true" {
  for f in docs/diagram.svg docs/guide.adoc docs/README.MD docs/a.PNG src/notes.md; do
    git reset -q --hard "$BASE"; mkdir -p docs src
    echo z > "$f"; commit
    run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"docs_only=true"* ]] || { echo "deu false: $f"; return 1; }
  done
}

@test "dir extra: handbook/x.txt true, handbook/x.py false" {
  mkdir -p handbook; echo z > handbook/x.txt; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" "handbook/**"
  [[ "$output" == *"docs_only=true"* ]] || return 1
  echo z > handbook/x.py; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" "handbook/**"
  [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "base inválida (opção do git) falha sem criar arquivo" {
  echo b >> docs/guia.md; commit
  run bash "$SCRIPT" "$REPO" "--output=$REPO/pwned" "$HEAD_SHA" ""
  [ "$status" -ne 0 ]
  [ ! -e "$REPO/pwned" ]
  run bash "$SCRIPT" "$REPO" "$BASE" "--output=$REPO/pwned" ""
  [ "$status" -ne 0 ]
  [ ! -e "$REPO/pwned" ]
}

@test "variação de requirements/constraints em docs/ é código" {
  echo z > docs/doc-requirements.txt; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]] || return 1
  git reset -q --hard "$BASE"; mkdir -p docs
  echo z > docs/My-Constraints.TXT; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [[ "$output" == *"docs_only=false"* ]] || return 1
}

@test "symlink docs/link.md conta como código" {
  ln -s ../src/app.js docs/link.md; commit
  run bash "$SCRIPT" "$REPO" "$BASE" "$HEAD_SHA" ""
  [ "$status" -eq 0 ]; [[ "$output" == *"docs_only=false"* ]] || return 1
}
