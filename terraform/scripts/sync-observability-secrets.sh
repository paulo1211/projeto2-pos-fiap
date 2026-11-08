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

# --- New Relic (APM) ---------------------------------------------------------
# License Key de ingestão (tipo "INGEST - LICENSE"), lida pelo otel-gateway
# como header api-key do exporter otlphttp/newrelic. Informe via variável de
# ambiente, sem gravar em arquivo:
#   read -rs NEW_RELIC_LICENSE_KEY && export NEW_RELIC_LICENSE_KEY && ./sync-observability-secrets.sh
# Com a variável definida o Secret é criado ou atualizado (rotação simples:
# o Collector lê a chave só na inicialização, então reinicie o gateway).
if [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  # A chave vai por stdin (e não como argumento) para não aparecer no `ps`.
  printf '%s' "$NEW_RELIC_LICENSE_KEY" | kubectl create secret generic newrelic-license \
    --namespace observability \
    --from-file=license-key=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret newrelic-license aplicado. Para o gateway carregar a chave:"
  echo "kubectl -n observability rollout restart deployment/otel-gateway"
else
  EXISTING_NR=$(kubectl get secret newrelic-license -n observability --ignore-not-found -o name)
  if [[ -n "$EXISTING_NR" ]]; then
    echo "Secret newrelic-license preservado."
  else
    echo "AVISO: Secret newrelic-license ausente; os traces NÃO chegarão ao New Relic." >&2
    echo "Defina NEW_RELIC_LICENSE_KEY e execute o script novamente." >&2
  fi
fi
