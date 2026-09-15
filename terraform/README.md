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

# 6) Ajustar o ARN do IRSA no gitops/base/namespace.yaml e o queueURL em
#    gitops/apps/analytics-service/scaledobject.yaml com os valores reais:
terraform output workload_irsa_role_arn
terraform output sqs_queue_url
# (edite, faça commit/push — o ArgoCD sincroniza automaticamente)
```

## Requisito de estado (backend remoto)

O `terraform.tfstate` **não fica local**: o backend é um bucket S3
(`terraform/backend.tf`), com **state locking nativo do S3**
(`use_lockfile = true`, Terraform >= 1.10 — dispensa tabela DynamoDB de lock).

## Nota sobre IAM

Este projeto foi configurado para **conta pessoal AWS**: o módulo `eks`
cria as roles do cluster, do node group e uma role de IRSA para os
workloads (substitui `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` fixos por
credenciais temporárias via `ServiceAccount` — ver `gitops/base/namespace.yaml`).

Se for necessário rodar em **AWS Academy**, os únicos arquivos que mudam são
`terraform/modules/eks/main.tf` (trocar `aws_iam_role.cluster`/`aws_iam_role.node`
por um `data "aws_iam_role" "lab_role"` apontando para a `LabRole` existente)
e remover os `aws_iam_role_policy_attachment` — o restante do projeto
(networking, rds, elasticache, dynamodb, sqs, ecr, argocd) não usa IAM e
não muda.
