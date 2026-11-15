# FIAP Cloud Games (FCG) — Fase 4

Plataforma de jogos em microsserviços, executando em **Kubernetes gerenciado na Azure (AKS)**, com **CI/CD no GitHub Actions**, **NoSQL (MongoDB)**, **cache distribuído (Redis)** e **busca avançada com Elasticsearch** (fuzzy + relevância).

Este repositório (`fcg-orchestration`) concentra os manifests Kubernetes, os scripts de infraestrutura e este guia. O código de cada serviço fica em seu próprio repositório.

## Sumário

1. [Arquitetura](#arquitetura)
2. [Repositórios](#repositórios)
3. [Infraestrutura na Azure](#infraestrutura-na-azure)
4. [Como subir tudo do zero](#como-subir-tudo-do-zero)
5. [Segredos](#segredos-zero-hardcoded-credentials)
6. [CI/CD](#cicd)
7. [Busca avançada (Elasticsearch)](#busca-avançada-elasticsearch)
8. [NoSQL e Cache](#nosql-e-cache)
9. [Testando a aplicação](#testando-a-aplicação)
10. [Custos e rotina de uso](#custos-e-rotina-de-uso)
11. [Limitações conhecidas](#limitações-conhecidas)

## Arquitetura

```
                          Internet
                             │
                  ┌──────────▼───────────┐
                  │  Kong (LoadBalancer) │  IP público · roteamento · JWT
                  └───┬──────────────┬───┘
        /auth /usuarios              /jogos /search
                  │                  │
          ┌───────▼──────┐   ┌───────▼───────┐        ┌────────────────────┐
          │  UsersAPI    │   │  CatalogAPI   │───────▶│ Elasticsearch      │
          │  (SQLite+PVC)│   │  (SQLite+PVC) │ índice │ (Elastic Cloud)    │
          └───────┬──────┘   └──┬─────┬───┬──┘        └────────────────────┘
                  │             │     │   │
                  │             │     │   └──────▶ Redis (cache-aside, TTL 30s)
                  │             │     └──────────▶ MongoDB (avaliações)
                  │             │
                  └──────┐      │ OrderPlacedEvent
                         ▼      ▼
                       ┌──────────────┐        ┌──────────────┐
                       │  RabbitMQ    │◀──────▶│ PaymentsAPI  │
                       └──────────────┘        └──────────────┘
                       (UserCreatedEvent, OrderPlacedEvent, PaymentProcessedEvent)
```

**Fluxo de compra:** `POST /jogos/{id}/comprar` → CatalogAPI publica `OrderPlacedEvent` → PaymentsAPI processa e publica `PaymentProcessedEvent` → CatalogAPI adiciona o jogo à biblioteca.

## Repositórios

| Repositório | Conteúdo |
|---|---|
| `fcg-orchestration` (este) | Manifests K8s, scripts, documentação |
| `fcg-users-api` | UsersAPI + testes + workflow CI/CD |
| `fcg-catalog-api` | CatalogAPI + testes + workflow CI/CD |
| `fcg-payments-api` | PaymentsAPI |
| `fcg-notifications-api` / `fcg-notifications-function` | Notificações via Azure Function (Fase 3, não implantado no AKS nesta fase) |

## Infraestrutura na Azure

| Recurso | Nome | Observação |
|---|---|---|
| Resource Group | `rg-fcg` | região `eastus` |
| Container Registry (ACR) | `fcgacr203f9c81` | SKU Basic, registry privado |
| AKS | `aks-fcg` | tier Free, 1 nó `Standard_D2s_v4`, ACR anexado |
| Elasticsearch | Elastic Cloud (Serverless) | índice `jogos` |
| Exposição | Kong com `Service LoadBalancer` | IP público |

Provisionamento (idempotente): `scripts/provision-azure.sh`.

## Como subir tudo do zero

**Pré-requisitos:** Azure CLI, `kubectl`, `helm`, Docker, Git Bash (ou Linux/macOS), conta Azure e um deployment do Elastic Cloud.

**1. Provisionar o cluster**

```bash
az login --tenant <TENANT_ID>
export MSYS_NO_PATHCONV=1                 # somente no Git Bash
NODE_SIZE=Standard_D2s_v4 bash scripts/provision-azure.sh
```

**2. Criar o `.env.local`** (arquivo ignorado pelo Git — modelo em `secrets.example.env`)

```bash
cp secrets.example.env .env.local
# preencha: JWT_SECRET, RABBITMQ_PASSWORD, ELASTIC_ENDPOINT, ELASTIC_API_KEY
# gerar valores:  openssl rand -base64 48   |   openssl rand -base64 24
```

**3. Publicar as imagens no ACR** (o pipeline faz isso automaticamente para Users e Catalog; o primeiro envio é manual)

```bash
ACR=fcgacr203f9c81
az acr login --name $ACR
for svc in fcg-users-api fcg-catalog-api fcg-payments-api; do
  docker build -t $ACR.azurecr.io/$svc:v1 ../$svc && docker push $ACR.azurecr.io/$svc:v1
done
```

**4. Instalar o Kong (IP público)**

```bash
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace
kubectl get svc -n kong kong-gateway-proxy -w     # aguarde o EXTERNAL-IP
```

**5. Criar os Secrets e aplicar os manifests** (os Secrets precisam existir antes dos Deployments)

```bash
bash scripts/create-secrets.sh

kubectl apply -f k8s/rabbitmq/ -f k8s/mongodb/ -f k8s/redis/
kubectl apply -f k8s/users-api/ -f k8s/catalog-api/ -f k8s/payments-api/
kubectl apply -f k8s/gateway/
kubectl get pods
```

**6. Popular o índice de busca** (autenticado como Admin)

```bash
curl -X POST http://<IP-DO-KONG>/search/reindexar -H "Authorization: Bearer <TOKEN>"
```

**Atalho para o dia a dia:** `source scripts/up.sh` liga o AKS, carrega o `.env.local`, descobre o IP do Kong e gera um token do Admin de teste. Use `login` para renovar o token e `down` para parar o cluster.

## Segredos (Zero Hardcoded Credentials)

Nenhuma credencial está no código ou nos YAMLs.

| Segredo | Onde vive | Como chega ao pod |
|---|---|---|
| `Jwt__Secret` | Secret K8s `users-api-secret`, `catalog-api-secret` e credencial do Kong (`fcg-jwt-credential`) | `envFrom` / `secretRef` |
| `RabbitMQ__Senha` | Secrets `*-api-secret` e `rabbitmq-secret` | `envFrom` / `secretKeyRef` |
| `Elastic__Endpoint`, `Elastic__ApiKey` | Secret `elastic-secret` | `envFrom` / `secretRef` |
| Credenciais do pipeline | **GitHub Secrets** de cada repositório | variáveis do workflow |

- Os Secrets do cluster são criados por `scripts/create-secrets.sh` a partir do `.env.local` (fora do Git) ou de variáveis de ambiente.
- Os `appsettings.json` das APIs contêm apenas o placeholder `CONFIGURE_VIA_ENV`; as variáveis do Secret sobrescrevem o valor em tempo de execução.

## CI/CD

Workflow `.github/workflows/ci.yml` em `fcg-users-api` e `fcg-catalog-api`:

| Job | Quando | O que faz |
|---|---|---|
| **Build & Test** | todo push e pull request em `main` | `dotnet restore`, `build` e testes unitários (xUnit) |
| **Imagem + Push (ACR)** | push em `main` | build da imagem Docker com tag = **SHA do commit** e push no ACR |
| **Deploy no AKS** | após o push | `kubectl set image` + `kubectl rollout status` (**Rolling Update**, sem downtime) |

**Credenciais do pipeline:** um Service Principal (`fcg-github-actions`) com `AcrPush` no ACR e `Azure Kubernetes Service Cluster Admin Role` no AKS, ambos limitados a esses dois recursos. Os valores ficam nos GitHub Secrets `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` e `AZURE_SUBSCRIPTION_ID`.

```bash
az ad sp create-for-rbac --name fcg-github-actions --role AcrPush --scopes <ID-DO-ACR>
az role assignment create --assignee <APP_ID> \
  --role "Azure Kubernetes Service Cluster Admin Role" --scope <ID-DO-AKS>
```

**Rolling Update:** os Deployments têm `readinessProbe` (TCP 8080), então o Kubernetes só remove o pod antigo depois que o novo está pronto.

## Busca avançada (Elasticsearch)

- **Serviço:** Elastic Cloud (Serverless), independente do banco relacional.
- **Índice `jogos`:** `titulo` e `descricao` como `text` (analyzer `folding`: minúsculas e sem acento), `titulo.raw` como `keyword`, mais `preco`, `precoAtual`, `temPromocaoAtiva` e `criadoEm`.
- **Sincronização (CatalogAPI):** o jogo é indexado ao ser **cadastrado**, ao ter o **preço atualizado**, ao receber uma **promoção** e removido do índice ao ser **excluído**. Falhas do Elasticsearch são registradas em log e **não derrubam** a operação principal.
- **`GET /search?q=termo`:** `multi_match` em `titulo^3` e `descricao` com `fuzziness: AUTO` (tolerância a erros de digitação), ordenado por relevância (`_score`).
- **`POST /search/reindexar`** (Admin): recria o índice, se necessário, e envia todos os jogos em lote (bulk).

```bash
curl "http://<IP>/search?q=zeldaa"      # encontra "Zelda" mesmo com erro de digitação
```

## NoSQL e Cache

| Recurso | Uso |
|---|---|
| **MongoDB** (`MongoDB.Driver`) | Avaliações de jogos (`POST` e `GET /jogos/{id}/avaliacoes`) — dados flexíveis e de alto volume |
| **Redis** (`IDistributedCache`) | Cache-aside de `GET /jogos`, TTL de 30s. O header `X-Cache` mostra `MISS` ou `HIT` |

## Testando a aplicação

```bash
IP=<EXTERNAL-IP do Kong>

# cadastro e login
curl -X POST http://$IP/usuarios -H "Content-Type: application/json" \
  -d '{"nome":"Admin","email":"admin@fcg.com","senha":"<SENHA-FORTE>"}'
curl -X POST http://$IP/auth/login -H "Content-Type: application/json" \
  -d '{"email":"admin@fcg.com","senha":"<SENHA-FORTE>"}'

# JWT validado no Gateway: 401 sem token, 200 com token
curl -i http://$IP/usuarios
curl -i http://$IP/usuarios -H "Authorization: Bearer <TOKEN>"

# cache: compare X-Cache e a latência
curl -s -o /dev/null -D - http://$IP/jogos | grep -i -E "x-cache|x-kong-upstream-latency"
```

A coleção Postman está em `postman/`.

## Custos e rotina de uso

O plano de controle do AKS (tier Free) não tem custo. O que cobra é a VM do nó por hora ligada, o IP público e os discos. Por isso:

```bash
az aks stop  --resource-group rg-fcg --name aks-fcg    # ao encerrar a sessão
az aks start --resource-group rg-fcg --name aks-fcg    # ao voltar
```

Para remover tudo: `az group delete --name rg-fcg`.

## Limitações conhecidas

- **SQLite em disco persistente (PVC `ReadWriteOnce`):** Users e Catalog usam SQLite. O Rolling Update funciona porque o cluster tem **um único nó**, e o pod novo monta o mesmo disco. Em produção, o correto seria um banco gerenciado (Azure SQL/PostgreSQL) e várias réplicas.
- **Autorização no Gateway:** o plugin JWT do Kong está aplicado em rotas inteiramente protegidas (ex.: `GET /usuarios`). A autorização fina por endpoint e por perfil (`[Authorize(Roles = "Admin")]`) continua nos serviços, porque o `Ingress` padrão roteia por caminho, não por método HTTP.
- **`precoAtual` no índice** é uma fotografia do momento da indexação: se uma promoção expirar por tempo, só será atualizado na próxima gravação ou reindexação.
- **Credencial do pipeline:** usa Service Principal com senha em GitHub Secrets. A evolução natural é OIDC (federação de identidade), sem senha armazenada.
- **Papel do pipeline no AKS:** `Cluster Admin Role` por simplicidade; em produção, um papel mais restrito (RBAC por namespace).
- **Notificações (Fase 3):** a Azure Function e o adaptador RabbitMQ → HTTP não foram implantados no AKS nesta fase.
