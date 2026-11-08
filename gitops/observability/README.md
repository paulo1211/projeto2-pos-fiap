# Observabilidade — ToggleMaster (Fase 4)

Stack open source de métricas, logs e traces, gerenciada 100% via GitOps
(ArgoCD), com o **OpenTelemetry Collector como peça central** de roteamento.

## Arquitetura

```
                        ┌──────────────────────── namespace observability ────────────────────────┐
 microsserviços ──OTLP──▶ otel-gateway (Deployment)                                                │
 (traces/métricas/logs) │   receivers: otlp                                                        │
                        │   processors: memory_limiter, k8sattributes, transform, batch                       │
 otel-agent (DaemonSet)─▶   connectors: spanmetrics (traces ──▶ métricas RED)                      │
   filelog /var/log/pods│   exporters:                                                             │
   (logs de TODOS os    │     métricas ──prometheusremotewrite──▶ Prometheus (kps-prometheus:9090)  │
   contêineres)         │     logs     ──otlphttp──────────────▶ Loki (loki:3100/otlp)              │
                        │     traces   ──otlphttp─────────────▶ New Relic APM (otlp.nr-data.net)    │
                        │                                                                          │
                        │ Prometheus ◀── scrape ── kube-state-metrics / node-exporter / cAdvisor    │
                        │ Grafana (ClusterIP) ── datasources: Prometheus + Loki                  │
                        └──────────────────────────────────────────────────────────────────────────┘
```

- **otel-agent** (DaemonSet): um por nó; coleta os logs de todos os
  contêineres do cluster, enriquece com metadados do Kubernetes e encaminha
  por OTLP para o gateway. Não fala com nenhum backend diretamente.
- **otel-gateway** (Deployment): ponto único de entrada de telemetria; decide
  para onde cada sinal vai. Trocar/adicionar backend (ex.: New Relic) é uma
  mudança só neste arquivo, sem tocar nos microsserviços.
- **spanmetrics**: gera `traces_span_metrics_calls_total` e
  `traces_span_metrics_duration_milliseconds_bucket` a partir dos spans recebidos; os painéis filtram spans
  SERVER — as mesmas métricas para Go e Python. É daí que vêm os painéis de
  taxa de requisições, erros 5xx e latência, e o alerta de 5xx (Etapa 3).
- **Infraestrutura do cluster** (CPU/memória de nós e pods, réplicas,
  restarts) vem do kube-state-metrics, node-exporter e cAdvisor raspados pelo
  próprio Prometheus.

## Arquivos

| Arquivo | O quê |
|---|---|
| `../argocd-apps/10-observability-base-app.yaml` | namespace + dashboards (esta pasta, via kustomize) |
| `../argocd-apps/11-kube-prometheus-stack-app.yaml` | Prometheus + Grafana + exporters (chart 65.1.1) |
| `../argocd-apps/12-loki-app.yaml` | Loki SingleBinary (chart 6.16.0) |
| `../argocd-apps/13-otel-gateway-app.yaml` | OTel Collector gateway (chart 0.108.0) |
| `../argocd-apps/14-otel-agent-app.yaml` | OTel Collector agent (chart 0.108.0) |
| `values/*.yaml` | values de cada chart (lidos pelas Applications via multi-source `$values`) |
| `dashboards/togglemaster-overview.json` | dashboard "ToggleMaster — Saúde do Ecossistema" |

## Acesso

```bash
# senha do admin (Secret criado por terraform/scripts/sync-observability-secrets.sh)
kubectl get secret grafana-admin -n observability -o jsonpath='{.data.admin-password}' | base64 -d

# Acesso em http://localhost:3000 (manter o comando em execução)
kubectl -n observability port-forward svc/grafana 3000:80
```

Logs no Grafana → Explore → Loki, por exemplo:

```logql
{k8s_namespace_name="togglemaster", service_name="auth-service"} |= "error"
```

## Limitações conscientes (ambiente de estudo)

- Prometheus e Loki usam `emptyDir` (o cluster não tem EBS CSI driver):
  os dados se perdem se o pod for substituído. A retenção de 3 dias é um
  limite máximo, não uma garantia de histórico. Grafana também é efêmero;
  dashboards/datasources são restaurados pelo GitOps. PVCs requerem uma
  etapa de infraestrutura com storage driver, StorageClass e permissões.
