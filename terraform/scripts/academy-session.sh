#!/usr/bin/env bash
# Prepara uma nova sessão do AWS Academy (Learner Lab) após clicar em "Start Lab".
#
# 1. Lê o bloco de credenciais do painel "AWS Details" -> "AWS CLI: Show"
#    (área de transferência ou stdin).
# 2. Grava as chaves em <repo>/.academy/credentials (fora do git, chmod 600),
#    isoladas dos profiles do ~/.aws.
# 3. Gera <repo>/.academy/env para o terminal usar SOMENTE a conta Academy.
# 4. Descobre o ID da conta (sts get-caller-identity, só com essas credenciais).
# 5. Atualiza no GitHub os secrets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#    AWS_SESSION_TOKEN e AWS_REGION e a variável AWS_ACCOUNT_ID.
# 6. Opcional (--kube): gera um kubeconfig próprio do projeto.
#
# Uso:
#   ./terraform/scripts/academy-session.sh            # lê da área de transferência
#   wl-paste | ./terraform/scripts/academy-session.sh -
#   ./terraform/scripts/academy-session.sh --kube     # também gera o kubeconfig
#   ./terraform/scripts/academy-session.sh --no-gh    # não mexe nos secrets do GitHub
# Depois, em cada terminal do projeto:
#   source .academy/env
set -euo pipefail

EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-654654158732}"
REGION="${AWS_REGION_ACADEMY:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-togglemaster-eks}"
PROFILE="academy"

READ_STDIN=false
UPDATE_GH=true
SETUP_KUBE=false
for arg in "$@"; do
  case "$arg" in
    -) READ_STDIN=true ;;
    --no-gh) UPDATE_GH=false ;;
    --kube) SETUP_KUBE=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
ACADEMY_DIR="$REPO_ROOT/.academy"
CREDS_FILE="$ACADEMY_DIR/credentials"
ENV_FILE="$ACADEMY_DIR/env"
KUBE_FILE="$ACADEMY_DIR/kubeconfig"

# --- 1. Ler o bloco de credenciais -------------------------------------------
read_clipboard() {
  if command -v wl-paste >/dev/null 2>&1 && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    wl-paste --no-newline
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output
  else
    return 1
  fi
}

if $READ_STDIN || [[ ! -t 0 ]]; then
  RAW="$(cat)"
elif ! RAW="$(read_clipboard 2>/dev/null)" || [[ -z "$RAW" ]]; then
  echo "Não consegui ler a área de transferência. Cole o bloco e tecle Ctrl+D:" >&2
  RAW="$(cat)"
fi

extract() {
  # Aceita "chave=valor" ou "chave = valor"; remove espaços e \r.
  printf '%s\n' "$RAW" | tr -d '\r' \
    | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | head -n1 | tr -d '[:space:]'
}

ACCESS_KEY="$(extract aws_access_key_id)"
SECRET_KEY="$(extract aws_secret_access_key)"
SESSION_TOKEN="$(extract aws_session_token)"
unset RAW

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || -z "$SESSION_TOKEN" ]]; then
  echo "ERRO: bloco incompleto. Copie tudo de 'AWS Details' -> 'AWS CLI: Show'" >&2
  echo "(aws_access_key_id, aws_secret_access_key e aws_session_token)." >&2
  exit 1
fi
if [[ "$ACCESS_KEY" != ASIA* ]]; then
  echo "ERRO: a access key não começa com ASIA; não parece credencial temporária do lab." >&2
  exit 1
fi

# --- 2. Gravar credenciais isoladas ------------------------------------------
umask 077
mkdir -p "$ACADEMY_DIR"
cat > "$CREDS_FILE" <<EOF
[$PROFILE]
aws_access_key_id = $ACCESS_KEY
aws_secret_access_key = $SECRET_KEY
aws_session_token = $SESSION_TOKEN
EOF
chmod 600 "$CREDS_FILE"

# --- 3. Arquivo de ambiente ----------------------------------------------------
cat > "$ENV_FILE" <<EOF
# Gerado por terraform/scripts/academy-session.sh — use com: source .academy/env
# Remove credenciais herdadas (variáveis de ambiente têm prioridade sobre o arquivo).
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
export AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE"
export AWS_CONFIG_FILE=/dev/null
export AWS_PROFILE="$PROFILE"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export KUBECONFIG="$KUBE_FILE"
EOF
chmod 600 "$ENV_FILE"
echo "Credenciais gravadas em $CREDS_FILE"

# --- 4. Conta AWS ----------------------------------------------------------------
# Subshell com o env do lab: não usa os profiles do ~/.aws.
ACCOUNT_ID=""
if command -v aws >/dev/null 2>&1; then
  ACCOUNT_ID="$( (source "$ENV_FILE" && aws sts get-caller-identity --query Account --output text) )" || {
    echo "ERRO: as credenciais não autenticaram (sts get-caller-identity falhou)." >&2
    exit 1
  }
  echo "Conta autenticada: $ACCOUNT_ID"
  if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
    echo "AVISO: conta diferente da esperada ($EXPECTED_ACCOUNT_ID). Defina EXPECTED_ACCOUNT_ID para silenciar." >&2
  fi
else
  echo "AVISO: AWS CLI não encontrado; variável AWS_ACCOUNT_ID do GitHub NÃO será atualizada." >&2
fi

# --- 5. Secrets e variável do GitHub -------------------------------------------
if $UPDATE_GH; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "AVISO: gh não encontrado; secrets do GitHub NÃO atualizados." >&2
  else
    cd "$REPO_ROOT"
    # Valores via stdin para não aparecerem no `ps`.
    printf '%s' "$ACCESS_KEY"    | gh secret set AWS_ACCESS_KEY_ID
    printf '%s' "$SECRET_KEY"    | gh secret set AWS_SECRET_ACCESS_KEY
    printf '%s' "$SESSION_TOKEN" | gh secret set AWS_SESSION_TOKEN
    printf '%s' "$REGION"        | gh secret set AWS_REGION
    echo "Secrets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN e AWS_REGION atualizados."
    if [[ -n "$ACCOUNT_ID" ]]; then
      gh variable set AWS_ACCOUNT_ID --body "$ACCOUNT_ID"
      echo "Variável AWS_ACCOUNT_ID = $ACCOUNT_ID"
    fi
  fi
fi

# --- 6. Kubeconfig do projeto (opcional) ----------------------------------------
if $SETUP_KUBE; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBE_FILE" >/dev/null
    echo "Kubeconfig do projeto gerado em $KUBE_FILE"
  else
    echo "Cluster $CLUSTER_NAME ainda não existe; rode o terraform apply e repita com --kube."
  fi
fi

echo
echo "Pronto. Em cada terminal do projeto rode:  source .academy/env"
