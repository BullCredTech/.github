# BullCredTech

Fintech brasileira focada em **crédito consignado privado** (private payroll-deducted credit). Operamos toda a jornada de originação digital — da simulação ao desembolso — integrando análise de crédito, KYC, assinatura eletrônica e fundings parceiros.

## Stack principal

- **Backend:** NestJS + TypeScript + PostgreSQL (TypeORM)
- **Frontend:** React + monorepo (Turborepo)
- **Infra:** AWS (ECS, Lambda, API Gateway, SQS, RDS)
- **Integrações:** Celcoin, Unico, Dataprev, PoD (motor de crédito), Zenvia

## Repositórios principais

| Repo | Propósito |
|---|---|
| `bull-api-proposals` | API de propostas de crédito (core) |
| `bull-web-platform` | Monorepo de apps web (cliente, b2b, promotor) |
| `bull-lambda-webhooks-receiver` | Receptor de webhooks externos |
| `bull-lambda-webhook-sender` | Disparador de webhooks para parceiros |

## Boas práticas

Este repo (`.github`) hospeda os **community health files** que se aplicam por default a todos os repositórios da organização:

- [Code of Conduct](./CODE_OF_CONDUCT.md)
- [Contributing](./CONTRIBUTING.md)
- [Security Policy](./SECURITY.md)
- [Support](./SUPPORT.md)
- Templates de PR e issue (em `.github/`)

Repositórios podem sobrescrever qualquer um desses arquivos colocando uma versão local.
