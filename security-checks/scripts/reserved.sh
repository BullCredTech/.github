#!/usr/bin/env bash
# `.org-security` é um caminho RESERVADO na raiz do repo: o workflow central de segurança faz o checkout dos
# próprios scripts nesse diretório (apagando antes qualquer coisa que o PR tenha ali) e o exclui dos scans.
# Se o PR rastreia algo com esse nome, o scan não cobriria esses arquivos: reprova, em vez de passar verde.
#
# Uso: reserved.sh [diretório-do-repo (padrão: .)]
# Olha a ÁRVORE DO COMMIT (git ls-tree HEAD), não a árvore de trabalho (que o passo de limpeza já esvaziou).
# Qualquer tipo de entrada conta: diretório, arquivo, symlink ou submódulo. Sai 0 em silêncio quando não há nada.
set -euo pipefail

repo="${1:-.}"
if ! saida="$(git -C "$repo" ls-tree HEAD -- .org-security 2>/dev/null)"; then
  echo "::error::não consegui ler a árvore do commit (git ls-tree falhou); o caminho reservado .org-security não pôde ser verificado" >&2
  exit 2
fi
if [ -n "$saida" ]; then
  echo "::error::o caminho .org-security é reservado pelo workflow central de segurança (org-security) e não pode existir no repositório; renomeie esse diretório/arquivo"
  exit 1
fi
