#!/usr/bin/env bash
# One-time bootstrap after `terraform apply` has installed ArgoCD itself:
# registers the GitOps repo and applies the 5 Application CRs so ArgoCD
# starts managing (and self-managing, via the app-of-apps) every
# microservice. From this point on, sync is automatic on every push to
# gitops/**.
set -euo pipefail

cd "$(dirname "$0")/../.."

: "${GITOPS_REPO_URL:?Set GITOPS_REPO_URL to the git URL of this repo, e.g. https://github.com/paulo1211/projeto2-pos-fiap.git}"

kubectl apply -f gitops/argocd-apps/

echo "Applied Argo CD Application manifests. Check with:"
echo "  kubectl get applications -n argocd"
