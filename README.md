
# FIAP Cloud Gaming - Fase 02

Tech Challenge Pos-graduacao FIAP.

# FCG — Orchestration

Repositório de orquestração da FIAP Cloud Games (FCG) — Fase 2.
Centraliza o `docker-compose.yml` para execução local e os manifestos
Kubernetes para deploy em cluster.

---

## Arquitetura

A aplicação foi decomposta do monolito da Fase 1 em **4 microsserviços
independentes**, comunicando-se de forma assíncrona via **RabbitMQ**.

    ┌─────────────┐        UserCreatedEvent         ┌──────────────────┐
    │  UsersAPI   │ ──────────────────────────────▶ │ NotificationsAPI │
    └─────────────┘                                 └──────────────────┘
    ▲
    ┌─────────────┐   OrderPlacedEvent    ┌──────────────┐   │
    │ CatalogAPI  │ ─────────────────────▶│ PaymentsAPI  │   │
    └─────────────┘                        └──────────────┘   │
    ▲                                      │           │
    │         PaymentProcessedEvent        │           │
    └──────────────────────────────────────┴───────────┘

| Serviço | Responsabilidade | Repositório |
|---------|-------------------|-------------|
| UsersAPI | Cadastro, autenticação e autorização | `fcg-users-api` |
| CatalogAPI | CRUD de jogos e fluxo de compra | `fcg-catalog-api` |
| PaymentsAPI | Simulação de pagamento | `fcg-payments-api` |
| NotificationsAPI | Simulação de e-mails | `fcg-notifications-api` |

---

## Fluxos orientados a eventos

### Fluxo de cadastro de usuário

    1. POST /usuarios no UsersAPI
    2. UsersAPI publica UserCreatedEvent
    3. NotificationsAPI consome e simula e-mail de boas-vindas

### Fluxo de compra de jogo

    1. POST /jogos/{id}/comprar no CatalogAPI (autenticado)
    2. CatalogAPI publica OrderPlacedEvent
    3. PaymentsAPI consome, simula o pagamento (90% aprovação)
    4. PaymentsAPI publica PaymentProcessedEvent
    5. CatalogAPI consome:
    → se Approved: adiciona o jogo à biblioteca do usuário
    6. NotificationsAPI consome:
    → se Approved: simula e-mail de confirmação
    → se Rejected: simula e-mail de aviso de recusa

---

## Estrutura deste repositório
    fcg-orchestration/
    ├── docker-compose.yml
    └── k8s/
    ├── rabbitmq/
    │   └── deployment.yaml
    ├── users-api/
    │   ├── configmap.yaml
    │   ├── secret.yaml
    │   └── deployment.yaml
    ├── catalog-api/
    │   ├── configmap.yaml
    │   ├── secret.yaml
    │   └── deployment.yaml
    ├── payments-api/
    │   ├── configmap.yaml
    │   └── deployment.yaml
    └── notifications-api/
    ├── configmap.yaml
    └── deployment.yaml

---

## Pré-requisitos

- Docker Desktop (com Docker Compose v2)
- .NET 9 SDK (para build local, se necessário)
- kubectl
- Minikube, Kind ou Docker Desktop Kubernetes

---

## Como rodar com Docker Compose

**1. Clone os 4 repositórios de microsserviço na mesma pasta pai
deste repositório:**
    
    FCG-Fase2/
    ├── fcg-users-api/
    ├── fcg-catalog-api/
    ├── fcg-payments-api/
    ├── fcg-notifications-api/
    └── fcg-orchestration/    ← você está aqui

**2. Suba tudo com um único comando:**

```bash
cd fcg-orchestration
docker compose up --build
```

**3. Aguarde os serviços subirem e acesse:**

| Serviço | URL |
|---------|-----|
| UsersAPI Swagger | http://localhost:5001/swagger |
| CatalogAPI Swagger | http://localhost:5002/swagger |
| PaymentsAPI Health | http://localhost:5003/health |
| NotificationsAPI Health | http://localhost:5004/health |
| RabbitMQ Management | http://localhost:15672 (guest/guest) |

**4. Para derrubar os serviços mantendo os dados:**

```bash
docker compose down
```

**5. Para derrubar e apagar todos os dados (reset completo):**

```bash
docker compose down -v
```

---

## Testando o fluxo completo via Docker Compose

**Fluxo de cadastro:**
```bash
curl -X POST http://localhost:5001/usuarios \
  -H "Content-Type: application/json" \
  -d '{"nome":"Lucas Silva","email":"lucas@fiap.com.br","senha":"Senha@123"}'
```
Verifique o e-mail simulado:
```bash
docker logs fcg-notifications-api | grep "BOAS-VINDAS"
```

