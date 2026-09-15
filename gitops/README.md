# GitOps — ToggleMaster

Única fonte de verdade para o que roda no cluster EKS. O ArgoCD sincroniza
esta pasta automaticamente (auto-sync + self-heal); ninguém roda `kubectl
apply` manualmente nem faz deploy a partir da máquina local.

```
gitops/
├── base/                 # namespace + configmap compartilhados (Application "togglemaster-base")
├── apps/
│   ├── auth-service/       # deployment + service
│   ├── flag-service/       # deployment + service
│   ├── targeting-service/  # deployment + service
│   ├── evaluation-service/ # deployment + service + hpa
│   └── analytics-service/  # deployment + service + keda scaledobject
└── argocd-apps/          # as 6 Applications do ArgoCD (base + 5 serviços)
```

## Como a tag da imagem chega aqui

1. Push/merge na `main` de um dos 5 microsserviços dispara o workflow de CI
   daquele serviço (`.github/workflows/<service>-ci.yml`).
2. Depois do build, testes, lint, scan de segurança (SAST/SCA) e do build +
   push da imagem para o ECR (tag = `v1.0.0-<commit-hash>`), o próprio
   pipeline edita `gitops/apps/<service>/deployment.yaml` (campo `image:`)
   e faz commit + push direto na `main` (`chore(gitops): deploy ... [skip ci]`).
3. O ArgoCD detecta a mudança no repositório Git e sincroniza automaticamente
   a nova versão no cluster — sem qualquer `kubectl apply` manual.

## Secrets

`base/secrets.example.yaml` é só referência — **não** está listado em
`base/kustomization.yaml` e o ArgoCD nunca sincroniza esse arquivo. O Secret
real (`togglemaster-secrets`) é aplicado diretamente no cluster por
`terraform/scripts/sync-secrets.sh`, a partir dos valores gerados pelo
Terraform/Secrets Manager. Se o Secret fizesse parte do sync do ArgoCD, o
auto-sync reverteria as credenciais reais para o placeholder do git a cada
reconciliação.
