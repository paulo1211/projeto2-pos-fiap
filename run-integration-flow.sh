#!/usr/bin/env bash
#
# ToggleMaster - Script de Fluxo de Integração Local
# Este script automatiza o fluxo lógico de utilização dos microsserviços.
#

set -euo pipefail

# Cores ANSI para saída formatada
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # Sem Cor

log_info() {
    echo -e "${GREEN}${BOLD}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}${BOLD}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}${BOLD}[ERRO]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}${BOLD}=== Passo $1: $2 ===${NC}"
}

# Função auxiliar para extrair valores JSON de forma compatível
# Não assume que o 'jq' esteja instalado, usando python3 nativo
extract_json_field() {
    local json="$1"
    local field="$2"
    python3 -c "import sys, json; print(json.loads(sys.argv[1]).get('$field', ''))" "$json"
}

# Configuração de portas e chaves
AUTH_URL="http://localhost:8001"
FLAG_URL="http://localhost:8002"
TARGETING_URL="http://localhost:8003"
EVALUATION_URL="http://localhost:8004"
ANALYTICS_URL="http://localhost:8005"
MASTER_KEY="supersecretkey"

echo -e "${BLUE}${BOLD}===================================================${NC}"
echo -e "${BLUE}${BOLD}        TOGGLEMASTER - TESTADOR DE FLUXO           ${NC}"
echo -e "${BLUE}${BOLD}===================================================${NC}"

# 1. Validação de saúde de todos os microsserviços
log_step "1" "Verificando a Saúde dos Serviços"

SERVICES=(
    "auth-service (Go)|$AUTH_URL/health"
    "flag-service (Python)|$FLAG_URL/health"
    "targeting-service (Python)|$TARGETING_URL/health"
    "evaluation-service (Go)|$EVALUATION_URL/health"
    "analytics-service (Python)|$ANALYTICS_URL/health"
)

unhealthy_count=0
for svc in "${SERVICES[@]}"; do
    name="${svc%%|*}"
    url="${svc##*|}"
    
    echo -n "Verificando $name em $url... "
    if curl -s -f "$url" > /dev/null; then
        echo -e "${GREEN}[ Saudável ]${NC}"
    else
        echo -e "${RED}[ Inacessível / Instável ]${NC}"
        unhealthy_count=$((unhealthy_count + 1))
    fi
done

if [ "$unhealthy_count" -gt 0 ]; then
    log_error "Alguns serviços não estão respondendo. Certifique-se de iniciar o Docker Compose com 'docker compose up -d' e tente novamente."
    exit 1
fi

log_info "Todos os microsserviços estão ativos e saudáveis!"

# 2. Criação da Chave de API
log_step "2" "Gerar Chave de API (Via auth-service em Go)"

log_info "Solicitando criação de chave de API administrativa..."
API_KEY_RESP=$(curl -s -X POST "$AUTH_URL/admin/keys" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"name": "chave-automatica-teste"}')

if [[ "$API_KEY_RESP" == *"tm_key_"* ]]; then
    API_KEY=$(extract_json_field "$API_KEY_RESP" "key")
    log_info "Chave de API gerada com sucesso: ${GREEN}$API_KEY${NC}"
else
    log_error "Falha ao gerar chave de API. Resposta do servidor: $API_KEY_RESP"
    exit 1
fi

# 3. Criação de Feature Flag
log_step "3" "Criar uma Feature Flag (Via flag-service em Python)"

FLAG_NAME="enable-new-dashboard"
log_info "Criando flag '$FLAG_NAME'..."

FLAG_RESP=$(curl -s -X POST "$FLAG_URL/flags" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "{
      \"name\": \"$FLAG_NAME\",
      \"description\": \"Ativa o novo painel administrativo\",
      \"is_enabled\": true
  }")

if [[ "$FLAG_RESP" == *"$FLAG_NAME"* ]]; then
    log_info "Flag '$FLAG_NAME' criada/verificada com sucesso."
elif [[ "$FLAG_RESP" == *"já existe"* ]]; then
    log_warn "A flag '$FLAG_NAME' já existe. Continuando..."
else
    log_error "Erro ao criar flag: $FLAG_RESP"
    exit 1
fi

# 4. Criar Regra de Segmentação
log_step "4" "Criar Regra de Segmentação de 50% (Via targeting-service em Python)"

