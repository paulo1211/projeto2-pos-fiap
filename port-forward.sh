#!/usr/bin/env bash
#
# Abre túneis (kubectl port-forward) do localhost até os Services do EKS e os
# mantém vivos: se um pod for trocado (rollout, troca de nós do lab, KEDA), o
# túnel reconecta sozinho. Ctrl+C encerra todos.
#
# Uso:
#   ./port-forward.sh            # 5 microsserviços (localhost:8001..8005)
#   ./port-forward.sh --all      # + Grafana, Prometheus e ArgoCD
#   ./port-forward.sh grafana argocd   # só os nomes informados
#
# Antes: source .academy/env (credenciais/kubeconfig do lab).
set -euo pipefail

# nome | namespace | service | porta local | porta do service
TARGETS=(
  "auth|togglemaster|auth-service|8001|8001"
  "flag|togglemaster|flag-service|8002|8002"
  "targeting|togglemaster|targeting-service|8003|8003"
  "evaluation|togglemaster|evaluation-service|8004|8004"
  # Escala a zero via KEDA: o túnel fica tentando até existir um pod.
  "analytics|togglemaster|analytics-service|8005|8005"
  "grafana|observability|grafana|3000|80"
  "prometheus|observability|kps-prometheus|9090|9090"
  "argocd|argocd|argocd-server|8080|443"
)
DEFAULT=(auth flag targeting evaluation analytics)

SELECTED=()
if [[ $# -eq 0 ]]; then
  SELECTED=("${DEFAULT[@]}")
elif [[ "$1" == "--all" ]]; then
  for t in "${TARGETS[@]}"; do SELECTED+=("${t%%|*}"); done
elif [[ "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '3,11p' "$0"; exit 0
else
  SELECTED=("$@")
fi

if ! kubectl get --raw /readyz >/dev/null 2>&1; then
  echo "ERRO: kubectl não acessa o cluster. Rode 'source .academy/env' (e academy-session.sh --kube)." >&2
  exit 1
fi

PIDS=()
cleanup() {
  trap - INT TERM EXIT
  echo; echo "Encerrando túneis..."
  for pid in "${PIDS[@]}"; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

forward_loop() {
  local name=$1 ns=$2 svc=$3 lport=$4 rport=$5
  while true; do
    kubectl -n "$ns" port-forward "svc/$svc" "$lport:$rport" >/dev/null 2>&1 || true
    sleep 3   # pod trocado / sem pod: tenta de novo
  done
}

echo "Túneis (Ctrl+C para encerrar):"
for name in "${SELECTED[@]}"; do
  found=false
  for t in "${TARGETS[@]}"; do
    IFS='|' read -r n ns svc lport rport <<< "$t"
    [[ "$n" == "$name" ]] || continue
    found=true
    if (exec 3<>"/dev/tcp/127.0.0.1/$lport") 2>/dev/null; then
      echo "  AVISO: porta $lport já está em uso; pulando $name." >&2
      break
    fi
    forward_loop "$n" "$ns" "$svc" "$lport" "$rport" &
    PIDS+=("$!")
    scheme=http; [[ "$n" == "argocd" ]] && scheme=https
    printf '  %-11s %s://localhost:%s  (%s/%s)\n' "$n" "$scheme" "$lport" "$ns" "$svc"
  done
  $found || echo "  AVISO: alvo desconhecido '$name'." >&2
done

if [[ " ${SELECTED[*]} " == *" grafana "* ]]; then
  echo "  Grafana: usuário admin; senha com"
  echo "    kubectl get secret grafana-admin -n observability -o jsonpath='{.data.admin-password}' | base64 -d"
fi
if [[ " ${SELECTED[*]} " == *" argocd "* ]]; then
  echo "  ArgoCD: usuário admin; senha com"
  echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
fi

wait
