# FCG — Orchestration

Repositório de orquestração da FIAP Cloud Games (FCG) — Fase 2.
Centraliza o `docker-compose.yml` para execução local e os manifestos
Kubernetes para deploy em cluster.

---

## Arquitetura

A aplicação foi decomposta do monolito da Fase 1 em **4 microsserviços
independentes**, comunicando-se de forma assíncrona via **RabbitMQ**.

```
┌─────────────┐        UserCreatedEvent        ┌──────────────────┐
│  UsersAPI   │ ──────────────────────────────▶ │ NotificationsAPI │
└─────────────┘                                 └──────────────────┘
                                                          ▲
┌─────────────┐   OrderPlacedEvent    ┌──────────────┐   │
│ CatalogAPI  │ ─────────────────────▶│ PaymentsAPI  │   │
└─────────────┘                       └──────────────┘   │
      ▲                                      │           │
      │         PaymentProcessedEvent        │           │
      └──────────────────────────────────────┴───────────┘
```

| Serviço | Responsabilidade | Repositório |
|---------|-------------------|-------------|
| UsersAPI | Cadastro, autenticação e autorização | `fcg-users-api` |
| CatalogAPI | CRUD de jogos e fluxo de compra | `fcg-catalog-api` |
| PaymentsAPI | Simulação de pagamento | `fcg-payments-api` |
| NotificationsAPI | Simulação de e-mails | `fcg-notifications-api` |

---

## Fluxos orientados a eventos

### Fluxo de cadastro de usuário

```
1. POST /usuarios no UsersAPI
2. UsersAPI publica UserCreatedEvent
3. NotificationsAPI consome e simula e-mail de boas-vindas
```

### Fluxo de compra de jogo

```
1. POST /jogos/{id}/comprar no CatalogAPI (autenticado)
2. CatalogAPI valida previamente se o jogo já está na biblioteca
   do usuário — se sim, retorna 400 imediatamente sem publicar evento
3. CatalogAPI publica OrderPlacedEvent
4. PaymentsAPI consome, simula o pagamento (~90% de aprovação)
5. PaymentsAPI publica PaymentProcessedEvent
6. CatalogAPI consome:
   → se Approved: adiciona o jogo à biblioteca do usuário
   → se Rejected: apenas loga, nenhuma ação
7. NotificationsAPI consome:
   → se Approved: simula e-mail de confirmação
   → se Rejected: simula e-mail de aviso de recusa
```

> **Nota sobre validação prévia e condição de corrida:** a validação
> do passo 2 reduz drasticamente a chance de compras duplicadas, mas
> não elimina por completo uma condição de corrida em requisições
> simultâneas. A defesa final contra duplicidade real no banco é o
> índice único composto `(UsuarioId, JogoId)` na tabela `Biblioteca`.
> Essa limitação é conhecida e documentada no README do `CatalogAPI`.

---

## Estrutura deste repositório

```
fcg-orchestration/
├── docker-compose.yml
├── postman/
│   └── FCG_Fase2.postman_collection.json
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
    │   ├── secret.yaml
    │   └── deployment.yaml
    └── notifications-api/
        ├── configmap.yaml
        ├── secret.yaml
        └── deployment.yaml
```

---

## Pré-requisitos

- Docker Desktop (com Docker Compose v2)
- .NET 9 SDK (para build local, se necessário)
- kubectl
- Minikube
- Postman (opcional, para testar com a collection incluída)

---

## Como rodar com Docker Compose

**1. Clone os 4 repositórios de microsserviço na mesma pasta pai
deste repositório:**

```
FCG-Fase2/
├── fcg-users-api/
├── fcg-catalog-api/
├── fcg-payments-api/
├── fcg-notifications-api/
└── fcg-orchestration/    ← você está aqui
```

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

## Como fazer o deploy no Kubernetes

**1. Suba um cluster local:**

```bash
minikube start
```

**2. Configure o Docker do Minikube para usar as imagens locais:**

> ⚠️ Esta variável de ambiente vale apenas para o terminal atual.
> Se você abrir um terminal novo, precisa rodar este comando de novo
> antes de qualquer `docker build` — esquecer este passo é a causa
> mais comum de "minha alteração não aparece no pod".

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

# Aguarde o pod do RabbitMQ ficar Running
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
```
NAME                                  READY   STATUS    RESTARTS   AGE
rabbitmq-xxxxxxxxxx-xxxxx             1/1     Running   0          2m
users-api-xxxxxxxxxx-xxxxx            1/1     Running   0          1m
catalog-api-xxxxxxxxxx-xxxxx          1/1     Running   0          1m
payments-api-xxxxxxxxxx-xxxxx         1/1     Running   0          1m
notifications-api-xxxxxxxxxx-xxxxx    1/1     Running   0          1m
```

