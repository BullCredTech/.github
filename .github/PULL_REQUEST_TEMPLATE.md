## Summary

<!-- 1-3 bullets descrevendo o QUE muda e POR QUE -->

-
-

## Test plan

<!-- Checklist do que foi testado. Marque cada item ANTES do merge. -->

- [ ]
- [ ]

## Tipo de mudança

- [ ] `feat` — nova funcionalidade
- [ ] `fix` — correção de bug
- [ ] `refactor` — refatoração sem mudança de comportamento
- [ ] `chore` — tarefa operacional / build / deps
- [ ] `docs` — documentação apenas
- [ ] `hotfix` — correção urgente em produção

## Changelog

<!--
Campos lidos pelo changelog tech (docs/CHANGELOG_TECH.md no repo BullCredTech/.github).
Deixe em branco o que não se aplica, mas mantenha cada campo na sua linha.
- Changelog: uma frase para o time interno sobre o que muda. Em branco, o digest usa o resumo do classificador ou o título.
- Parceiro: frase para o parceiro. Só quando a label for partner:additive ou partner:breaking.
- Flag: chave da feature flag que liga a mudança (formato api.<nome>). Obrigatório com partner:breaking.
- Docs: link do PR em BullCredTech/bull-api-docs-gitbook. Obrigatório com partner:breaking.
As labels cl:* (tipo) e partner:* (impacto no parceiro) vêm do classificador ou de quem abre o PR.
O check changelog-gate exige uma de cada e, com partner:breaking, Flag e Docs. A revisão normal do PR aprova; o parceiro só fica sabendo quando alguém Anunciar no BMS.
-->

Changelog:
Parceiro:
Flag:
Docs:

## Checklist

- [ ] Build / lint / testes passam localmente
- [ ] Adicionou/atualizou testes para a mudança
- [ ] Variáveis novas estão em `.env.example` (se aplicável)
- [ ] Documentação atualizada (`docs/` / `README` / `CLAUDE.md`) se a mudança afeta comportamento, schema ou contrato de API
- [ ] PII / segredos não estão em logs novos
