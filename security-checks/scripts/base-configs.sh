#!/usr/bin/env bash
# Restaura da branch de DESTINO os arquivos de configuração/ignore das ferramentas de segurança.
# Uso: base-configs.sh <base-sha> [diretório-do-repo (padrão: .)]
# Para cada arquivo: se existe na base, o conteúdo da base substitui o do PR; se não existe, é removido.
# Assim um PR não relaxa os próprios checks (ex.: .gitleaksignore, .trivyignore); a mudança vale
# depois do merge, revisada pelo CODEOWNERS.
set -euo pipefail

sha="${1:-}"; repo="${2:-.}"
[[ "$sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { echo "::error::SHA da base ausente ou inválido" >&2; exit 2; }
# Falha fechado: sem o commit da base, não apaga nada (senão "sem arquivo na base" seria só um objeto faltando).
git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "::error::commit da base não está no clone (fetch-depth: 0?)" >&2; exit 1; }

arquivos=(.gitleaks.toml .gitleaksignore .semgrepignore .semgrep.yml .trivyignore trivy.yaml trivy-secret.yaml .trivyignore.yaml)
for f in "${arquivos[@]}"; do
  rm -rf -- "${repo:?}/$f"   # arquivo, symlink (não escreve através dele) ou diretório do PR
  if [ "$(git -C "$repo" cat-file -t "$sha:$f" 2>/dev/null || true)" = blob ]; then
    git -C "$repo" show "$sha:$f" > "$repo/$f"
    echo "restaurado da base: $f"
  fi
done
