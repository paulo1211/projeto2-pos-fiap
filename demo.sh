#!/usr/bin/env bash
#
# ToggleMaster — prepara o ambiente do AWS Academy do zero para a gravação do vídeo.
#
#  0. ferramentas            5. pods (rollouts, StatefulSet travado, imagens)
#  1. credenciais AWS (lab)  6. secrets e KEDA
#  2. acesso ao cluster      7. túneis (serviços, Grafana, Prometheus, ArgoCD)
#  3. nós do EKS             8. health checks
#  4. aplicações do ArgoCD   9. tráfego de teste (traces, métricas, logs, KEDA)
#                           10. resumo e roteiro do vídeo
#
# Uso:
#   ./demo.sh                 # fluxo completo; no fim segura os túneis (Ctrl+C encerra)
#   ./demo.sh --no-traffic    # não gera tráfego de teste
#   ./demo.sh --skip-tunnels  # só verifica/corrige o ambiente
#   ./demo.sh --yes           # aceita sem perguntar trocar nós e apagar pods travados
#
# Não roda terraform: se a infraestrutura não existir, indica o terraform apply.
# Senhas nunca aparecem na tela (o terminal vai estar sendo gravado).
set -euo pipefail

EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-654654158732}"
CLUSTER_NAME="${CLUSTER_NAME:-togglemaster-eks}"
REGION="${AWS_REGION_ACADEMY:-us-east-1}"
APP_NS=togglemaster
OBS_NS=observability

TRAFFIC=true; TUNNELS=true; ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --no-traffic) TRAFFIC=false ;;
    --skip-tunnels) TUNNELS=false; TRAFFIC=false ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) sed -n '3,19p' "$0"; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ACADEMY_DIR="$REPO_ROOT/.academy"
ENV_FILE="$ACADEMY_DIR/env"
KUBE_FILE="$ACADEMY_DIR/kubeconfig"
SESSION_SCRIPT="$REPO_ROOT/terraform/scripts/academy-session.sh"
DB_INIT_SCRIPT="$REPO_ROOT/terraform/scripts/init-databases.sh"
PF_SCRIPT="$REPO_ROOT/port-forward.sh"
PF_LOG="$ACADEMY_DIR/port-forward.log"

# --- saída ---------------------------------------------------------------------
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; W='\033[1m'; N='\033[0m'
step() { echo -e "\n${B}${W}=== [$1] $2 ===${N}"; }
ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
fail() { echo -e "  ${R}✘ $*${N}" >&2; exit 1; }
info() { echo -e "    $*"; }
confirm() {
  $ASSUME_YES && return 0
  local ans; read -r -p "  → $1 [s/N] " ans </dev/tty
  [[ "$ans" =~ ^[sSyY]$ ]]
}
elapsed_since() { echo $(( $(date +%s) - $(date -d "$1" +%s) )); }