- Alertmanager desligado: os alertas são feitos no Grafana Alerting.

## Bootstrap e validação da Etapa 1

1. Execute `terraform/scripts/sync-secrets.sh` para os Secrets das aplicações.
   As chaves existentes são preservadas. `ROTATE_APP_KEYS=true` é uma rotação
   explícita: exige atualizar consumidores e coordenar o restart dos pods.
2. Execute `terraform/scripts/sync-observability-secrets.sh` para criar o
   Secret do Grafana. `GRAFANA_ADMIN_PASSWORD` é opcional na criação inicial.
   Secrets existentes são preservados; falhas de acesso ao Kubernetes abortam.
   Para uma base Grafana já inicializada, mudar apenas o Secret não rotaciona
   a senha: use a API/CLI administrativa do Grafana e atualize o Secret.
3. Aplique as Applications com o bootstrap existente. Aguarde primeiro a
   stack `kube-prometheus-stack` instalar as CRDs de monitoramento, depois
   sincronize agent/gateway. Os números dos arquivos não ordenam Applications
   independentes; repita o sync se PodMonitor ainda não tiver CRD disponível.
4. No Prometheus, confirme os targets dos Collectors na porta 8888 e consulte
   `up{namespace="observability"}`. Inspecione as métricas internas
   `otelcol_exporter_send_failed_log_records`,
   `otelcol_exporter_send_failed_spans`, `otelcol_exporter_send_failed_metric_points`,
   `otelcol_processor_refused_log_records`, `otelcol_exporter_queue_size` e
   `otelcol_process_memory_rss`; confira nomes/labels no endpoint `/metrics`.
5. No Loki, confirme os logs das aplicações e dos próprios Collectors:
   `{k8s_namespace_name="observability", service_name=~"otel-agent|otel-gateway"}`.
   O gateway deriva `service.name` do workload quando ausente, sem substituir
   identidade enviada pelo SDK. Os Collectors não usam o exporter `debug`,
   evitando reexportar payloads de telemetria como logs.
6. O agent mantém checkpoints em `/var/lib/otelcol` no próprio nó (o preset
   usa root para escrever nesse hostPath). Reinícios no mesmo nó retomam o
   offset; substituição do nó perde checkpoints. Na primeira leitura coleta
   o histórico ainda disponível em `/var/log/pods`; rotação/remoção de arquivos
   e indisponibilidade prolongada ainda podem causar perda. Não há garantia
   de entrega exatamente uma vez nem fila persistente nos exporters.
7. Na Etapa 2, gere tráfego e verifique métricas RED: com tráfego sem 5xx,
   erros devem mostrar 0%; sem tráfego ou sem telemetria, mostrar sem dados.
   `transform/http` normaliza a convenção antiga antes do spanmetrics,
   evitando subcontagem de instâncias com convenções distintas. Não aplicar
   sampling antes do spanmetrics se a intenção for medir todo o tráfego.

Prometheus coleta diretamente infraestrutura e métricas internas do Collector;
a telemetria das aplicações passa pelo gateway. Métricas OTLP devem usar
temporality cumulativa para o exporter remote-write desta versão. Somente
identidade de serviço/namespace/pod é promovida dos recursos a labels, além das
dimensões próprias das métricas. Pod distingue contadores de réplicas diferentes;
evite IDs de usuário e URLs dinâmicas.

O número de pods e requests precisa ser conferido após o sync, inclusive
durante atualizações. O tipo `t3.large` por si só não garante capacidade.
Alertas, PagerDuty/Discord, self-healing e evidências finais pertencem à
Etapa 3; esta configuração ainda não representa a entrega completa.

O dashboard também inclui uma seção de saúde da coleta com targets dos
Collectors, falhas/recusas, fila/capacidade e memória RSS. Filas dependem do
exporter; ausência dessa métrica não equivale a uma fila vazia.

Os binários Go compilados foram retirados do código versionado; os Dockerfiles
continuam compilando em estágios próprios. `.gitignore` ignora esses artefatos.

## Instrumentação e APM (Etapa 2)

Os 5 microsserviços enviam traces e métricas por **OTLP/HTTP** ao
`otel-gateway` (`OTEL_EXPORTER_OTLP_ENDPOINT` no ConfigMap
`togglemaster-config`). O gateway envia os traces ao **New Relic** e ao
connector spanmetrics. Os logs continuam saindo em stdout (coletados pelo
otel-agent); nos serviços Python e nos logs Go associados às requisições há
`trace_id`/`span_id`. Logs de inicialização fora de um trace não têm essa correlação.

