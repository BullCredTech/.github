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

# --- endurecimento ---

falha() { # $1 = trecho esperado na mensagem (opcional)
  [ "$status" -eq 2 ]
  [ -z "$1" ] || [[ "$output" == *"$1"* ]]
}

@test "erro vai só para stderr (stdout vazio)" {
  printf 'version: 2\n' > "$REPO/.github/security-checks.yml"
  out=$(bash "$SCRIPT" "$REPO" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ -z "$out" ]
}

@test "quebra de linha em docs_paths falha" {
  printf 'version: 1\ndocs_paths: ["a\\nb=c"]\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha "controle"
}
@test "quebra de linha em license.extra_allowed falha" {
  printf 'version: 1\nlicense:\n  extra_allowed: ["MIT\\nskip=trivy"]\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha "controle"
}
@test "quebra de linha em skip[].check falha" {
  printf 'version: 1\nskip:\n  - check: "trivy\\nx=1"\n    reason: "motivo bem longo"\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha "controle"
}
@test "caractere de controle em chave falha" {
  printf 'version: 1\n"a\\nb": 1\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha ""
}

docs() { printf 'version: 1\ndocs_paths: [%s]\n' "$1" > "$REPO/.github/security-checks.yml"; }
@test "docs_paths catch-all ou inválido falha" {
  for e in '"**"' '"*"' '"**/*"' '"*/**"' '""' '"../x"' '"/abs"' '"a,b"' '"a/../b"'; do
    docs "$e"
    run bash "$SCRIPT" "$REPO"
    [ "$status" -eq 2 ] || { echo "passou: $e"; return 1; }
  done
}
@test "docs_paths handbook/** passa" {
  docs '"handbook/**"'
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs_paths=handbook/**"* ]]
}

@test "tipos errados falham" {
  for c in \
    'semgrep: {extra_configs: "p/python"}' \
    'semgrep: {extra_configs: {a: b}}' \
    'docs_paths: "docs/**"' \
    'docs_paths: [1]' \
    'license: foo' \
    'semgrep: foo' \
    'license: {extra_allowed: "MIT"}' \
    'skip: foo' \
    'skip: [foo]' \
    'skip: [{check: trivy, reason: "motivo bem longo", foo: 1}]' \
    'skip: [{check: trivy, reason: 12345678901234}]'; do
    printf 'version: 1\n%s\n' "$c" > "$REPO/.github/security-checks.yml"
    run bash "$SCRIPT" "$REPO"
    [ "$status" -eq 2 ] || { echo "passou: $c"; return 1; }
  done
}
@test "raiz que não é mapa falha" {
  printf -- '- a\n- b\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha ""
}
@test "alias YAML: valor correto ou falha limpa, nunca vazio silencioso" {
  cat > "$REPO/.github/security-checks.yml" <<'EOT'
version: 1
docs_paths: &d ["handbook/**"]
license:
  extra_allowed: ["CC-BY-4.0"]
semgrep:
  extra_configs: ["p/python"]
EOT
  run bash "$SCRIPT" "$REPO"
  if [ "$status" -eq 0 ]; then [[ "$output" == *"docs_paths=handbook/**"* ]]; else [ "$status" -eq 2 ]; fi
  cat > "$REPO/.github/security-checks.yml" <<'EOT'
version: 1
docs_paths: ["handbook/**"]
license:
  extra_allowed: &d ["CC-BY-4.0"]
semgrep:
  extra_configs: *d
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 2 ]
}

@test "reason em branco ou curto falha" {
  for r in '"   "' '"curto"' '"  curto   "'; do
    printf 'version: 1\nskip:\n  - check: trivy\n    reason: %s\n' "$r" > "$REPO/.github/security-checks.yml"
    run bash "$SCRIPT" "$REPO"
    [ "$status" -eq 2 ] || { echo "passou: $r"; return 1; }
  done
}

@test "semgrep extra_configs com .., barra final ou longo demais falha" {
  long="p/$(printf 'a%.0s' $(seq 1 100))"
  for e in '"p/../x"' '"r/"' '"p/x/"' "\"$long\""; do
    printf 'version: 1\nsemgrep:\n  extra_configs: [%s]\n' "$e" > "$REPO/.github/security-checks.yml"
    run bash "$SCRIPT" "$REPO"
    [ "$status" -eq 2 ] || { echo "passou: $e"; return 1; }
  done
}

@test "version string \"1\" falha" {
  printf 'version: "1"\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha "version"
}

@test "license.extra_allowed inválidos falham, válidos passam" {
  for e in '"MIT;GPL-3.0"' '"*"' '""' '"A,B"' '"a b"'; do
    printf 'version: 1\nlicense:\n  extra_allowed: [%s]\n' "$e" > "$REPO/.github/security-checks.yml"
    run bash "$SCRIPT" "$REPO"
    [ "$status" -eq 2 ] || { echo "passou: $e"; return 1; }
  done
  printf 'version: 1\nlicense:\n  extra_allowed: ["CC-BY-4.0", "LicenseRef-Bull-1", "GPL-2.0+"]\n' > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"license_extra=CC-BY-4.0;LicenseRef-Bull-1;GPL-2.0+"* ]]
}

@test "skip duplicado é deduplicado" {
  cfg <<'EOT'
version: 1
skip:
  - {check: trivy, reason: "motivo bem longo"}
  - {check: trivy, reason: "outro motivo longo"}
  - {check: license, reason: "motivo bem longo"}
EOT
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip=license,trivy"* ]]
}

@test "arquivo symlink falha" {
  printf 'version: 1\n' > "$REPO/real.yml"
  ln -s "$REPO/real.yml" "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha "symlink"
}

@test "arquivo vazio falha" {
  : > "$REPO/.github/security-checks.yml"
  run bash "$SCRIPT" "$REPO"; falha "vazio"
}

@test "funciona em qualquer raiz (diretório temporário fora de repo)" {
  d="$(mktemp -d)"; mkdir "$d/.github"; printf 'version: 1\n' > "$d/.github/security-checks.yml"
  run bash "$SCRIPT" "$d"; rm -rf "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config_present=true"* ]]
}
