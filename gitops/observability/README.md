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
                        │     traces   ──otlp─────────────────▶ New Relic APM  (Etapa 2)            │
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
Alertas, New Relic, instrumentação e evidências finais pertencem às próximas
etapas; esta configuração ainda não representa a entrega completa.

O dashboard também inclui uma seção de saúde da coleta com targets dos
Collectors, falhas/recusas, fila/capacidade e memória RSS. Filas dependem do
exporter; ausência dessa métrica não equivale a uma fila vazia.

Os binários Go compilados foram retirados do código versionado; os Dockerfiles
continuam compilando em estágios próprios. `.gitignore` ignora esses artefatos.
