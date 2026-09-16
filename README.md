# ToggleMaster — Tech Challenge (Fases 2 & 3)

**Participante:** Paulo Ricardo

Plataforma de feature flags com 5 microsserviços: `auth-service`,
`flag-service`, `targeting-service`, `evaluation-service`,
`analytics-service`.

- **Fase 2** (arquitetura de microsserviços, Docker Compose, Kubernetes
  manual): código dos serviços em `*-service/`, manifests legados em
  `kubernetes/`.
- **Fase 3** (IaC, CI/CD, DevSecOps, GitOps — este desafio): ver abaixo.

## O que a Fase 3 adicionou

| Requisito | Onde |
|---|---|
| Infraestrutura como código (Terraform) | [`terraform/`](terraform/README.md) |
| Pipeline de CI + DevSecOps (SAST/SCA, build/push ECR) | [`.github/workflows/`](.github/workflows/) |
| GitOps (manifests versionados) | [`gitops/`](gitops/README.md) |
| ArgoCD | instalado pelo Terraform (`terraform/modules/argocd`) e configurado em `gitops/argocd-apps/` |
| Relatório de entrega | [`docs/RELATORIO_ENTREGA.md`](docs/RELATORIO_ENTREGA.md) |

## Fluxo ponta a ponta

```
dev push/PR → GitHub Actions (build/test → lint → SAST/SCA → docker build+scan → push ECR)
                                                            │
                                                            ▼
                                        commit automático em gitops/apps/<service>/deployment.yaml
                                                            │
                                                            ▼
                                          ArgoCD detecta a mudança e sincroniza no EKS
```

Veja `terraform/README.md` para o passo a passo de provisionamento e
`gitops/README.md` para como o deploy funciona no dia a dia.

## Secrets e variáveis do GitHub Actions

Configurar em *Settings → Secrets and variables → Actions* do repositório:

**Aba Secrets:**

| Secret | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID` | credenciais de um usuário/role com permissão de push no ECR |
| `AWS_SECRET_ACCESS_KEY` | idem |
| `AWS_REGION` | `us-east-1` |

**Aba Variables:**

| Variável | Valor |
|---|---|
| `AWS_ACCOUNT_ID` | ID da conta AWS (usado para montar a URL do ECR sem depender de saída derivada de credenciais entre jobs, que o GitHub Actions zera ao cruzar a fronteira de job) |

O `GITHUB_TOKEN` padrão já é suficiente para o job `update-gitops` (commit
automático em `gitops/apps/<service>/deployment.yaml`), desde que o
repositório permita "Read and write permissions" em *Settings → Actions →
General → Workflow permissions*.