| Serviço | Instrumentação | Spans gerados |
|---|---|---|
| evaluation-service (Go) | `otelhttp` no servidor e no client HTTP; spans manuais de Redis e SQS | `GET /evaluate` → `redis GET/SET`, `GET` (CLIENT) → flag/targeting, `<fila> publish` (PRODUCER) |
| auth-service (Go) | `otelhttp` no servidor; spans manuais de PostgreSQL | `GET /validate` → `SELECT api_keys` |
| flag-service / targeting-service (Python) | Flask, requests, psycopg2 | `GET /flags/<name>` → `GET` (CLIENT) → auth, `SELECT` |
| analytics-service (Python) | botocore + span CONSUMER manual | `<fila> process` (CONSUMER) → `DynamoDB.PutItem`, `SQS.DeleteMessage` |

**Caminho de uma requisição** (um único trace):

```
GET /evaluate (evaluation-service)
├── redis GET (cache)
├── GET flag-service ──▶ GET /flags/<name> (flag-service) ──▶ GET /validate (auth-service) ──▶ SELECT api_keys
├── GET targeting-service ──▶ GET /rules/<flag> (targeting-service) ──▶ GET /validate (auth-service)
├── redis SET
└── <fila> publish (SQS) ──traceparent nos MessageAttributes──▶ <fila> process (analytics-service) ──▶ DynamoDB.PutItem
```

O `traceparent` (W3C) segue em headers HTTP entre os serviços e nos
**MessageAttributes do SQS** entre o evaluation-service e o analytics-service.
É isso que liga os 5 serviços no Service Map do New Relic.

### Configurar o New Relic

1. Criar a conta e copiar a **License Key** do tipo *INGEST - LICENSE*
   (API Keys no menu do usuário).
2. Criar o Secret, sem gravar a chave em arquivo:
   ```bash
   read -rs NEW_RELIC_LICENSE_KEY && export NEW_RELIC_LICENSE_KEY
   terraform/scripts/sync-observability-secrets.sh
   kubectl -n observability rollout restart deployment/otel-gateway
   ```
3. Conta na região **EU**: troque o endpoint de `otlphttp/newrelic` em
   `values/otel-gateway.yaml` para `https://otlp.eu01.nr-data.net`.

Sem o Secret, o gateway sobe mesmo assim (a referência é `optional`).
Métricas e logs continuam funcionando, e só o envio ao New Relic falha (403).

### Validar

```bash
# requisição de teste (de dentro do cluster)
kubectl -n togglemaster run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s "http://evaluation-service:8004/evaluate?user_id=u1&flag_name=<flag>"
```

- New Relic → APM & Services → `evaluation-service` → Distributed tracing:
  com uma flag existente e cache miss, o trace deve conter spans dos 5 serviços.
  Aguarde o consumo da fila e a exportação, considerando inicialização pelo KEDA
  e atraso de ingestão do APM; não há garantia de aparecer em 20 segundos.
- New Relic → Service map: arestas evaluation → flag/targeting → auth e
  evaluation → analytics (via SQS).
- Grafana → dashboard "ToggleMaster — Saúde do Ecossistema": requisições/s,
  % de 5xx e latência p95 por serviço (spanmetrics).
- Falhas de envio ao New Relic: `otelcol_exporter_send_failed_spans{exporter="otlphttp/newrelic"}`
  e os logs do `otel-gateway` no Loki.

### Decisões e limitações

- **SDK programático** (`telemetry.py` / `telemetry.go`) em vez de
  auto-instrumentação por `opentelemetry-instrument`. O SDK inicializa dentro
  do worker do gunicorn (sem `--preload`), o que evita problemas de fork com as
  threads dos exporters, e deixa explícitos o filtro do `/health` e o
  `skip_dep_check` do psycopg2 (os serviços usam `psycopg2-binary`).
- **Redis (go-redis v8) e PostgreSQL (pgx v4)** não têm instrumentação
  compatível com o OTel Go v1.32, então os spans são manuais e só registram
  operação e tabela, sem a query completa.
- O `/health` não gera spans (probes do Kubernetes), e o long-poll do SQS é
  suprimido; os traces do analytics começam em cada mensagem.
