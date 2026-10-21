#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/reserved.sh"

setup() {
  REPO="$(mktemp -d)"; cd "$REPO"
  git init -q -b main; git config user.email t@t; git config user.name t
  echo base > README.md; git add -A; git commit -qm base
}
teardown() { rm -rf "$REPO"; }

@test "repo limpo passa em silencio" {
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "arquivo rastreado em .org-security reprova" {
  mkdir .org-security; echo 'x' > .org-security/x.js; git add -A; git commit -qm c
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]] || return 1
  [[ "$output" == *".org-security"* ]] || return 1
}

@test "arquivo rastreado mesmo com a arvore de trabalho limpa (como o passo de limpeza deixa)" {
  mkdir .org-security; echo 'x' > .org-security/x.js; git add -A; git commit -qm c
  rm -rf .org-security
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
}

@test "symlink chamado .org-security reprova" {
  ln -s README.md .org-security; git add -A; git commit -qm c
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
}

@test "gitlink (submodulo) em .org-security reprova" {
  git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),.org-security"
  git commit -qm c
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
}

@test "diretorio .org-security so no working tree, sem nada no HEAD, passa" {
  mkdir .org-security; echo 'x' > .org-security/x.js
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "nome parecido (.org-security-x e org-security) nao e reservado" {
  mkdir .org-security-x org-security; echo a > .org-security-x/a; echo b > org-security/b; git add -A; git commit -qm c
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
}

@test "usa o diretorio do repo informado, nao o atual" {
  mkdir .org-security; echo 'x' > .org-security/x.js; git add -A; git commit -qm c
  cd /
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
}

@test "diretorio que nao e repo git falha fechado" {
  d="$(mktemp -d)"; cd /
  run bash "$SCRIPT" "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}