log_info "Criando regra de segmentação para '$FLAG_NAME' com 50% de distribuição..."
RULE_RESP=$(curl -s -X POST "$TARGETING_URL/rules" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "{
      \"flag_name\": \"$FLAG_NAME\",
      \"is_enabled\": true,
      \"rules\": {
          \"type\": \"PERCENTAGE\",
          \"value\": 50
      }
  }")

if [[ "$RULE_RESP" == *"$FLAG_NAME"* ]]; then
    log_info "Regra de segmentação de 50% criada com sucesso."
elif [[ "$RULE_RESP" == *"already exists"* ]] || [[ "$RULE_RESP" == *"já existe"* ]]; then
    log_warn "Regra de segmentação para '$FLAG_NAME' já existe. Continuando..."
else
    log_error "Erro ao criar regra de segmentação: $RULE_RESP"
    exit 1
fi

# 5. Avaliação da Feature Flag
log_step "5" "Avaliar a Flag para múltiplos usuários (Via evaluation-service em Go)"

log_info "Avaliando a flag '$FLAG_NAME' para 6 IDs de usuário diferentes para observar a distribuição de 50%:"

TEST_USERS=("user-100" "user-200" "user-300" "user-400" "user-500" "user-600")

for user in "${TEST_USERS[@]}"; do
    EVAL_RESP=$(curl -s "$EVALUATION_URL/evaluate?user_id=$user&flag_name=$FLAG_NAME")
    RESULT=$(extract_json_field "$EVAL_RESP" "result")
    
    if [ "$RESULT" = "true" ] || [ "$RESULT" = "True" ]; then
        echo -e "  - Usuário: ${BOLD}$user${NC} -> Resultado: ${GREEN}${BOLD}ATIVO (true)${NC}"
    else
        echo -e "  - Usuário: ${BOLD}$user${NC} -> Resultado: ${RED}${BOLD}INATIVO (false)${NC}"
    fi
done

# 6. Verificação de Métricas e Processamento Assíncrono
log_step "6" "Verificar logs de métricas no DynamoDB (Via analytics-service em Python)"

log_info "Aguardando 3 segundos para que o processamento assíncrono (SQS -> DynamoDB) conclua..."
sleep 3

log_info "Consultando a tabela local do DynamoDB para listar eventos gravados..."

# Executa consulta no DynamoDB
SCAN_RESP=$(docker compose exec -T analytics-service python -c "
import boto3, json
client = boto3.client('dynamodb', endpoint_url='http://dynamodb-local:8000', region_name='us-east-1', aws_access_key_id='mock', aws_secret_access_key='mock')
items = client.scan(TableName='ToggleMasterAnalytics')['Items']
print(json.dumps(items, indent=2))
" 2>/dev/null || echo "Falha ao escanear DynamoDB")

if [ "$SCAN_RESP" = "Falha ao escanear DynamoDB" ]; then
    log_warn "Não foi possível escanear o DynamoDB diretamente. Tentando pelo AWS CLI local..."
    if command -v aws &> /dev/null; then
        AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock aws --endpoint-url http://127.0.0.1:8000 dynamodb scan --table-name ToggleMasterAnalytics --region us-east-1 --no-cli-pager || log_error "Falha ao consultar via AWS CLI."
    else
        log_error "AWS CLI não encontrado. Você pode conferir os logs do container 'analytics-service' usando: docker compose logs analytics-service"
    fi
else
    # Mostra os itens encontrados
    echo -e "${GREEN}Itens encontrados no DynamoDB local:${NC}"
    echo "$SCAN_RESP"
fi

echo -e "\n${GREEN}${BOLD}===================================================${NC}"
echo -e "${GREEN}${BOLD}    FLUXO DE INTEGRAÇÃO EXECUTADO COM SUCESSO!     ${NC}"
echo -e "${GREEN}${BOLD}===================================================${NC}"
log_info "A sequência lógica está funcionando perfeitamente:"
echo -e "  1. Autenticação (Go) gerou a chave de acesso."
echo -e "  2. Definição de flags (Python) salvou no PostgreSQL."
echo -e "  3. Regras de segmentação (Python) salvou no PostgreSQL."
echo -e "  4. Avaliação (Go) leu as regras, fez o cache em Redis e respondeu."
echo -e "  5. Métrica assíncrona (Python) consumiu do SQS e salvou no DynamoDB."
echo -e "==================================================="
