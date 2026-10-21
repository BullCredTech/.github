#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/base-configs.sh"

setup() {
  REPO="$(mktemp -d)"; cd "$REPO"
  git init -q -b main; git config user.email t@t; git config user.name t
  echo base > README.md
}
teardown() { rm -rf "$REPO"; }
commit() { git add -A; git commit -qm c; git rev-parse HEAD; }

@test "restaura da base o que existe e remove o que a base não tem" {
  echo A > .gitleaksignore
  BASE=$(commit)
  echo B > .gitleaksignore; echo "x" > .trivyignore; echo "y" > .gitleaks.toml
  commit >/dev/null
  run bash "$SCRIPT" "$BASE"
  [ "$status" -eq 0 ]
  [ "$(cat .gitleaksignore)" = A ]
  [ ! -e .trivyignore ]
  [ ! -e .gitleaks.toml ]
}

@test "cobre todos os arquivos de configuração das ferramentas" {
  for f in .gitleaks.toml .gitleaksignore .semgrepignore .semgrep.yml .trivyignore trivy.yaml trivy-secret.yaml .trivyignore.yaml; do echo base > "$f"; done
  BASE=$(commit)
  for f in .gitleaks.toml .gitleaksignore .semgrepignore .semgrep.yml .trivyignore trivy.yaml trivy-secret.yaml .trivyignore.yaml; do echo pr > "$f"; done
  commit >/dev/null
  run bash "$SCRIPT" "$BASE"
  [ "$status" -eq 0 ]
  for f in .gitleaks.toml .gitleaksignore .semgrepignore .semgrep.yml .trivyignore trivy.yaml trivy-secret.yaml .trivyignore.yaml; do
    [ "$(cat "$f")" = base ] || { echo "não restaurou $f"; return 1; }
  done
}

@test "arquivo que é symlink no PR vira arquivo regular da base e o alvo não é tocado" {
  echo A > .gitleaksignore
  BASE=$(commit)
  echo alvo > "$REPO/alvo.txt"; rm .gitleaksignore; ln -s alvo.txt .gitleaksignore
  commit >/dev/null
  run bash "$SCRIPT" "$BASE"
  [ "$status" -eq 0 ]
  [ ! -L .gitleaksignore ]
  [ "$(cat .gitleaksignore)" = A ]
  [ "$(cat alvo.txt)" = alvo ]
}

@test "diretório com o nome do arquivo é removido quando a base não tem" {
  BASE=$(commit)
  mkdir .trivyignore; echo x > .trivyignore/y
  commit >/dev/null
  run bash "$SCRIPT" "$BASE"
  [ "$status" -eq 0 ]
  [ ! -e .trivyignore ]
}

@test "recusa SHA que não é hexadecimal" {
  echo A > .gitleaksignore
  BASE=$(commit); echo B > .gitleaksignore
  for s in "" "main" "--help" "$BASE;id" "ABCDEF0123456789ABCDEF0123456789ABCDEF01" "abc123"; do
    run bash "$SCRIPT" "$s"
    [ "$status" -ne 0 ] || { echo "passou: '$s'"; return 1; }
  done
  [ "$(cat .gitleaksignore)" = B ]
}

@test "SHA inexistente falha sem apagar nada" {
  echo A > .gitleaksignore
  commit >/dev/null; echo B > .gitleaksignore
  run bash "$SCRIPT" "$(printf '%040d' 1)"
  [ "$status" -ne 0 ]
  [ "$(cat .gitleaksignore)" = B ]
}

@test "aceita um diretório de repositório como segundo argumento" {
  echo A > .gitleaksignore
  BASE=$(commit); echo B > .gitleaksignore
  cd /
  run bash "$SCRIPT" "$BASE" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/.gitleaksignore")" = A ]
}
