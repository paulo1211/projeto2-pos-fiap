#!/usr/bin/env bash
#
# ToggleMaster — "A Prova Real" (Etapa 3): incidente proposital e self-healing.
#
#  1. checa o ambiente (segredos do alerting, Grafana, runbook, auth-service)
#  2. injeta a falha: POST /admin/chaos em cada pod do auth-service
#     (/validate passa a responder 500; o /health continua OK, então o
#     Kubernetes sozinho não percebe nada)
#  3. gera tráfego no /validate e mostra, a cada 5 s: códigos HTTP, estado do
#     alerta no Grafana (Normal → Pending → Firing) e pods do auth-service
#  4. o Grafana dispara: PagerDuty abre o incidente, Discord recebe a
#     notificação e o runbook faz o rollout restart do auth-service
#  5. pods novos (sem a falha, que só existia na memória) → 401 normais →
#     alerta volta a Normal (PagerDuty resolve e Discord avisa)
#  6. mostra o log do self-healing e o histórico do rollout
#
# Uso:  source .academy/env && ./demo-incident.sh
set -euo pipefail

APP_NS=togglemaster
OBS_NS=observability
DEPLOY=auth-service
RULE_PREFIX="auth-service"            # título da regra em gitops/observability/alerting/rules.yaml
FIRING_TIMEOUT=${FIRING_TIMEOUT:-420}
HEAL_TIMEOUT=${HEAL_TIMEOUT:-300}
RESOLVE_TIMEOUT=${RESOLVE_TIMEOUT:-420}
AUTH_PORT=18001
GRAFANA_PORT=13000

WORK="$(mktemp -d)"
chmod 700 "$WORK"
CODES="$WORK/codes"; : > "$CODES"

if [[ -t 1 ]]; then
  B='\033[1m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; N='\033[0m'
else
  B=''; G=''; Y=''; R=''; C=''; N=''
fi
step() { echo -e "\n${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
fail() { echo -e "  ${R}✘ $*${N}" >&2; exit 1; }
now()  { date +%H:%M:%S; }

PIDS=()
INJECTED_PODS=()
cleanup() {
  trap - INT TERM EXIT
  # Se o self-healing não rodou, desliga a falha nos pods que ainda existem.
  for pod in "${INJECTED_PODS[@]}"; do
    if kubectl -n "$APP_NS" get pod "$pod" >/dev/null 2>&1; then
      chaos_pod "$pod" false >/dev/null 2>&1 && echo "  falha desligada em $pod (limpeza)" || true
    fi
  done
  for pid in "${PIDS[@]}"; do pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup INT TERM EXIT

wait_port() {
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# Túnel que se reconecta (o pod do outro lado é trocado pelo restart).
forward_loop() {  # ns alvo porta_local porta_remota
  while true; do
    kubectl -n "$1" port-forward "$2" "$3:$4" >/dev/null 2>&1 || true
    sleep 1
  done
}

# Liga/desliga a falha em um pod específico (túnel direto para o pod).
CHAOS_PORT=18100
chaos_pod() {  # pod true|false
  local port=$((CHAOS_PORT++)) pf code
  kubectl -n "$APP_NS" port-forward "pod/$1" "$port:8001" >/dev/null 2>&1 &
  pf=$!
  if ! wait_port "$port"; then kill "$pf" 2>/dev/null; return 1; fi
  code=$(curl -s -o "$WORK/chaos.out" -w '%{http_code}' -m 5 -X POST \
    -H @"$WORK/master.hdr" -H 'Content-Type: application/json' \
    -d "{\"fail\": $2}" "http://127.0.0.1:$port/admin/chaos" || true)
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null || true
  echo "$code"
  [[ "$code" == "200" ]]
}

alert_state() {
  curl -s -m 5 --netrc-file "$WORK/netrc" \
    "http://localhost:$GRAFANA_PORT/api/prometheus/grafana/api/v1/rules" 2>/dev/null \
    | jq -r --arg p "$RULE_PREFIX" \
      '[.data.groups[]?.rules[]? | select(.name | startswith($p)) | .state][0] // "?"' 2>/dev/null \
    || echo "?"
}

auth_pods() {
  kubectl -n "$APP_NS" get pods -l "app=$DEPLOY" --no-headers \
    -o custom-columns='N:.metadata.name,R:.status.containerStatuses[0].ready,D:.metadata.deletionTimestamp' 2>/dev/null
}

LAST_LINE=0
WINDOW=""
window_codes() {  # resumo dos códigos HTTP desde a última chamada (em WINDOW)
  local total; total=$(wc -l < "$CODES")
  if (( total > LAST_LINE )); then
    WINDOW=$(sed -n "$((LAST_LINE + 1)),${total}p" "$CODES" | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}')
  else
    WINDOW="sem respostas"
  fi
  LAST_LINE=$total
}

status_line() {  # imprime uma linha do painel
  local state pods color
  state=$(alert_state)
  case "$state" in firing) color=$R ;; pending) color=$Y ;; inactive|normal) color=$G ;; *) color=$N ;; esac
  pods=$(auth_pods | awk '{ s = ($3 != "<none>") ? "encerrando" : (($2 == "true") ? "ok" : "subindo"); printf "%s(%s) ", substr($1, length($1) - 4), s }')
  window_codes
  printf "  %s  HTTP: %-22s alerta: ${color}%-8s${N}  pods: %s\n" "$(now)" "$WINDOW" "$state" "$pods"
  LAST_STATE=$state
}

