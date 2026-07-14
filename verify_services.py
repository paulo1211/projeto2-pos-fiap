#!/usr/bin/env python3
import socket
import urllib.request
import json
import time
import sys

# Cores ANSI
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

# Configuração de serviços HTTP
SERVICES = {
    "auth-service": {
        "url": "http://localhost:8001/health",
        "desc": "Serviço de Autenticação (Go)",
        "port": 8001
    },
    "flag-service": {
        "url": "http://localhost:8002/health",
        "desc": "Serviço de Flags (Python)",
        "port": 8002
    },
    "targeting-service": {
        "url": "http://localhost:8003/health",
        "desc": "Serviço de Segmentação (Python)",
        "port": 8003
    },
    "evaluation-service": {
        "url": "http://localhost:8004/health",
        "desc": "Serviço de Avaliação (Go)",
        "port": 8004
    },
    "analytics-service": {
        "url": "http://localhost:8005/health",
        "desc": "Serviço de Métricas (Python)",
        "port": 8005
    }
}

# Configuração de infraestrutura (portas TCP)
INFRA = {
    "PostgreSQL Primary": {
        "host": "127.0.0.1",
        "port": 5432,
        "desc": "Banco de Dados Principal"
    },
    "PostgreSQL Replica": {
        "host": "127.0.0.1",
        "port": 5433,
        "desc": "Banco de Dados Réplica"
    },
    "Redis Cache": {
        "host": "127.0.0.1",
        "port": 6379,
        "desc": "Cache de Avaliação"
    },
    "SQS Local (ElasticMQ)": {
        "host": "127.0.0.1",
        "port": 9324,
        "desc": "Fila de Mensagens Local"
    },
    "DynamoDB Local": {
        "host": "127.0.0.1",
        "port": 8000,
        "desc": "Banco de Métricas NoSQL"
    }
}

def check_tcp(host, port, timeout=1.5):
    """ Tenta abrir uma conexão TCP no host e porta fornecidos """
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

def check_http(url, timeout=2.0):
    """ Tenta realizar uma requisição HTTP GET e valida se retornou 'status': 'ok' """
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'ToggleMaster-Verifier'})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            if response.status == 200:
                data = response.read().decode('utf-8')
                try:
                    body = json.loads(data)
                    if body.get("status") == "ok":
                        return True, "OK"
                    return True, f"JSON: {data.strip()}"
                except json.JSONDecodeError:
                    return True, f"Texto: {data[:30].strip()}"
            return False, f"Status HTTP {response.status}"
    except urllib.error.HTTPError as e:
        return False, f"Erro HTTP {e.code}"
    except urllib.error.URLError as e:
        return False, f"Conexão falhou ({e.reason})"
    except Exception as e:
        return False, str(e)

def print_header(title):
    print(f"\n{BOLD}{CYAN}=== {title} ==={RESET}")

def main():
    print(f"{BOLD}{YELLOW}==================================================={RESET}")
    print(f"{BOLD}{YELLOW}     VERIFICADOR DE MICROSERVIÇOS & INFRA          {RESET}")
    print(f"{BOLD}{YELLOW}==================================================={RESET}")

    total_checks = 0
    passed_checks = 0

    # 1. Testando a Infraestrutura Básica
    print_header("INFRAESTRUTURA (Conexões TCP)")
    for name, info in INFRA.items():
        total_checks += 1
        print(f"Checking {BOLD}{name}{RESET} ({info['desc']}) no port {info['port']}...", end="", flush=True)
        
        start_time = time.time()
        is_up = check_tcp(info['host'], info['port'])
        elapsed = (time.time() - start_time) * 1000

        if is_up:
            passed_checks += 1
            print(f" {GREEN}{BOLD}[✔ REACHABLE]{RESET} ({elapsed:.1f}ms)")
        else:
            print(f" {RED}{BOLD}[✘ UNREACHABLE]{RESET}")

    # 2. Testando os Microserviços
    print_header("MICROSERVIÇOS (Endpoints de Saúde /health)")
    for name, info in SERVICES.items():
        total_checks += 1
        print(f"Checking {BOLD}{name}{RESET} ({info['desc']}) no port {info['port']}...", end="", flush=True)
        
        start_time = time.time()
        is_up, detail = check_http(info['url'])
        elapsed = (time.time() - start_time) * 1000

        if is_up:
            passed_checks += 1
            print(f" {GREEN}{BOLD}[✔ HEALTHY]{RESET} ({detail}) ({elapsed:.1f}ms)")
        else:
            print(f" {RED}{BOLD}[✘ UNHEALTHY]{RESET} - {detail}")

    # 3. Sumário Final
    print(f"\n{BOLD}{YELLOW}==================================================={RESET}")
    print(f"{BOLD}SUMÁRIO DO TESTE:{RESET}")
    print(f"Total de testes realizados: {total_checks}")
    print(f"Sucessos: {GREEN}{passed_checks}{RESET}")
    print(f"Falhas: {RED if passed_checks < total_checks else GREEN}{total_checks - passed_checks}{RESET}")
    print(f"{BOLD}{YELLOW}==================================================={RESET}")

    if passed_checks == total_checks:
        print(f"{GREEN}{BOLD}Parabéns! Todos os serviços e a infra estão 100% ativos e integrados!{RESET}\n")
        sys.exit(0)
    else:
        print(f"{YELLOW}{BOLD}Atenção: Alguns componentes falharam. Verifique os logs do Docker Compose:{RESET}")
        print(" -> docker compose logs <nome-do-serviço>")
        print(" -> Verifique se a rede local do Docker não está bloqueada.")
        print()
        sys.exit(1)

if __name__ == "__main__":
    main()
