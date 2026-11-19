#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/codeartifact.sh"
URL1='https://minhaorg-123456789012.d.codeartifact.us-east-1.amazonaws.com/npm/npm/'

setup() { REPO="$(mktemp -d)"; }
teardown() { rm -rf "$REPO"; }

@test "repo sem CodeArtifact: needed=false" {
  echo '{"lockfileVersion":3}' > "$REPO/package-lock.json"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]; [ "$output" = "needed=false" ]
}

@test "yarn.lock com pacote do CodeArtifact: dominio, conta, regiao e repositorio" {
  printf '"@x/sdk@^0.1.0":\n  resolved "%s@x/sdk/-/sdk-0.1.0.tgz#abc"\n' "$URL1" > "$REPO/yarn.lock"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"needed=true"* ]] || return 1
  [[ "$output" == *"domain=minhaorg"* ]] || return 1
  [[ "$output" == *"owner=123456789012"* ]] || return 1
  [[ "$output" == *"region=us-east-1"* ]] || return 1
  [[ "$output" == *"repositories=npm"* ]] || return 1
}

@test ".npmrc num subdiretorio tambem conta" {
  mkdir -p "$REPO/apis/x"; echo "@x:registry=$URL1" > "$REPO/apis/x/.npmrc"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]; [[ "$output" == *"needed=true"* ]] || return 1
}

@test "node_modules e .org-security sao ignorados" {
  mkdir -p "$REPO/node_modules/a" "$REPO/.org-security"
  echo "resolved \"$URL1\"" > "$REPO/node_modules/a/yarn.lock"
  echo "resolved \"$URL1\"" > "$REPO/.org-security/yarn.lock"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]; [ "$output" = "needed=false" ]
}

@test "dois repositorios do mesmo dominio saem juntos" {
  printf 'resolved "%s"\nresolved "%s"\n' "$URL1" 'https://minhaorg-123456789012.d.codeartifact.us-east-1.amazonaws.com/npm/outro/' > "$REPO/yarn.lock"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]; [[ "$output" == *"repositories=npm outro"* ]] || return 1
}

@test "dois dominios ou contas diferentes falham fechado" {
  printf 'resolved "%s"\nresolved "%s"\n' "$URL1" "${URL1/123456789012/210987654321}" > "$REPO/yarn.lock"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 2 ]
}

@test "endpoint com caracteres fora do formato nao vira saida" {
  echo 'resolved "https://a$(id)-123456789012.d.codeartifact.us-east-1.amazonaws.com/npm/npm/"' > "$REPO/yarn.lock"
  run bash "$SCRIPT" detect "$REPO"
  [ "$status" -eq 0 ]; [ "$output" = "needed=false" ]
}

@test "login recusa valores fora do formato antes de chamar a AWS" {
  run env DOMAIN='x;rm' OWNER=123456789012 REGION=us-east-1 REPOSITORIES=npm bash "$SCRIPT" login
  [ "$status" -eq 2 ]
}

@test "comando desconhecido falha" {
  run bash "$SCRIPT" outro
  [ "$status" -eq 2 ]
}
