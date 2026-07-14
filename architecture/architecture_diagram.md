# Diagrama de Arquitetura — ToggleMaster

Este diagrama ilustra a topologia do **ToggleMaster**, detalhando o fluxo de tráfego dos clientes, o roteamento feito pelo Nginx Ingress Controller, as interações entre os microsserviços, suas respectivas camadas de dados (RDS, Redis, DynamoDB), a mensageria assíncrona (SQS) e os mecanismos específicos de escalabilidade (**HPA** e **KEDA**).

```mermaid
graph TD
    classDef client fill:#f9f,stroke:#333,stroke-width:2px;
    classDef ingress fill:#bbf,stroke:#333,stroke-width:2px;
    classDef app fill:#dfd,stroke:#333,stroke-width:2px;
    classDef db fill:#ffd,stroke:#333,stroke-width:2px;
    classDef cache fill:#fdd,stroke:#333,stroke-width:2px;
    classDef scaler fill:#dff,stroke:#333,stroke-dasharray: 5 5,stroke-width:2px;
    subgraph Clients["Tráfego Externo"]
        User["Clientes / Sistemas Parceiros"]:::client
    end
    subgraph IngressLayer["Camada de Entrada (Ingress)"]
        Ingress["Nginx Ingress Controller"]:::ingress
    end
    subgraph Microservices["Microsserviços (Kubernetes Pods)"]
        AuthService["auth-service (Go)"]:::app
        FlagService["flag-service (Python)"]:::app
        TargetingService["targeting-service (Python)"]:::app
        EvalService["evaluation-service (Go)"]:::app
        AnalyticsService["analytics-service (Python)"]:::app
    end
    subgraph CacheAndQueue["Mensageria e Cache"]
        Redis["ElastiCache Redis"]:::cache
        SQS["AWS SQS (evaluation-analytics)"]:::cache
    end
    subgraph Databases["Persistência de Dados"]
        PostgresAuth[("RDS PostgreSQL - auth_db")]:::db
        PostgresFlags[("RDS PostgreSQL - flags_db")]:::db
        PostgresTargeting[("RDS PostgreSQL - targeting_db")]:::db
        DynamoDB[("AWS DynamoDB - analytics-service-dynamo")]:::db
    end
    subgraph AutoScaling["Mecanismos de Escalabilidade"]
        HPA["HPA (CPU > 70%)"]:::scaler
        KEDA["KEDA (SQS Queue Length > 5)"]:::scaler
    end
    User -->|Requisições HTTP| Ingress
    Ingress -->|/auth| AuthService
    Ingress -->|/flags| FlagService
    Ingress -->|/targeting| TargetingService
    Ingress -->|/evaluation| EvalService
    Ingress -->|/analytics| AnalyticsService
    AuthService -->|Persistência ACID| PostgresAuth
    FlagService -->|Persistência ACID| PostgresFlags
    TargetingService -->|Persistência ACID| PostgresTargeting
    EvalService -.->|Consome API| FlagService
    EvalService -.->|Consome API| TargetingService
    EvalService -->|Leitura/Escrita de Cache| Redis
    EvalService -->|Envia métricas assíncronas| SQS
    AnalyticsService -->|Consome fila em Lote| SQS
    AnalyticsService -->|Gravação massiva NoSQL| DynamoDB
    HPA ==>|Monitora CPU & Escala Réplicas| EvalService
    KEDA ==>|Monitora Fila & Escala Réplicas - 0 a 10| AnalyticsService
    SQS -.->|Métrica de Volume| KEDA
```

### Explicação do Fluxo:
1. **Roteamento de Borda**: O cliente faz requisições que chegam ao **Nginx Ingress Controller**. Com base no path (/auth, /flags, /evaluation, etc.), o tráfego é encaminhado ao microsserviço correspondente.
2. **Camada de Administração**:
   * O `auth-service` gerencia chaves de API salvando-as no PostgreSQL (`auth_db`).
   * O `flag-service` e o `targeting-service` controlam o CRUD de feature flags e regras de distribuição no PostgreSQL (`flags_db` e `targeting_db`).
3. **Fluxo de Avaliação Crítica**:
   * O `evaluation-service` realiza a validação das flags. Ele consulta e cacheia as configurações de avaliação no **Redis** (ElastiCache) para garantir tempos de resposta de sub-milissegundos.
   * Para não onerar a requisição do usuário final, a telemetria do evento avaliado é enviada de forma assíncrona ao **AWS SQS**.
4. **Camada de Auditoria e Escrita Massiva**:
   * O `analytics-service` atua como um worker assíncrono. Ele consome as mensagens em lote do SQS e as armazena no **Amazon DynamoDB** (banco NoSQL altamente escalável).
5. **Autoscaling**:
   * O **HPA** do Kubernetes monitora o uso de CPU do `evaluation-service` e escala o número de réplicas quando a média ultrapassa **70%**.
   * O **KEDA** monitora a profundidade de mensagens da fila do SQS e escala o `analytics-service` de **0 a 10 réplicas** dinamicamente. Se não houver mensagens acumuladas, ele reduz a quantidade de pods a zero.