- `otelhttp` (Go) e as instrumentações Python emitem a semconv HTTP antiga; o
  `transform/http` do gateway normaliza antes do spanmetrics.
- Sampling explicitamente `AlwaysOn` nos SDKs Go/Python, inclusive para
  `traceparent` remoto não amostrado. Essa política prevalece sobre
  `OTEL_TRACES_SAMPLER`, pois os painéis/alertas RED dependem dos spans.
  Não garante entrega em caso de saturação/falha dos exporters. Avalie consumo
  e limites da conta; não há garantia prévia de permanecer na cota gratuita.
- `OTEL_SDK_DISABLED=true` desliga a exportação (usado no `docker-compose.yml`
  local, que não tem Collector).
- Falha de banco no auth-service agora responde **503**, e não mais 401
  "chave inválida". O flag-service e o targeting-service repassam um 5xx do
  auth como 503. Assim a falha aparece como erro nos traces, no dashboard e no
  alerta da Etapa 3.

### Correções e testes da instrumentação

- `.env` é carregado antes do SDK nos serviços Python. O filtro exclui
  somente a URL de `/health` (com ou sem query), preservando flags e parâmetros
  que contenham a palavra `health`.
- Os spans HTTP Go usam o padrão registrado no ServeMux; rotas desconhecidas
  usam apenas o método. Não há caminho arbitrário no nome do span.
- Publicações SQS têm timeout próprio de 5 s, preservam o contexto do trace
  sem herdar o cancelamento HTTP e são acompanhadas para drenagem.
- Go: orçamento de até 10 s para HTTP, mais até 6 s para publicações no
  evaluation-service e 5 s para encerrar traces/métricas em paralelo.
  Os pods Go têm `terminationGracePeriodSeconds: 30`.
- Python: `gunicorn.conf.py` inicia o consumidor em `post_worker_init` e
  encerra em `worker_exit`, sem substituir handlers de sinais. Ao parar,
  o analytics não inicia novas mensagens, aguarda a atual por até 20 s e
  depois encerra os providers em paralelo por até 5 s. O gunicorn tem prazo
  de 35 s e os pods Python 45 s. Interrupção forçada ainda pode perder spans;
  mensagens não confirmadas podem ser reentregues pela SQS.
- O polling SQS espera até 5 s; os clientes têm connect/read timeouts
  explícitos e uma tentativa por operação para limitar a parada. Falhas
  de processamento deixam a mensagem na fila para reentrega. Isso não
  implementa idempotência: uma falha após PutItem e antes de DeleteMessage
  ainda pode causar duplicação, como na implementação anterior.
- Em gunicorn, use o Dockerfile atualizado (config explícita). Localmente,
  execute `python app.py` para iniciar o consumidor analytics; importar o módulo
  ou usar `flask run` não inicia mais a thread automaticamente.
- O dashboard mantém os painéis HTTP e adiciona uma seção própria do analytics:
  mensagens/s, taxa de erro baseada no status do span CONSUMER e p95.
  Essa seção não depende do filtro `$service` dos painéis HTTP.

Para demonstrar os 5 serviços em um trace, crie uma flag e uma regra válidas,
configure a chave de serviço e espere o TTL de cache de 30 s sem chamadas
para essa flag (ou use outra flag preparada ainda não consultada). Uma
requisição com cache hit omite flag, targeting e auth por comportamento normal.
Depois aguarde o analytics consumir a mensagem e procure o mesmo trace ID no APM.
O mapa de serviços e o comportamento real do New Relic ainda precisam de
validação com a conta e o cluster; um receptor OTLP simulado não comprova a UI.

Testes reproduzíveis no repositório (sem AWS, Kubernetes ou New Relic):

```bash
# Dentro de cada serviço Go
go test ./...
go vet ./...

# Dentro de cada serviço Python, com seu requirements.txt instalado
python -m pip install pytest
python -m pytest -q
```

Os testes cobrem exclusão exata de health, parent não amostrado, propagação
HTTP e SQS, erro do consumidor, nomes de spans, prazo de flush e drenagem.
O analytics inclui um teste com gunicorn real, SIGTERM e receiver OTLP local;
somente as chamadas AWS são simuladas. O workflow Python existente já executa
esses testes. Não há teste de integração real com a conta do New Relic.
