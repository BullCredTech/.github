#!/usr/bin/env bash
# Pacotes npm privados no AWS CodeArtifact. O check de licença instala as dependências para ler as
# licenças; sem token, o registry responde 401 e cada projeto reprova como "dependências não verificáveis".
#
# Uso:
#   codeartifact.sh detect <raiz>  -> stdout para o $GITHUB_OUTPUT: needed=true|false e, se true,
#                                     domain=, owner=, region=, repositories= (separados por espaço)
#   codeartifact.sh login          -> grava o token em ~/.npmrc (lê DOMAIN, OWNER, REGION e REPOSITORIES
#                                     do ambiente) e zera as credenciais AWS para os passos seguintes
#
# O endpoint vem dos lockfiles e dos .npmrc/.yarnrc do repo (fora de node_modules e de .org-security) e
# precisa casar com a regex estrita abaixo, então nada do repo chega ao workflow sem validação. Todos os
# endpoints têm de ser do mesmo domínio, conta e região (uma role só); mais de um => exit 2.
# A role assumida é a GitHubActionsCodeArtifactReadRole da conta dona do domínio, que só lê o repositório.
set -euo pipefail

RE='https://([a-z][a-z0-9-]{0,48}[a-z0-9])-([0-9]{12})\.d\.codeartifact\.([a-z]{2}-[a-z]+-[0-9])\.amazonaws\.com/npm/([A-Za-z0-9][A-Za-z0-9._-]{1,99})/'
cmd="${1:-}"

if [ "$cmd" = detect ]; then
  root="${2:?uso: codeartifact.sh detect <raiz>}"
  urls="$(find "$root" \( -name node_modules -o -name .org-security -o -name .git \) -prune -o -type f \
      \( -name .npmrc -o -name .yarnrc -o -name package-lock.json -o -name npm-shrinkwrap.json -o -name yarn.lock \) \
      -print0 | xargs -0 -r grep -ohE "$RE" 2>/dev/null | sort -u || true)"
  if [ -z "$urls" ]; then
    echo "needed=false"
    exit 0
  fi
  contas=""
  repos=()
  while IFS= read -r u; do
    [[ "$u" =~ ^$RE$ ]] || { echo "::error::endpoint do CodeArtifact fora do formato esperado" >&2; exit 2; }
    contas="$contas
${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
    repos+=("${BASH_REMATCH[4]}")
  done <<< "$urls"
  contas="$(printf '%s\n' "$contas" | grep . | sort -u)"
  if [ "$(printf '%s\n' "$contas" | wc -l | tr -d ' ')" != 1 ]; then
    echo "::error::o repo aponta para mais de um domínio, conta ou região do CodeArtifact; o check só autentica em um" >&2
    exit 2
  fi
  read -r domain owner region <<< "$contas"
  echo "needed=true"
  echo "domain=$domain"
  echo "owner=$owner"
  echo "region=$region"
  echo "repositories=$(printf '%s\n' "${repos[@]}" | sort -u | paste -sd ' ' -)"
  exit 0
fi

if [ "$cmd" = login ]; then
  : "${DOMAIN:?}" "${OWNER:?}" "${REGION:?}" "${REPOSITORIES:?}"
  # Os valores vêm do detect, mas a validação se repete aqui: este passo escreve em ~/.npmrc.
  [[ "https://$DOMAIN-$OWNER.d.codeartifact.$REGION.amazonaws.com/npm/x0/" =~ ^$RE$ ]] \
    || { echo "::error::DOMAIN, OWNER ou REGION fora do formato esperado" >&2; exit 2; }
  token="$(aws codeartifact get-authorization-token --domain "$DOMAIN" --domain-owner "$OWNER" \
    --region "$REGION" --duration-seconds 0 --query authorizationToken --output text)"
  echo "::add-mask::$token"
  host="$DOMAIN-$OWNER.d.codeartifact.$REGION.amazonaws.com"
  read -r -a lista <<< "$REPOSITORIES"
  for r in "${lista[@]}"; do
    [[ "https://$host/npm/$r/" =~ ^$RE$ ]] || { echo "::error::repositório fora do formato esperado" >&2; exit 2; }
    # ~/.npmrc, nunca o .npmrc do repo: o npm e o yarn v1 leem a credencial daqui pelo prefixo da URL.
    printf '//%s/npm/%s/:always-auth=true\n//%s/npm/%s/:_authToken=%s\n' "$host" "$r" "$host" "$r" "$token" >> "$HOME/.npmrc"
  done
  # O token já está no ~/.npmrc. As credenciais da role não servem a mais nada: zera para os passos seguintes.
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'AWS_ACCESS_KEY_ID=\nAWS_SECRET_ACCESS_KEY=\nAWS_SESSION_TOKEN=\n' >> "$GITHUB_ENV"
  fi
  echo "token do CodeArtifact gravado em ~/.npmrc para: $REPOSITORIES"
  exit 0
fi

echo "uso: codeartifact.sh detect <raiz> | login" >&2
exit 2
