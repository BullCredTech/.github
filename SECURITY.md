# Política de Segurança

A BullCredTech leva segurança a sério. Esta política descreve como reportar vulnerabilidades e o que esperar do nosso processo de resposta.

## Reportando uma vulnerabilidade

**Não abra issue pública** para vulnerabilidades de segurança. Reporte de forma privada via um dos canais abaixo:

- E-mail: **security@bullcredtech.com**
- GitHub Security Advisories: abra um advisory privado no repositório afetado (`Security` → `Report a vulnerability`)

Por favor, inclua o máximo possível das seguintes informações:

- Tipo de vulnerabilidade (ex.: SQL injection, XSS, RCE, exposição de PII)
- Caminho/URL/endpoint afetado
- Passo a passo para reproduzir
- Impacto potencial
- Sugestão de mitigação (opcional)

## Nosso compromisso

- **Acknowledge em até 2 dias úteis** após o report.
- **Avaliação inicial em até 5 dias úteis** com classificação de severidade (CVSS).
- **Plano de correção comunicado em até 10 dias úteis** para issues de severidade média ou superior.
- **Disclosure coordenado**: combinaremos com o reporter a janela de divulgação pública após o fix estar em produção.

## Escopo

A política cobre todos os repositórios da organização BullCredTech, incluindo APIs, aplicações web, lambdas, scripts ops e infraestrutura como código.

## Práticas de segurança em desenvolvimento

A organização adota **Security by Design** como princípio não-negociável:

- Zero vulnerabilidades toleradas em dependências (gates de CI: `npm audit`, `Trivy`, `Semgrep`, `CodeQL`).
- Pre-commit hook `gitleaks` em repos com infraestrutura sensível.
- Defense in depth: validação de input, autenticação/autorização, sanitização de logs, mínimo privilégio.
- Falha fechada: em dúvida, nega.
- PII em logs sempre mascarada.

Detalhes técnicos vivem em `docs/SECURITY.md` de cada repositório aplicável.

## Reconhecimento

Reporters de vulnerabilidades confirmadas são reconhecidos publicamente (com autorização) após o disclosure coordenado.
