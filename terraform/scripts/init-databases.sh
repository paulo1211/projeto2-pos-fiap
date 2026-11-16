#!/usr/bin/env bash
# Aplica os schemas dos três bancos (auth, flag, targeting) e cadastra a
# SERVICE_API_KEY no auth-service. Necessário em todo RDS novo: o Terraform
# cria os bancos vazios e, sem a tabela api_keys, o /validate responde 503.
#
# Roda dentro do cluster, num Job com postgres:16-alpine:
#   - os SQL vêm de <serviço>/db/init.sql (ConfigMap db-init-sql);
#   - URLs dos bancos e SERVICE_API_KEY vêm do Secret togglemaster-secrets,
#     então nenhuma credencial passa pelo terminal;
#   - só o hash SHA-256 da chave vai ao banco (como o auth-service faz).
# Idempotente (IF NOT EXISTS / ON CONFLICT DO NOTHING): pode rodar sempre.
# Rode de novo após rotacionar a SERVICE_API_KEY (ROTATE_APP_KEYS=true).
#
# Uso (com o kubeconfig do lab, ex.: source .academy/env):
#   ./terraform/scripts/init-databases.sh
#   ./terraform/scripts/init-databases.sh --quiet   # sem os logs do psql
set -euo pipefail

NAMESPACE="${NAMESPACE:-togglemaster}"
TIMEOUT="${TIMEOUT:-5m}"
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=true ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if ! kubectl -n "$NAMESPACE" get secret togglemaster-secrets >/dev/null 2>&1; then
  echo "ERRO: Secret togglemaster-secrets não existe em $NAMESPACE; rode antes o sync-secrets.sh." >&2
  exit 1
fi

kubectl -n "$NAMESPACE" create configmap db-init-sql \
  --from-file=auth.sql="$REPO_ROOT/auth-service/db/init.sql" \
  --from-file=flag.sql="$REPO_ROOT/flag-service/db/init.sql" \
  --from-file=targeting.sql="$REPO_ROOT/targeting-service/db/init.sql" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" delete job db-init --ignore-not-found --wait >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: db-init
    app.kubernetes.io/part-of: togglemaster-ecosystem
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 900
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16-alpine
          resources: {requests: {cpu: 50m, memory: 64Mi}}
          envFrom: [{secretRef: {name: togglemaster-secrets}}]
          volumeMounts: [{name: sql, mountPath: /sql}]
          command: ["sh", "-c"]
          args:
            - |
              set -e
              for db in auth flag targeting; do
                case \$db in
                  auth) URL=\$AUTH_DATABASE_URL ;;
                  flag) URL=\$FLAG_DATABASE_URL ;;
                  targeting) URL=\$TARGETING_DATABASE_URL ;;
                esac
                # O banco já existe no RDS: o CREATE DATABASE do init.sql é do docker-compose.
                echo "== \$db"; grep -v '^CREATE DATABASE' /sql/\$db.sql | psql "\$URL" -v ON_ERROR_STOP=1
              done
              HASH=\`printf %s "\$SERVICE_API_KEY" | sha256sum | cut -d' ' -f1\`
              echo "== service key"
              psql "\$AUTH_DATABASE_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO api_keys (name, key_hash) VALUES ('service-internal', '\$HASH') ON CONFLICT (key_hash) DO NOTHING;"
      volumes: [{name: sql, configMap: {name: db-init-sql}}]
EOF

echo "Job db-init criado; aguardando (até $TIMEOUT)..."
if kubectl -n "$NAMESPACE" wait --for=condition=complete job/db-init --timeout="$TIMEOUT" >/dev/null 2>&1; then
  $QUIET || kubectl -n "$NAMESPACE" logs job/db-init
  echo "Schemas aplicados e SERVICE_API_KEY cadastrada."
else
  echo "ERRO: o Job db-init não completou." >&2
  kubectl -n "$NAMESPACE" get pods -l job-name=db-init -o wide >&2 || true
  kubectl -n "$NAMESPACE" logs job/db-init --tail=20 >&2 2>/dev/null || true
  kubectl -n "$NAMESPACE" describe pod -l job-name=db-init 2>/dev/null | sed -n '/Events:/,$p' >&2 || true
  exit 1
fi
