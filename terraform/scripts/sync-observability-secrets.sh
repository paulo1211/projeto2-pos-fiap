#!/usr/bin/env bash
# Somente credenciais da observabilidade; não altera chaves das aplicações.
set -euo pipefail

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
EXISTING_SECRET=$(kubectl get secret grafana-admin -n observability --ignore-not-found -o json)
if [[ -z "$EXISTING_SECRET" ]]; then
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 18)}"
  kubectl create secret generic grafana-admin \
    --namespace observability \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret grafana-admin criado."
else
  echo "Secret grafana-admin preservado."
  # Alterar o Secret não troca a senha de uma base Grafana já inicializada.
  # Rotação deve usar a API/CLI administrativa do Grafana e atualizar o Secret.
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    echo "GRAFANA_ADMIN_PASSWORD só é usada na criação inicial; use o procedimento de rotação do Grafana." >&2
    exit 1
  fi
fi
echo "Consulte a senha com:"
echo "kubectl get secret grafana-admin -n observability -o jsonpath='{.data.admin-password}' | base64 -d"
