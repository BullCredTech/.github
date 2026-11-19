#!/usr/bin/env bash
# Cria ou atualiza o comentário do Infracost no PR (um só, reconhecido pelo marcador).
# Uso: comment.sh <comment.md> <has_projects: true|false>
# Variáveis: GH_TOKEN, REPO (owner/repo), PR (número).
# Sem workspace afetado e sem comentário anterior, não comenta (PR sem IaC fica limpo).
set -euo pipefail

body="${1:?}"
has_projects="${2:?}"
: "${GH_TOKEN:?}" "${REPO:?}" "${PR:?}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "::error::REPO inválido"; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "::error::PR inválido"; exit 2; }

marker='<!-- bull-infracost -->'
id="$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" | tail -n 1)"

if [ -n "$id" ]; then
  gh api -X PATCH "repos/$REPO/issues/comments/$id" -F "body=@$body" --silent
  echo "Comentário $id atualizado."
elif [ "$has_projects" = "true" ]; then
  gh api -X POST "repos/$REPO/issues/$PR/comments" -F "body=@$body" --silent
  echo "Comentário criado."
else
  echo "Nenhum workspace afetado e nenhum comentário anterior: nada a comentar."
fi
