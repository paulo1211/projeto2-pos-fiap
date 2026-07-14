#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_TAG="${VERSION_TAG:-0.1}"
REGISTRY="${ECR_REGISTRY:-}"
REPOSITORY_PREFIX="${ECR_REPOSITORY_PREFIX:-}"
NO_CACHE="false"

usage() {
    cat <<'EOF'
Uso: ./build-all-dockerfiles.sh [--no-cache] [--tag VERSION] [--registry URI] [--repository-prefix PREFIXO]

Builda todos os Dockerfiles dos servicos do projeto.

Opcoes:
  --no-cache      Executa o docker build sem usar cache.
  --tag VERSION   Define a tag das imagens. Padrao: 0.1 ou $VERSION_TAG.
    --registry URI  Define o registry alvo. Ex.: 123456789012.dkr.ecr.us-east-1.amazonaws.com
    --repository-prefix PREFIXO
                                    Prefixo opcional para os repositorios. Ex.: tech-challenger
  -h, --help      Exibe esta ajuda.

Variaveis de ambiente:
    ECR_REGISTRY            Registry padrao quando --registry nao for informado.
    ECR_REPOSITORY_PREFIX   Prefixo padrao quando --repository-prefix nao for informado.
EOF
}

SERVICE_DIRS=(
    "analytics-service"
    "auth-service"
    "evaluation-service"
    "flag-service"
    "targeting-service"
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache)
            NO_CACHE="true"
            shift
            ;;
        --tag)
            if [[ $# -lt 2 ]]; then
                echo "Erro: informe um valor para --tag." >&2
                exit 1
            fi
            VERSION_TAG="$2"
            shift 2
            ;;
        --registry)
            if [[ $# -lt 2 ]]; then
                echo "Erro: informe um valor para --registry." >&2
                exit 1
            fi
            REGISTRY="$2"
            shift 2
            ;;
        --repository-prefix)
            if [[ $# -lt 2 ]]; then
                echo "Erro: informe um valor para --repository-prefix." >&2
                exit 1
            fi
            REPOSITORY_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Erro: opcao desconhecida '$1'." >&2
            usage >&2
            exit 1
            ;;
    esac
done

BUILD_ARGS=()
if [[ "$NO_CACHE" == "true" ]]; then
    BUILD_ARGS+=(--no-cache)
fi

REGISTRY="${REGISTRY%/}"
REPOSITORY_PREFIX="${REPOSITORY_PREFIX#/}"
REPOSITORY_PREFIX="${REPOSITORY_PREFIX%/}"

for service_dir in "${SERVICE_DIRS[@]}"; do
    dockerfile_path="$ROOT_DIR/$service_dir/Dockerfile"

    if [[ ! -f "$dockerfile_path" ]]; then
        echo "Aviso: Dockerfile nao encontrado em $service_dir. Pulando." >&2
        continue
    fi

    repository_name="$service_dir"
    if [[ -n "$REPOSITORY_PREFIX" ]]; then
        repository_name="$REPOSITORY_PREFIX/$repository_name"
    fi

    image_name="$repository_name:$VERSION_TAG"
    if [[ -n "$REGISTRY" ]]; then
        image_name="$REGISTRY/$image_name"
    fi

    echo "==> Building $image_name"
    docker build "${BUILD_ARGS[@]}" -t "$image_name" "$ROOT_DIR/$service_dir"
done

echo "Build finalizado para todos os Dockerfiles encontrados."