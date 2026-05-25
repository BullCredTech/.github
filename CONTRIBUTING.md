# Contribuindo

Obrigado por contribuir com os repositórios da BullCredTech. Este guia cobre as convenções gerais que se aplicam à organização. Cada repositório pode complementar com seu próprio `CONTRIBUTING.md` local.

## Fluxo geral

1. **Branch a partir da `main`** com nome semântico:
   - `feat/<descricao-curta>` para novas funcionalidades
   - `fix/<descricao-curta>` para correções
   - `chore/<descricao-curta>` para tarefas operacionais
   - `hotfix/<descricao-curta>` para correções urgentes em produção
2. **Commits seguem [Conventional Commits](https://www.conventionalcommits.org/)**: `feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, `test:`.
3. **Pull Request com descrição clara** — preencha o template (`Summary` + `Test plan`). Marque os checkboxes do test plan **antes do merge**.
4. **Review obrigatória** — todos os PRs em `main` exigem ao menos uma aprovação.
5. **Janelas restritas de merge** — PRs em `main` durante sextas-feiras, fins de semana, feriados nacionais e vésperas de feriado exigem aprovação explícita do owner do gate (ver workflow `weekend-holiday-merge-gate`).

## Padrões de código

- TypeScript strict, ESLint + Prettier configurados por repo.
- **Sempre** rode `lint`, `build` e `test` localmente antes de subir.
- Para repos backend (NestJS): siga SOLID, prefira composição a herança, valide inputs com `class-validator`.
- Para repos frontend: componentes funcionais, hooks, evite estado global desnecessário.

## Segurança

- Nunca commite segredos. Use `.env.example` para documentar variáveis necessárias.
- Pre-commit hook (gitleaks) está habilitado nos repos com infraestrutura sensível.
- Dependências: zero vulnerabilidades moderadas+. `npm audit` rodando em CI.
- Reports de vulnerabilidade: ver [SECURITY.md](./SECURITY.md).

## Testes

- Unit tests obrigatórios para nova lógica de negócio.
- Integration tests preferidos sobre mocks profundos (ex.: testes de DB devem hitar Postgres real).
- Cobertura mínima é definida por repo.

## Migrations de banco

Usar **somente** o CLI do TypeORM:

```bash
npm run migration:create -- src/database/migrations/<NomeDaMigration>
npm run migration:generate -- src/database/migrations/<NomeDaMigration>
```

Nunca crie arquivos de migration manualmente — o timestamp tem que ser auto-gerado.

## Dúvidas

- Code review e discussões técnicas: comentários no PR
- Bugs externos: abra issue usando o template `bug_report`
- Solicitação de feature: template `feature_request`
- Suporte interno: ver [SUPPORT.md](./SUPPORT.md)