# --- 1. Checagens -------------------------------------------------------------------
step "1. Ambiente"
for t in kubectl curl jq; do command -v "$t" >/dev/null || fail "$t não encontrado"; done
kubectl get --raw /readyz >/dev/null 2>&1 || fail "kubectl sem acesso ao cluster → source .academy/env"
kubectl -n "$OBS_NS" get secret alerting-secrets >/dev/null 2>&1 \
  || fail "Secret alerting-secrets ausente → ./terraform/scripts/sync-alerting-secrets.sh"
ok "Secret alerting-secrets (PagerDuty, Discord, token do self-healing)"
kubectl -n "$OBS_NS" rollout status deployment/self-healing --timeout=60s >/dev/null 2>&1 \
  || fail "runbook self-healing não está pronto → kubectl apply -f gitops/argocd-apps/15-self-healing-app.yaml"
ok "runbook self-healing pronto"
kubectl -n "$APP_NS" rollout status "deployment/$DEPLOY" --timeout=60s >/dev/null 2>&1 \
  || fail "deployment/$DEPLOY não está saudável antes do teste"
ok "deployment/$DEPLOY saudável"

MASTER_KEY=$(kubectl -n "$APP_NS" get secret togglemaster-secrets -o jsonpath='{.data.MASTER_KEY}' | base64 -d)
( umask 077; printf 'Authorization: Bearer %s\n' "$MASTER_KEY" > "$WORK/master.hdr" )
unset MASTER_KEY
G_USER=$(kubectl -n "$OBS_NS" get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)
G_PASS=$(kubectl -n "$OBS_NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
( umask 077; printf 'machine localhost login %s password %s\n' "$G_USER" "$G_PASS" > "$WORK/netrc" )
unset G_USER G_PASS

forward_loop "$OBS_NS" svc/grafana "$GRAFANA_PORT" 80 & PIDS+=("$!")
forward_loop "$APP_NS" "svc/$DEPLOY" "$AUTH_PORT" 8001 & PIDS+=("$!")
wait_port "$GRAFANA_PORT" && wait_port "$AUTH_PORT" || fail "túneis para Grafana/auth-service não abriram"
state=$(alert_state)
if [[ "$state" == "?" ]]; then
  # Pod novo do Grafana pode ter subido depois do reload do sidecar: recarrega.
  warn "regra não encontrada; recarregando o provisionamento de alertas do Grafana"
  curl -s -m 10 --netrc-file "$WORK/netrc" -X POST \
    "http://localhost:$GRAFANA_PORT/api/admin/provisioning/alerting/reload" >/dev/null || true
  sleep 3; state=$(alert_state)
fi
[[ "$state" != "?" ]] || fail "regra '$RULE_PREFIX…' não encontrada no Grafana (ArgoCD sincronizou o alerting? kubectl -n $OBS_NS logs deploy/grafana -c grafana-sc-alerts)"
[[ "$state" == "inactive" || "$state" == "normal" ]] \
  || warn "alerta já está em '$state' antes do teste; o resultado pode se confundir"
ok "regra de alerta no Grafana: $state"

echo -e "\n  ${C}Pods do $DEPLOY antes do incidente:${N}"
kubectl -n "$APP_NS" get pods -l "app=$DEPLOY" -o wide | sed 's/^/    /'
mapfile -t ORIGINAL < <(kubectl -n "$APP_NS" get pods -l "app=$DEPLOY" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# --- 2. Injeção da falha --------------------------------------------------------------
step "2. Injetando a falha no $DEPLOY ($(now))"
for pod in "${ORIGINAL[@]}"; do
  code=$(chaos_pod "$pod" true) || {
    [[ "$code" == "404" ]] && fail "$pod sem /admin/chaos: a imagem nova do auth-service ainda não foi publicada (CI/ArgoCD)"
    fail "não consegui injetar a falha em $pod (HTTP ${code:-sem resposta})"
  }
  INJECTED_PODS+=("$pod")
  ok "$pod: /validate agora responde 500 (o /health continua 200)"
done
START=$(date +%s)

# Tráfego contínuo: ~5 req/s com uma chave qualquer (normal = 401; com falha = 500).
(
  while true; do
    curl -s -o /dev/null -w '%{http_code}\n' -m 2 -H 'Authorization: Bearer tm_key_demo_incidente' \
      "http://127.0.0.1:$AUTH_PORT/validate" >> "$CODES" 2>/dev/null || echo "000" >> "$CODES"
    sleep 0.2
  done
) & PIDS+=("$!")

# --- 3. Esperando o alerta -------------------------------------------------------------
step "3. Tráfego no /validate; aguardando o alerta (regra: 5xx > 5% por 1 min)"
LAST_STATE="?"
until [[ "$LAST_STATE" == "firing" ]]; do
  (( $(date +%s) - START < FIRING_TIMEOUT )) || fail "o alerta não disparou em ${FIRING_TIMEOUT}s"
  sleep 5; status_line
done
FIRED=$(date +%s)
ok "ALERTA FIRING após $((FIRED - START))s → PagerDuty (incidente), Discord (ChatOps) e webhook do self-healing"

# --- 4. Self-healing ---------------------------------------------------------------------
step "4. Aguardando o self-healing (rollout restart do $DEPLOY)"
healed() {
  local pods; pods=$(auth_pods)
  [[ -n "$pods" ]] || return 1
  local want; want=$(kubectl -n "$APP_NS" get deployment "$DEPLOY" -o jsonpath='{.spec.replicas}')
  local fresh; fresh=$(awk -v orig=" ${ORIGINAL[*]} " '$2 == "true" && $3 == "<none>" && index(orig, " " $1 " ") == 0' <<< "$pods" | wc -l)
  local old; old=$(awk -v orig=" ${ORIGINAL[*]} " 'index(orig, " " $1 " ") > 0' <<< "$pods" | wc -l)
  (( fresh >= want && old == 0 ))
}
until healed; do
  (( $(date +%s) - FIRED < HEAL_TIMEOUT )) || fail "o self-healing não reiniciou o $DEPLOY em ${HEAL_TIMEOUT}s (veja: kubectl -n $OBS_NS logs deploy/self-healing)"
  sleep 5; status_line
done
HEALED=$(date +%s)
INJECTED_PODS=()
ok "pods novos no ar $((HEALED - FIRED))s após o alerta, sem intervenção humana"

# --- 5. Recuperação -------------------------------------------------------------------------
step "5. Aguardando o alerta voltar ao normal (janela de 2 min da regra)"
until [[ "$LAST_STATE" == "inactive" || "$LAST_STATE" == "normal" ]]; do
  (( $(date +%s) - HEALED < RESOLVE_TIMEOUT )) || { warn "alerta ainda em '$LAST_STATE' após ${RESOLVE_TIMEOUT}s"; break; }
  sleep 5; status_line
done
[[ "$LAST_STATE" == "inactive" || "$LAST_STATE" == "normal" ]] \
  && ok "alerta RESOLVIDO $(( $(date +%s) - START ))s após a falha → PagerDuty resolve o incidente e o Discord avisa"

# --- 6. Evidências ----------------------------------------------------------------------------
step "6. Evidências"
echo -e "  ${C}Log do runbook de self-healing:${N}"
kubectl -n "$OBS_NS" logs deploy/self-healing --since=$(( $(date +%s) - START + 60 ))s 2>/dev/null \
  | grep -vE "ouvindo :" | sed 's/^/    /'
echo -e "\n  ${C}Rollout do $DEPLOY:${N}"
kubectl -n "$APP_NS" get deployment "$DEPLOY" \
  -o jsonpath='    restartedAt={.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}  acionado pelo alerta: {.spec.template.metadata.annotations.self-healing/alert}{"\n"}'
kubectl -n "$APP_NS" rollout history "deployment/$DEPLOY" | tail -3 | sed 's/^/    /'
kubectl -n "$APP_NS" get pods -l "app=$DEPLOY" -o wide | sed 's/^/    /'
cat <<EOF

  Linha do tempo: falha $(date -d "@$START" +%H:%M:%S) · alerta firing $(date -d "@$FIRED" +%H:%M:%S) · pods novos $(date -d "@$HEALED" +%H:%M:%S)
  Mostre agora: PagerDuty (incidente aberto e resolvido), canal do Discord (incidente,
  ação do self-healing e resolução) e Grafana → Alerting → Alert rules (histórico do estado).
EOF