---

## Acessando os serviços expostos

Os `Service` de cada microsserviço usam **NodePort com portas fixas**,
definidas diretamente nos manifestos — isso evita ter que descobrir
uma porta aleatória a cada deploy:

| Serviço | NodePort |
|---------|----------|
| UsersAPI | `30001` |
| CatalogAPI | `30002` |
| PaymentsAPI | `30003` |
| NotificationsAPI | `30004` |

### Opção A — Acesso direto pelo IP do node (driver VirtualBox/Hyper-V)

```bash
minikube ip
```

```
http://{IP_DO_MINIKUBE}:30001   → UsersAPI
http://{IP_DO_MINIKUBE}:30002   → CatalogAPI
```

### Opção B — `kubectl port-forward` (necessário no driver Docker/Docker Desktop)

> No Windows com Minikube usando o **driver Docker** (padrão do Docker
> Desktop), o IP retornado por `minikube ip` fica dentro da rede virtual
> do Docker Desktop e **não é acessível diretamente do host Windows**.
> Nesse cenário, use `port-forward` — ele funciona independente do driver:

```bash
kubectl port-forward svc/users-api 30001:80
```

Em outro terminal:
```bash
kubectl port-forward svc/catalog-api 30002:80
```

Mantenha os dois terminais abertos enquanto testa. As URLs continuam
as mesmas:
```
http://localhost:30001   → UsersAPI
http://localhost:30002   → CatalogAPI
```

---

## Testando com a Collection do Postman

Este repositório inclui uma collection pronta em
[`postman/FCG_Fase2.postman_collection.json`](./postman/FCG_Fase2.postman_collection.json)
com todo o fluxo de teste organizado em ordem de execução.

### Importando

1. Abra o Postman → **Import** → selecione o arquivo da collection.
2. Clique nos três pontinhos da collection → **Edit** → aba **Variables**.
3. Preencha `users_url` e `catalog_url` com as URLs da sua sessão atual
   (ver seção anterior — normalmente `http://localhost:30001` e
   `http://localhost:30002` se estiver usando `port-forward`).
4. Clique em **Save**.

### Estrutura da collection

```
1 - Fluxo de Cadastro
    → Cadastrar Usuario           (primeiro cadastro vira Admin)
    → Cadastrar Segundo Usuario   (vira User comum)

2 - Autenticacao
    → Login                       (salva o token automaticamente)

3 - Catalogo
    → Cadastrar Jogo               (salva o jogo_id automaticamente)
    → Listar Jogos
    → Criar Promocao

4 - Fluxo de Compra
    → Comprar Jogo                 (aguardar ~5s antes do próximo)
    → Verificar Biblioteca

5 - Testes de Regra de Negocio
    → Comprar Mesmo Jogo Novamente  (deve retornar 400 imediatamente)
    → Cadastrar Jogo Como User Comum (deve retornar 403)
```

Os requests de **Login** e **Cadastrar Jogo** possuem scripts na aba
**Tests** que capturam automaticamente o `token` e o `jogo_id` da
resposta e os salvam nas variáveis da collection — não é necessário
copiar e colar manualmente entre requests.

### Observando o fluxo assíncrono durante o teste

Abra um terceiro terminal e acompanhe os três serviços em paralelo
enquanto testa pelo Postman:

```bash
kubectl logs -f -l app=payments-api
```
```bash
kubectl logs -f -l app=catalog-api
```
```bash
kubectl logs -f -l app=notifications-api
```

Após rodar **Comprar Jogo**, aguarde de 3 a 5 segundos antes de rodar
**Verificar Biblioteca** — o processamento passa por três serviços via
RabbitMQ e não é instantâneo.

---

## ConfigMaps e Secrets

Cada microsserviço tem seu próprio `ConfigMap` (dados não sensíveis)
e `Secret` (dados sensíveis) dentro de `k8s/{servico}/`.

**ConfigMap** — armazena:
- `ASPNETCORE_ENVIRONMENT` (necessário como `Development` para o
  Swagger ficar habilitado — por padrão o ambiente é `Production`)
- Host e usuário do RabbitMQ
- Issuer e Audience do JWT
- Tempo de expiração do token

**Secret** — armazena:
- Chave secreta do JWT (`Jwt__Secret`)
- Senha do RabbitMQ
- Connection string do banco de dados

