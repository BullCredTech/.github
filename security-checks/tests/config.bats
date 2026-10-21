#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../scripts/config.sh"

setup() { REPO="$(mktemp -d)"; mkdir -p "$REPO/.github"; }
teardown() { rm -rf "$REPO"; }
cfg() { cat > "$REPO/.github/security-checks.yml"; }

@test "sem arquivo: tudo vazio e config_present=false" {
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config_present=false"* ]]
  [[ "$output" == *"skip="* ]]
}

@test "arquivo válido: emite listas" {
  cfg <<'EOT'
version: 1
docs_paths: ["handbook/**", "notes/**"]
license:
  extra_allowed: ["CC-BY-4.0", "MPL-2.0"]
semgrep:
  extra_configs: ["p/python"]
skip:
  - check: trivy
    reason: "Repo só de documentação"
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config_present=true"* ]]
  [[ "$output" == *"docs_paths=handbook/**,notes/**"* ]]
  [[ "$output" == *"license_extra=CC-BY-4.0;MPL-2.0"* ]]
  [[ "$output" == *"semgrep_extra=--config p/python"* ]]
  [[ "$output" == *"skip=trivy"* ]]
}

@test "versão diferente de 1 falha" {
  cfg <<'EOT'
version: 2
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"version"* ]]
}

@test "chave desconhecida falha" {
  cfg <<'EOT'
version: 1
desligar_tudo: true
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"desligar_tudo"* ]]
}

@test "skip sem reason falha" {
  cfg <<'EOT'
version: 1
skip:
  - check: semgrep
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"reason"* ]]
}

@test "skip do gitleaks não é permitido" {
  cfg <<'EOT'
version: 1
skip:
  - check: gitleaks
    reason: "não quero"
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"gitleaks"* ]]
}

@test "regra extra do semgrep fora do formato p/ ou r/ falha" {
  cfg <<'EOT'
version: 1
semgrep:
  extra_configs: ["--metrics=off"]
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"extra_configs"* ]]
}

@test "YAML inválido falha" {
  printf 'version: [1\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
}