**Fluxo de compra:**
```bash
# 1. Login
curl -X POST http://localhost:5001/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"lucas@fiap.com.br","senha":"Senha@123"}'

# 2. Cadastrar jogo (usando o token retornado)
curl -X POST http://localhost:5002/jogos \
  -H "Authorization: Bearer {token}" \
  -H "Content-Type: application/json" \
  -d '{"titulo":"Minecraft","descricao":"Jogo de blocos","preco":99.90}'

# 3. Comprar o jogo
curl -X POST http://localhost:5002/jogos/{jogoId}/comprar \
  -H "Authorization: Bearer {token}"

# 4. Verificar biblioteca (aguardar alguns segundos para o
#    processamento assíncrono do pagamento)
curl http://localhost:5002/biblioteca \
  -H "Authorization: Bearer {token}"
```

Verifique os logs do fluxo completo:
```bash
docker compose logs -f
```

---

## Como fazer o deploy no Kubernetes

**1. Suba um cluster local:**

```bash
minikube start
```

**2. Configure o Docker do Minikube para usar as imagens locais:**

```bash
# Windows PowerShell
& minikube -p minikube docker-env | Invoke-Expression

# Linux/Mac
eval $(minikube docker-env)
```

**3. Faça o build das imagens dentro do contexto do Minikube:**

```bash
docker build -t fcg-users-api:latest ../fcg-users-api
docker build -t fcg-catalog-api:latest ../fcg-catalog-api
docker build -t fcg-payments-api:latest ../fcg-payments-api
docker build -t fcg-notifications-api:latest ../fcg-notifications-api
```

**4. Aplique os manifestos na ordem correta:**

```bash
# RabbitMQ primeiro — os demais dependem dele
kubectl apply -f k8s/rabbitmq/

# Aguarde o RabbitMQ subir completamente
kubectl get pods -w
# (Ctrl+C quando o pod rabbitmq estiver Running)

# Demais serviços
kubectl apply -f k8s/users-api/
kubectl apply -f k8s/catalog-api/
kubectl apply -f k8s/payments-api/
kubectl apply -f k8s/notifications-api/
```

**5. Verifique se todos os Pods estão rodando:**

```bash
kubectl get pods
```

Saída esperada:

    NAME                                  READY   STATUS    RESTARTS   AGE
    rabbitmq-xxxxxxxxxx-xxxxx             1/1     Running   0          2m
    users-api-xxxxxxxxxx-xxxxx            1/1     Running   0          1m
    catalog-api-xxxxxxxxxx-xxxxx          1/1     Running   0          1m
    payments-api-xxxxxxxxxx-xxxxx         1/1     Running   0          1m
    notifications-api-xxxxxxxxxx-xxxxx    1/1     Running   0          1m

**6. Acesse os serviços expostos via NodePort:**

```bash
minikube service users-api --url
minikube service catalog-api --url
```

---

## ConfigMaps e Secrets

Cada microsserviço tem seu próprio `ConfigMap` (dados não sensíveis)
e `Secret` (dados sensíveis) dentro de `k8s/{servico}/`.

**ConfigMap** — armazena:
- Host e usuário do RabbitMQ
- Issuer e Audience do JWT
- Tempo de expiração do token

**Secret** — armazena:
- Chave secreta do JWT (`Jwt__Secret`)
- Senha do RabbitMQ
- Connection string do banco de dados

Para inspecionar (sem expor os valores sensíveis):
```bash
kubectl get configmap users-api-config -o yaml
kubectl get secret users-api-secret -o yaml
```

---

## Comunicação entre serviços no cluster

Dentro do Kubernetes, os serviços se comunicam pelo nome do `Service`,
nunca por IP ou `localhost`:

    http://users-api:80
    http://catalog-api:80
    http://rabbitmq:5672

Isso é resolvido automaticamente pelo DNS interno do cluster.

---

## Solução de problemas

**Pods em `CrashLoopBackOff`:**
```bash
kubectl logs {nome-do-pod}
kubectl describe pod {nome-do-pod}
```

**Mensagens não roteadas no RabbitMQ ("unroutable"):**
Verifique se todos os serviços usam o **mesmo namespace** nos
contratos de eventos (`FCG.Contratos`). O MassTransit deriva o nome
do exchange a partir do namespace completo — precisa ser idêntico
em todos os microsserviços que publicam/consomem o mesmo evento.

**Reset completo do ambiente local:**
```bash
docker compose down -v
docker compose up --build
```



*FIAP Cloud Games · Tech Challenge Fase 2 · PosTech FIAP*