PF_PID=""
cleanup() {
  trap - INT TERM EXIT
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    echo; echo "Encerrando túneis..."
    kill -INT "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

echo -e "${B}${W}"
echo "==================================================="
echo "   TOGGLEMASTER — PREPARAÇÃO DO AMBIENTE (DEMO)"
echo "==================================================="
echo -e "${N}  Confira o timer do Learner Lab: a sessão precisa durar a gravação inteira."

# --- 0. Ferramentas --------------------------------------------------------------
step 0 "Ferramentas"
missing=()
for bin in aws kubectl gh jq curl; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
((${#missing[@]} == 0)) || fail "faltando: ${missing[*]}"
ok "aws, kubectl, gh, jq e curl instalados"

# --- 1. Credenciais AWS ----------------------------------------------------------
step 1 "Credenciais AWS do Learner Lab"
check_creds() {
  [[ -f "$ENV_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || return 1
}
if ! check_creds; then
  warn "credenciais ausentes, expiradas ou canceladas (fim de sessão do lab)."
  info "1) No Learner Lab clique em ${W}Start Lab${N} e espere o indicador ficar verde."
  info "2) Abra ${W}AWS Details → AWS CLI: Show${N} e copie o bloco inteiro."
  read -r -p "  → Tecle Enter depois de copiar o bloco... " _ </dev/tty
  "$SESSION_SCRIPT"
  check_creds || fail "as credenciais ainda não autenticam; copie o bloco de novo e repita."
fi
[[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || fail "conta $ACCOUNT_ID diferente da esperada ($EXPECTED_ACCOUNT_ID)."
ok "conta $ACCOUNT_ID autenticada (só com .academy/env; profiles do ~/.aws não são usados)"
info "Secrets do GitHub: atualizados pelo academy-session.sh a cada nova sessão."

# --- 2. Cluster --------------------------------------------------------------------
step 2 "Acesso ao cluster EKS"
CLUSTER_STATUS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.status --output text 2>/dev/null)" \
  || fail "cluster $CLUSTER_NAME não existe. Rode: cd terraform && terraform apply"
[[ "$CLUSTER_STATUS" == "ACTIVE" ]] || fail "cluster em estado $CLUSTER_STATUS."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBE_FILE" >/dev/null
export KUBECONFIG="$KUBE_FILE"
kubectl get --raw /readyz >/dev/null 2>&1 || fail "kubectl não autenticou no cluster (access entry da role voclabs?)."
ok "cluster $CLUSTER_NAME ACTIVE e kubectl autenticado"

# --- 3. Nós ------------------------------------------------------------------------
step 3 "Nós do EKS"
NODEGROUP="$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query 'nodegroups[0]' --output text)"
DESIRED="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" \
  --query nodegroup.scalingConfig.desiredSize --output text)"

ready_nodes() {
  kubectl get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length'
}
# Instâncias ligadas há > 8 min que não viraram nó: o nodeadm falhou (instância
# criada pelo ASG com a sessão do lab encerrada) e não tenta de novo.
stale_instances() {
  local registered instances id launch
  registered="$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's#.*/##')"
  instances="$(aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,LaunchTime]' --output text)"
  while read -r id launch; do
    [[ -z "$id" ]] && continue
    grep -qx "$id" <<< "$registered" && continue
    if (( $(elapsed_since "$launch") > 480 )); then echo "$id"; fi
  done <<< "$instances"
  return 0
}

stale="$(stale_instances)"
if [[ -n "$stale" ]]; then
  warn "instâncias ligadas que não entraram no cluster: $(echo $stale)"
  info "Causa típica: o ASG as criou com a sessão do lab encerrada (nodeadm sem permissão)."
  if confirm "Encerrar essas instâncias para o ASG recriar com a sessão ativa?"; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $stale >/dev/null
    ok "instâncias encerradas; o ASG vai criar novas"
  fi
fi

info "aguardando $DESIRED nó(s) Ready (até 8 min)..."
for _ in $(seq 1 96); do
  n="$(ready_nodes)"; (( n >= DESIRED )) && break; sleep 5
done
n="$(ready_nodes)"
(( n >= DESIRED )) || fail "só $n de $DESIRED nós Ready. Veja: kubectl get nodes; aws ec2 get-console-output --instance-id <id> --latest"
ok "$n nó(s) Ready"

# --- 4. ArgoCD -----------------------------------------------------------------------
step 4 "Aplicações do ArgoCD"
apps_pending() {
  kubectl -n argocd get applications -o json \
    | jq -r '.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy")
             | "\(.metadata.name) \(.status.sync.status)/\(.status.health.status)"'
}
refreshed=false
for i in $(seq 1 60); do   # até 10 min
  pending="$(apps_pending)"
  [[ -z "$pending" ]] && break
  if ! $refreshed && (( i == 6 )); then
    for app in $(awk '$2 ~ /^OutOfSync/ {print $1}' <<< "$pending"); do
      kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done
    refreshed=true
  fi
  (( i % 6 == 0 )) && info "aguardando: $(echo $pending)"
  sleep 10
done
pending="$(apps_pending)"
if [[ -n "$pending" ]]; then
  warn "ainda pendentes: $(echo $pending)"
  for app in $(awk '{print $1}' <<< "$pending"); do
    msg="$(kubectl -n argocd get application "$app" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
    info "$app: ${msg:-sem mensagem de sync}"
  done
  info "(Progressing costuma ser só pod subindo; a etapa 5 confere.)"
else
  ok "$(kubectl -n argocd get applications --no-headers | wc -l) aplicações Synced/Healthy"
fi

# --- 5. Pods ----------------------------------------------------------------------------
step 5 "Pods"
bad_image="$(kubectl get pods -n "$APP_NS" -o json | jq -r '.items[] | select(any(.status.containerStatuses[]?;
  .state.waiting.reason=="ImagePullBackOff" or .state.waiting.reason=="ErrImagePull")) | .metadata.name')"
if [[ -n "$bad_image" ]]; then
  warn "pods sem imagem no ECR: $(echo $bad_image)"
  info "Rode o CI dos serviços (Actions → Run workflow) e execute ./demo.sh de novo."
fi

# Pod de StatefulSet que nunca ficou Ready não é substituído após mudança de
# template (limitação do StatefulSet): precisa ser apagado.
for ns in "$OBS_NS" "$APP_NS"; do
  stuck="$(kubectl get pods -n "$ns" -o json | jq -r '.items[]
    | select(.metadata.ownerReferences[]?.kind=="StatefulSet")
    | select(any(.status.containerStatuses[]?; .state.waiting.reason=="CrashLoopBackOff"))
    | .metadata.name')"
  for pod in $stuck; do
    warn "$ns/$pod em CrashLoopBackOff"
    kubectl -n "$ns" logs "$pod" --all-containers --tail=3 2>/dev/null | sed 's/^/      /' || true
    if confirm "Apagar $ns/$pod para recriar com o template atual?"; then
      kubectl -n "$ns" delete pod "$pod" --wait=false >/dev/null
      ok "$pod apagado (o StatefulSet recria)"
    fi
  done
done

for ns in "$APP_NS" "$OBS_NS"; do
  for d in $(kubectl get deploy -n "$ns" -o name); do
    kubectl -n "$ns" rollout status "$d" --timeout=180s >/dev/null 2>&1 \
      && ok "$ns/${d#*/}" || warn "$ns/${d#*/} não ficou pronto em 3 min"
  done
  for s in $(kubectl get statefulset -n "$ns" -o name); do
    kubectl -n "$ns" rollout status "$s" --timeout=180s >/dev/null 2>&1 \
      && ok "$ns/${s#*/}" || warn "$ns/${s#*/} não ficou pronto em 3 min"
  done
  for ds in $(kubectl get daemonset -n "$ns" -o name); do
    kubectl -n "$ns" rollout status "$ds" --timeout=120s >/dev/null 2>&1 \
      && ok "$ns/${ds#*/}" || warn "$ns/${ds#*/} não ficou pronto em 2 min"
  done
done

# --- 6. Secrets e KEDA ---------------------------------------------------------------------
step 6 "Secrets e KEDA"
has_secret() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
if has_secret "$APP_NS" togglemaster-secrets; then
  ok "togglemaster-secrets"
  # Idempotente: num RDS novo cria a tabela api_keys e cadastra a SERVICE_API_KEY
  # (sem isso o auth-service responde 503 e o /evaluate falha).
  if "$DB_INIT_SCRIPT" --quiet >/dev/null 2>"$ACADEMY_DIR/db-init.log"; then
    ok "schemas dos bancos e SERVICE_API_KEY (init-databases.sh)"
  else
    warn "init-databases.sh falhou; detalhes em .academy/db-init.log"
  fi
else
  warn "togglemaster-secrets ausente → cd terraform && ./scripts/sync-secrets.sh && ./scripts/init-databases.sh"
fi
has_secret "$OBS_NS" grafana-admin && ok "grafana-admin" \
  || warn "grafana-admin ausente → ./terraform/scripts/sync-observability-secrets.sh"
has_secret "$OBS_NS" newrelic-license && ok "newrelic-license" \
  || warn "newrelic-license ausente: traces NÃO chegam ao New Relic → NEW_RELIC_LICENSE_KEY + sync-observability-secrets.sh"
so_ready="$(kubectl -n "$APP_NS" get scaledobject -o json \
  | jq -r '.items[] | "\(.metadata.name) \((.status.conditions // [])[] | select(.type=="Ready") | .status)"')"
if grep -q " True$" <<< "$so_ready"; then
  ok "ScaledObject do analytics-service Ready (KEDA consulta o SQS com a LabRole)"
else
  warn "ScaledObject não está Ready: ${so_ready:-inexistente} → kubectl -n $APP_NS describe scaledobject"
fi

# --- 7. Túneis ---------------------------------------------------------------------------------
if $TUNNELS; then
  step 7 "Túneis (port-forward)"
  : > "$PF_LOG"
  "$PF_SCRIPT" --all > "$PF_LOG" 2>&1 &
  PF_PID=$!
  sleep 4
  kill -0 "$PF_PID" 2>/dev/null || { cat "$PF_LOG"; fail "port-forward.sh encerrou."; }
  grep -E "localhost|AVISO" "$PF_LOG" | grep -v "senha\|kubectl get" | sed 's/^ */    /' || true
fi

# --- 8. Health checks -------------------------------------------------------------------------
if $TUNNELS; then
  step 8 "Health checks pelos túneis"
  for p in auth:8001 flag:8002 targeting:8003 evaluation:8004; do
    name="${p%%:*}-service"; port="${p##*:}"; up=false
    for _ in $(seq 1 15); do
      curl -sf "http://localhost:$port/health" >/dev/null 2>&1 && { up=true; break; }; sleep 2
    done
    $up && ok "$name (localhost:$port)" || warn "$name não respondeu em localhost:$port"
  done
fi

# --- 9. Tráfego de teste ---------------------------------------------------------------------
if $TRAFFIC; then
  step 9 "Tráfego de teste"
  MASTER_KEY="$(kubectl -n "$APP_NS" get secret togglemaster-secrets -o jsonpath='{.data.MASTER_KEY}' | base64 -d)"
  FLAG_NAME=enable-new-dashboard
  API_KEY="$(curl -s -X POST localhost:8001/admin/keys -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $MASTER_KEY" -d '{"name":"demo-video"}' | jq -r '.key // empty' 2>/dev/null || true)"
  unset MASTER_KEY
  if [[ "$API_KEY" != tm_key_* ]]; then
    warn "auth-service não gerou a API key (MASTER_KEY do Secret difere da do pod?)."
    info "Reinicie: kubectl -n $APP_NS rollout restart deployment/auth-service"
  else
    ok "API key criada no auth-service"
    curl -s -X POST localhost:8002/flags -H 'Content-Type: application/json' -H "Authorization: Bearer $API_KEY" \
      -d "{\"name\":\"$FLAG_NAME\",\"description\":\"Novo painel (demo)\",\"is_enabled\":true}" >/dev/null
    curl -s -X POST localhost:8003/rules -H 'Content-Type: application/json' -H "Authorization: Bearer $API_KEY" \
      -d "{\"flag_name\":\"$FLAG_NAME\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}" >/dev/null
    ok "flag '$FLAG_NAME' e regra de 50% criadas/verificadas"
    on=0; total=40
    for i in $(seq 1 $total); do
      r="$(curl -s "localhost:8004/evaluate?user_id=demo-user-$i&flag_name=$FLAG_NAME" | jq -r '.result // empty' 2>/dev/null || true)"
      [[ "$r" == "true" ]] && on=$((on + 1))
    done
    ok "$total avaliações no evaluation-service ($on ativas, $((total - on)) inativas)"
    info "aguardando o KEDA ativar o analytics-service (até 2 min)..."
    for _ in $(seq 1 24); do
      replicas="$(kubectl -n "$APP_NS" get deploy analytics-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
      [[ "${replicas:-0}" -gt 0 ]] && break; sleep 5
    done
    if [[ "${replicas:-0}" -gt 0 ]]; then
      ok "analytics-service escalou para $replicas réplica(s) via KEDA"
      TABLE="$(kubectl -n "$APP_NS" get deploy analytics-service -o json | jq -r '
        [.spec.template.spec.containers[].env[]? | select(.name=="AWS_DYNAMODB_TABLE") | .value][0] // "ToggleMasterAnalytics"')"
      sleep 10
      count="$(aws dynamodb scan --table-name "$TABLE" --select COUNT --query Count --output text 2>/dev/null || echo "?")"
      ok "DynamoDB $TABLE: $count evento(s) gravado(s)"
    else
      warn "analytics-service não escalou ainda (fila abaixo do limiar ou polling do KEDA); confira depois."
    fi
  fi
fi

# --- 10. Resumo ---------------------------------------------------------------------------------
step 10 "Pronto para gravar"
PASS_FILE="$ACADEMY_DIR/demo-passwords"
{
  echo "grafana  admin  $(kubectl -n "$OBS_NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
  echo "argocd   admin  $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
} > "$PASS_FILE"
chmod 600 "$PASS_FILE"
GRAFANA_PASS="$(awk '/^grafana/{print $3}' "$PASS_FILE")"
if [[ -n "$GRAFANA_PASS" ]] && command -v wl-copy >/dev/null 2>&1 && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  printf '%s' "$GRAFANA_PASS" | wl-copy; ok "senha do Grafana copiada para a área de transferência"
elif [[ -n "$GRAFANA_PASS" ]] && command -v xclip >/dev/null 2>&1; then
  printf '%s' "$GRAFANA_PASS" | xclip -selection clipboard; ok "senha do Grafana copiada para a área de transferência"
fi
unset GRAFANA_PASS
info "Senhas (Grafana e ArgoCD) em .academy/demo-passwords — não mostrar na gravação."

if $TUNNELS; then
  echo -e "
  ${W}Endereços${N}
    Grafana     http://localhost:3000   (admin)
    ArgoCD      https://localhost:8080  (admin; aceite o certificado)
    Prometheus  http://localhost:9090
    Serviços    http://localhost:8001..8005"
fi
echo -e "
  ${W}Roteiro do vídeo (ordem do PDF)${N}
    1. Visão geral: kubectl get nodes · kubectl get applications -n argocd · ArgoCD na UI
    2. Grafana: dashboard ToggleMaster Overview · Explore → Loki {k8s_namespace_name=\"togglemaster\"}
       · explicar o pipeline: apps → otel-agent/otel-gateway → Prometheus, Loki e New Relic
    3. New Relic: APM & Services → evaluation-service → Service map · requisição de teste:
       curl \"localhost:8004/evaluate?user_id=video&flag_name=enable-new-dashboard\"
       kubectl -n $APP_NS logs -l app=evaluation-service --since=1m --prefix | grep -oE 'trace_id=[0-9a-f]{32}' | tail -1
       → Distributed tracing: trace.id = '<id>' · mesmo id no Loki: {k8s_namespace_name=\"togglemaster\"} |= \"<id>\"
    4. Incidente e Self-Healing (Etapa 3): ./demo-incident.sh"

if $TUNNELS; then
  echo -e "\n  ${G}${W}Túneis ativos — deixe este terminal aberto. Ctrl+C encerra.${N}"
  wait "$PF_PID"
fi
