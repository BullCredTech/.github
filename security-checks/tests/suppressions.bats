#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/suppressions.sh"

setup() {
  REPO="$(mktemp -d)"; cd "$REPO"
  git init -q -b main; git config user.email t@t; git config user.name t
  printf 'a\nlegado = "x"  # nosemgrep: old\nb\n' > app.py; git add -A; git commit -qm base
  BASE=$(git rev-parse HEAD)
  export GITHUB_STEP_SUMMARY="$REPO/.summary"; : > "$GITHUB_STEP_SUMMARY"
}
teardown() { rm -rf "$REPO"; }
commit() { git add -A; git commit -qm c; HEAD_SHA=$(git rev-parse HEAD); }

@test "supressão adicionada é listada com arquivo e linha e vira annotation" {
  printf 'a\nlegado = "x"  # nosemgrep: old\nb\nsegredo = "y"  # gitleaks:allow\nz = 1  # NoSemgrep\n' > app.py
  printf 'iac  # trivy:ignore:AVD-1\n' > main.tf
  commit
  run bash "$SCRIPT" "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning file=app.py,line=4::"* ]] || return 1
  [[ "$output" == *"::warning file=app.py,line=5::"* ]] || return 1
  [[ "$output" == *"::warning file=main.tf,line=1::"* ]] || return 1
  grep -q 'supressões adicionadas neste PR' "$GITHUB_STEP_SUMMARY"
  grep -q 'app.py:4' "$GITHUB_STEP_SUMMARY"
}

@test "supressão que já existia na base não é reportada" {
  echo "c" >> app.py
  commit
  run bash "$SCRIPT" "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning"* ]] || return 1
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "nome de arquivo com quebra de linha e caracteres especiais não quebra a annotation" {
  f="$(printf 'x\n::error::pwn,%%.py')"
  printf 'v = 1  # gitleaks:allow\n' > "$f"
  commit
  run bash "$SCRIPT" "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^::warning')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^::error')" -eq 0 ]
}

@test "nunca falha: SHA inválido ou base inexistente só avisa" {
  run bash "$SCRIPT" "main" "--output=x"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" "0000000000000000000000000000000000000001" "0000000000000000000000000000000000000002"
  [ "$status" -eq 0 ]
  [ ! -e x ]
}

@test "mudança sem supressão não gera nada" {
  echo "d = 4" >> app.py; commit
  run bash "$SCRIPT" "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "linha adicionada que começa com ++ não escapa da detecção" {
  printf '++ x  # gitleaks:allow\n-- y  # nosemgrep\n' > notas.txt
  commit
  run bash "$SCRIPT" "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | /usr/bin/grep -c '^::warning file=notas.txt')" -eq 2 ]
}
