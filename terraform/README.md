# Terraform — ToggleMaster (Tech Challenge Fase 3)

Provisiona toda a infraestrutura AWS usada pelos 5 microsserviços do
ToggleMaster: VPC/subnets, cluster EKS + node group, 3 RDS PostgreSQL,
1 ElastiCache (Redis), 1 tabela DynamoDB, 1 fila SQS (+ DLQ), 5 repositórios
ECR e o ArgoCD instalado via Helm.

Conta usada: **pessoal** (não AWS Academy) — o Terraform cria as próprias
IAM Roles/Policies (cluster EKS, node group, IRSA da aplicação).

## Estrutura

```
terraform/
├── bootstrap/         # cria o bucket S3 do backend remoto (rodar 1x, com state local)
├── modules/
│   ├── networking/     # VPC, subnets públicas/privadas, IGW, NAT, route tables
│   ├── eks/             # cluster EKS, node group, IAM roles, OIDC provider (IRSA)
│   ├── rds/             # 3x RDS Postgres (auth/flag/targeting) + Secrets Manager
│   ├── elasticache/    # Redis (usado pelo evaluation-service)
│   ├── dynamodb/        # tabela ToggleMasterAnalytics
│   ├── sqs/              # fila evaluation-analytics + DLQ
│   ├── ecr/              # 5 repositórios de imagem
│   └── argocd/          # instala o ArgoCD (helm_release) no cluster
├── scripts/
│   ├── sync-secrets.sh          # materializa o Secret k8s a partir do Secrets Manager
│   └── bootstrap-argocd-apps.sh # aplica as Applications do ArgoCD (1x)
├── backend.tf, providers.tf, versions.tf, variables.tf, main.tf, outputs.tf
└── terraform.tfvars.example
```

## Passo a passo

```bash
# 1) Bootstrap do backend remoto (uma única vez)
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=<nome-globalmente-unico>"

# 2) Infraestrutura principal
cd ../
terraform init \
  -backend-config="bucket=<nome-do-bucket-do-passo-1>" \
  -backend-config="region=us-east-1"
terraform plan
terraform apply

# 3) Configurar kubectl
$(terraform output -raw eks_update_kubeconfig_command)

# 4) Popular o Secret real (nunca commitado em git)
./scripts/sync-secrets.sh

# 5) Registrar as Applications do ArgoCD
./scripts/bootstrap-argocd-apps.sh

# 6) Conta comum (use_lab_role = false): ajustar o ARN do IRSA em
#    gitops/base/namespace.yaml. Em ambos os modos, conferir o queueURL em
#    gitops/apps/analytics-service/scaledobject.yaml com os valores reais:
terraform output workload_irsa_role_arn
terraform output sqs_queue_url
# (edite, faça commit/push — o ArgoCD sincroniza automaticamente)
```

## Requisito de estado (backend remoto)

O `terraform.tfstate` **não fica local**: o backend é um bucket S3
(`terraform/backend.tf`), com **state locking nativo do S3**
(`use_lockfile = true`, Terraform >= 1.10 — dispensa tabela DynamoDB de lock).

## Nota sobre IAM (AWS Academy x conta comum)

A variável `use_lab_role` (padrão `true`) escolhe o modo:

| | `use_lab_role = true` (AWS Academy) | `use_lab_role = false` (conta comum) |
|---|---|---|
| Role do cluster e dos nós | `LabRole` já existente na conta | roles dedicadas criadas pelo módulo `eks` |
| Provedor OIDC / IRSA | não criados (IAM bloqueado no Learner Lab) | criados; pods assumem roles via `ServiceAccount` |
| Credenciais dos pods (SQS, DynamoDB, KEDA) | `LabRole` do nó via IMDS (launch template com hop limit 2) | roles IRSA com privilégio mínimo |
| Admin do cluster | access entry explícita para a role `voclabs` (vale em todas as sessões) | access entry explícita para quem roda o apply |

O restante do projeto (networking, rds, elasticache, dynamodb, sqs, ecr,
argocd, keda) não muda entre os modos. No modo Academy qualquer pod do nó
alcança a `LabRole`: é o limite do ambiente de laboratório, não o desenho
recomendado para produção (que é o modo IRSA).

### Subindo no AWS Academy (Learner Lab)

1. Clique em *Start Lab*, abra *AWS Details* → *AWS CLI: Show* e copie o
   bloco inteiro (Access Key, Secret Key **e Session Token**, válidos só
   durante a sessão, cerca de 4 h). Depois, na raiz do repositório:
   ```bash
   ./terraform/scripts/academy-session.sh   # lê a área de transferência
   source .academy/env                      # em cada terminal do projeto
   ```
   O script grava as chaves em `.academy/` (ignorada pelo git), isola o
   terminal dos profiles do `~/.aws`, descobre a conta (`sts`) e atualiza no
   GitHub, via `gh`, os secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `AWS_SESSION_TOKEN` e `AWS_REGION` e a variável `AWS_ACCOUNT_ID`. Repita a
   cada sessão; com `--kube` ele também gera `.academy/kubeconfig`.
2. Crie pelo console um bucket S3 para o state (nome globalmente único) e
   rode `terraform init -reconfigure -backend-config="bucket=<bucket>"`.
3. `terraform apply` (região `us-east-1`; `use_lab_role` já é `true`).
   Em seguida `./terraform/scripts/academy-session.sh --kube --no-gh`.
4. Rode o CI dos 5 serviços (`workflow_dispatch`): o ECR da conta nova começa
   vazio e as tags em `gitops/apps/*/deployment.yaml` só existem depois do push.
5. Siga os passos 3 a 5 do passo a passo acima e
   `./scripts/sync-observability-secrets.sh` (Grafana e New Relic).
6. Ao terminar: `terraform destroy`. O lab para os nós quando a sessão acaba,
   mas EKS, NAT Gateway, RDS e load balancer continuam consumindo o crédito.
