# Alertas inteligentes e Self-Healing — ToggleMaster (Fase 4, Etapa 3)

```
 traces ─▶ otel-gateway ─spanmetrics─▶ Prometheus ◀── regra do Grafana (30 s)
                                                     "5xx do auth-service > 5% por 1 min"
                                                              │ Firing
                                   contact point togglemaster-incident
                    ┌──────────────────────────┼──────────────────────────┐
                    ▼                          ▼                          ▼
          PagerDuty (Events v2)        Discord (ChatOps)        webhook → runbook self-healing
          abre/resolve incidente       mensagem detalhada       (namespace observability)
                                                                 │ ServiceAccount + Role mínima
                                                                 ▼
                                             kubectl rollout restart deployment/auth-service
```

| Peça | Arquivo |
|---|---|
| Regra de alerta | `gitops/observability/alerting/rules.yaml` |
| Contact points (PagerDuty, Discord, webhook) | `gitops/observability/alerting/contact-points.yaml` |
| Política de notificação | `gitops/observability/alerting/policies.yaml` |
| Runbook (Python, só biblioteca padrão) | `gitops/self-healing/runbook.py` |
| ServiceAccount, Role e RoleBinding | `gitops/self-healing/rbac.yaml` |
| Deployment e Service do runbook | `gitops/self-healing/deployment.yaml` |
| Application do ArgoCD | `gitops/argocd-apps/15-self-healing-app.yaml` |
| Segredos (PagerDuty, Discord, token) | `terraform/scripts/sync-alerting-secrets.sh` |
| Falha proposital e demonstração | `auth-service` `POST /admin/chaos` + `./demo-incident.sh` |

## Decisões

- **Alerta inteligente, sem alert fatigue:** taxa (não contagem) de 5xx nos
  spans SERVER do auth-service em 2 min; exige volume mínimo (> 0,1 req/s);
  precisa se manter por 1 min (`for`); sem tráfego = Normal; o mesmo
  incidente só é renotificado após 4 h.
- **PagerDuty em vez de OpsGenie:** integração nativa do Grafana (Events API
  v2) com abertura e resolução automáticas do incidente; plano gratuito
  suficiente; a Atlassian anunciou o fim da venda do OpsGenie (migração
  para o Jira Service Management).
- **Runbook no cluster em vez de GitHub Action/Lambda:** o Grafana 11.2 não
  monta o corpo que a API `repository_dispatch` do GitHub exige, e no AWS
  Academy não há OIDC/IRSA nem credenciais duradouras para uma automação
  externa. O runbook fala com a API do Kubernetes usando o próprio
  ServiceAccount, que só pode `get`/`patch` no deployment `auth-service`.
- **Proteções do runbook:** token Bearer compartilhado com o Grafana,
  allowlist de namespace/deployment (igual ao RBAC), cooldown de 5 min por
  deployment e acompanhamento do rollout até os pods novos ficarem
  disponíveis; cada ação é registrada no log (Loki) e no Discord.
- **Falha que só um restart cura:** `POST /admin/chaos` (protegido pela
  MASTER_KEY) faz o `/validate` responder 500 a partir da memória do pod. O
  `/health` continua 200, então liveness/readiness não percebem; quem detecta
  é o alerta de 5xx, e o rollout restart cria pods limpos.

## Configuração (uma vez por ambiente)

1. **PagerDuty:** crie uma conta (plano Free) → *Services → New Service* →
   em *Integrations* escolha **Events API V2** → copie a *Integration Key*
   (32 caracteres).
2. **Discord:** no canal, *Editar canal → Integrações → Webhooks → Novo
   webhook → Copiar URL do webhook*.
3. Segredos (perguntados sem eco; nada vai para o git):
   ```bash
   source .academy/env
   ./terraform/scripts/sync-alerting-secrets.sh
   ```
4. Application do runbook (o bootstrap original só aplicou as 00–14):
   ```bash
   kubectl apply -f gitops/argocd-apps/15-self-healing-app.yaml
   ```
5. A imagem do auth-service com `/admin/chaos` é publicada pelo CI no merge
   para a `main` (o workflow atualiza a tag em `gitops/apps/auth-service`).

Conferir: Grafana → *Alerting → Alert rules* (pasta *ToggleMaster Alertas*)
e *Contact points → togglemaster-incident* (botão *Test* envia uma
notificação de teste para as três integrações — o runbook a ignora porque o
alerta de teste não tem o label `deployment`).

## Demonstração

```bash
source .academy/env
./demo-incident.sh
```

Linha do tempo típica: falha injetada → ~1,5–2 min até *Firing* (janela
de 2 min + `for: 1m`) → PagerDuty/Discord/runbook em segundos → pods novos
em ~30–60 s → alerta volta a *Normal* ~2 min depois (a janela de 2 min
precisa esquecer os 500).

Evidências para o relatório: dashboard do Grafana, regra em Firing,
incidente no PagerDuty, mensagens no Discord e o log do runbook:

```bash
kubectl -n observability logs deploy/self-healing
```
