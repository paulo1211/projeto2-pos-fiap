#!/usr/bin/env bash
# Segredos da Etapa 3 (alertas e self-healing) no Secret observability/alerting-secrets:
#   PAGERDUTY_INTEGRATION_KEY  Integration Key do serviço no PagerDuty
#                              (Integrations → Events API V2), 32 caracteres
#   DISCORD_WEBHOOK_URL        Webhook do canal (Editar canal → Integrações →
#                              Webhooks → Copiar URL do webhook)
#   SELF_HEALING_TOKEN         gerado aqui; autentica o Grafana no runbook
#
# Valores vêm de variáveis de ambiente; se ausentes, preserva os do Secret
# existente; se não houver, pergunta (sem eco). Nada é gravado em arquivo
# versionado. Depois reinicia o Grafana (lê as variáveis só ao iniciar) e o
# runbook de self-healing.
#
# Uso (com o kubeconfig do lab, ex.: source .academy/env):
#   ./terraform/scripts/sync-alerting-secrets.sh
#   ROTATE_SELF_HEALING_TOKEN=true ./terraform/scripts/sync-alerting-secrets.sh
set -euo pipefail

NS=observability
SECRET=alerting-secrets

current() {
  kubectl -n "$NS" get secret "$SECRET" -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

ask() {  # ask VAR "pergunta"
  local value
  if [[ ! -t 0 ]]; then
    echo "ERRO: $1 não definida e sem terminal para perguntar." >&2; exit 1
  fi
  read -rsp "$2: " value; echo >&2
  printf '%s' "$value"
}

PD="${PAGERDUTY_INTEGRATION_KEY:-$(current PAGERDUTY_INTEGRATION_KEY)}"
[[ -n "$PD" ]] || PD="$(ask PAGERDUTY_INTEGRATION_KEY "PagerDuty Integration Key (Events API V2)")"
DC="${DISCORD_WEBHOOK_URL:-$(current DISCORD_WEBHOOK_URL)}"
[[ -n "$DC" ]] || DC="$(ask DISCORD_WEBHOOK_URL "URL do webhook do Discord")"
TOKEN="$(current SELF_HEALING_TOKEN)"
if [[ -z "$TOKEN" || "${ROTATE_SELF_HEALING_TOKEN:-false}" == "true" ]]; then
  TOKEN="$(openssl rand -hex 32)"
  echo "SELF_HEALING_TOKEN gerado."
else
  echo "SELF_HEALING_TOKEN preservado."
fi

PD="$(printf '%s' "$PD" | tr -d '[:space:]')"
DC="$(printf '%s' "$DC" | tr -d '[:space:]')"
if [[ ! "$PD" =~ ^[A-Za-z0-9]{32}$ ]]; then
  echo "ERRO: a Integration Key do PagerDuty deve ter 32 letras/números (Events API V2)." >&2; exit 1
fi
if [[ ! "$DC" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]]; then
  echo "ERRO: URL do Discord inválida (esperado https://discord.com/api/webhooks/<id>/<token>)." >&2; exit 1
fi

# Valores em arquivos temporários (chmod 600) para não aparecerem no `ps`.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
printf '%s' "$PD" > "$TMP/pd"; printf '%s' "$DC" > "$TMP/dc"; printf '%s' "$TOKEN" > "$TMP/tk"
unset PD DC TOKEN

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic "$SECRET" \
  --from-file=PAGERDUTY_INTEGRATION_KEY="$TMP/pd" \
  --from-file=DISCORD_WEBHOOK_URL="$TMP/dc" \
  --from-file=SELF_HEALING_TOKEN="$TMP/tk" \
  --dry-run=client -o yaml | kubectl apply -f -

for d in grafana self-healing; do
  if kubectl -n "$NS" get deployment "$d" >/dev/null 2>&1; then
    kubectl -n "$NS" rollout restart "deployment/$d" >/dev/null
    kubectl -n "$NS" rollout status "deployment/$d" --timeout=180s
  else
    echo "AVISO: deployment/$d ainda não existe em $NS (será criado pelo ArgoCD e já lerá o Secret)." >&2
  fi
done
echo "Pronto. Confira no Grafana: Alerting → Contact points → togglemaster-incident."