> ⚠️ O `Jwt__Secret` e `Jwt__Issuer` do `catalog-api` devem ser
> **idênticos** aos do `users-api` — o CatalogAPI só valida tokens,
> quem os emite é o UsersAPI. Um `Issuer` divergente entre os dois
> ConfigMaps causa o erro `"The issuer '...' is invalid"`.

Para inspecionar (sem expor os valores sensíveis):
```bash
kubectl get configmap users-api-config -o yaml
kubectl get secret users-api-secret -o yaml
```

---

## Comunicação entre serviços no cluster

Dentro do Kubernetes, os serviços se comunicam pelo nome do `Service`,
nunca por IP ou `localhost`:

```
http://users-api:80
http://catalog-api:80
http://rabbitmq:5672
```

Isso é resolvido automaticamente pelo DNS interno do cluster.

---

## Solução de problemas

### Pods em `CrashLoopBackOff`

```bash
kubectl logs {nome-do-pod}
kubectl describe pod {nome-do-pod}
```

Causa comum: connection string do SQLite apontando para um path que
não existe no container (ex: `/data`). Use `/app` ou outro diretório
que já existe por padrão na imagem, ou monte um volume explícito.

### Mensagens não roteadas no RabbitMQ ("unroutable")

Verifique se todos os serviços usam o **mesmo namespace** nos
contratos de eventos (`FCG.Contratos`). O MassTransit deriva o nome
do exchange a partir do namespace completo — precisa ser idêntico
em todos os microsserviços que publicam/consomem o mesmo evento.

### Duas classes de consumer com o mesmo nome consomem da mesma fila

Se dois microsserviços diferentes têm uma classe chamada, por
exemplo, `PaymentProcessedConsumer`, e ambos usam
`cfg.ConfigureEndpoints(context)` sem nomear o endpoint, o
MassTransit cria **a mesma fila para os dois** — cada mensagem é
entregue a apenas um dos serviços (round-robin), nunca aos dois.
Isso causa comportamento intermitente e difícil de depurar (às
vezes o e-mail é enviado, às vezes o jogo é adicionado à biblioteca,
nunca os dois juntos para o mesmo pedido).

**Solução:** nomeie explicitamente o endpoint de cada consumer:

```csharp
cfg.ReceiveEndpoint("catalog-payment-processed", e =>
{
    e.ConfigureConsumer<PaymentProcessedConsumer>(context);
});
```

Use nomes diferentes por serviço mesmo que a classe do consumer
tenha o mesmo nome em ambos.

### Alterações no código não aparecem no pod após rebuild

Sintoma: você corrige um bug, faz `docker build`, reinicia o pod, mas
o comportamento antigo persiste.

Checklist de diagnóstico:

```bash
# 1. Confirme que o build foi feito DENTRO do contexto do Minikube
#    (precisa rodar em TODO terminal novo antes de buildar)
eval $(minikube docker-env)   # ou o equivalente PowerShell

# 2. Confirme que a imagem local mudou
docker inspect {nome-da-imagem}:latest --format "{{.Id}}"

# 3. Confirme que a imagem chegou dentro do Minikube
minikube ssh -- docker images | grep {nome-da-imagem}

# 4. Force a recriação do pod (delete, não rollout restart)
kubectl delete pod -l app={nome-do-servico}

# 5. Confirme que o pod novo pegou a imagem nova
kubectl get pod -l app={nome-do-servico} \
  -o jsonpath="{.items[0].status.containerStatuses[0].imageID}"
```

Compare o hash do passo 5 com o do passo 2 — precisam ser idênticos.

### Swagger retorna 404 no cluster

O Swagger só é habilitado quando `ASPNETCORE_ENVIRONMENT=Development`.
Confirme que essa variável está no `ConfigMap` do serviço e que o pod
foi reiniciado após adicioná-la (ConfigMaps alterados não reiniciam
pods automaticamente):

```bash
kubectl rollout restart deployment/{nome-do-servico}
```

### `curl`/Postman não conecta ao IP do Minikube (timeout)

Se você estiver no Windows com Minikube usando o **driver Docker**
(via Docker Desktop), o IP de `minikube ip` pode não ser acessível
diretamente do host. Use `kubectl port-forward` como alternativa
(ver seção "Acessando os serviços expostos" acima).

### Reset completo do ambiente local

```bash
docker compose down -v
docker compose up --build
```

---

*FIAP Cloud Games · Tech Challenge Fase 2 · PosTech FIAP*
