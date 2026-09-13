# FCG — FIAP Cloud Games (Fase 3)

Repositório de orquestração da plataforma FCG. Contém os manifests Kubernetes, scripts de ambiente e a documentação central de todos os microsserviços.

Na Fase 2, o monólito foi dividido em quatro microsserviços independentes, o que resolveu o acoplamento mas abriu quatro problemas novos. A Fase 3 é a resposta a cada um deles.

| Problema | Solução | Pilar |
|---|---|---|
| Cliente precisava conhecer o endereço de cada serviço; nada impedia acesso direto pulando autenticação | Kong como ponto único de entrada, validando JWT na borda | API Gateway |
| Falha em produção só era descoberta por reclamação — sem visibilidade de latência ou taxa de erro | OpenTelemetry + Prometheus + Grafana | Observabilidade |
| NotificationsAPI consumia recursos 24/7 para ficar ocioso a maior parte do tempo | Azure Function acionada por evento | Serverless |
| Banco relacional único atendendo dados flexíveis e leituras repetitivas | MongoDB para avaliações + Redis como cache | Persistência poliglota |

---

## Arquitetura

```
                          ┌─────────────┐
   cliente ──────────────▶│    Kong     │  (roteamento + validação JWT)
                          └──────┬──────┘
                    ┌────────────┴────────────┐
                    ▼                         ▼
            ┌───────────────┐        ┌────────────────┐
            │   UsersAPI    │        │   CatalogAPI   │
            │   (SQLite)    │        │ SQLite + Mongo │
            └───────┬───────┘        │    + Redis     │
                    │                └───────┬────────┘
                    │      ┌─────────────────┘
                    ▼      ▼
                ┌─────────────┐
                │  RabbitMQ   │
                └──────┬──────┘
                   ┌───┴────┐
                   ▼        ▼
         ┌──────────────┐  ┌──────────────────┐
         │ PaymentsAPI  │  │ NotificationsAPI │
         └──────────────┘  │   (adaptador)    │
                           └────────┬─────────┘
                                    │ HTTP
                                    ▼
                        ┌────────────────────────┐
                        │  Azure Function        │
                        │  (plano Consumption)   │
                        └────────────────────────┘

   UsersAPI e CatalogAPI expõem /metrics ──▶ Prometheus ──▶ Grafana
```

---

## Stack escolhida

| Pilar | Escolha | Justificativa resumida |
|---|---|---|
| API Gateway | Kong Ingress Controller | Open-source, roda no cluster Kubernetes já existente, suporta plugins (JWT, rate limit) além de roteamento |
| Serverless | Azure Functions, plano Consumption | Único provedor com trigger nativo de RabbitMQ; ver decisão detalhada abaixo |
| Observabilidade | **Opção A** — Prometheus + Grafana | Custo zero, roda local, controle total sobre a instrumentação |
| NoSQL | MongoDB | Modelo de documento se encaixa na estrutura flexível das avaliações |
| Cache | Redis via `IDistributedCache` | Compartilhado entre réplicas, ao contrário de cache em memória de processo |

---

## Como subir o ambiente do zero

**Pré-requisitos:** Docker Desktop com Kubernetes habilitado, Helm, kubectl, .NET 9 SDK, Azure Functions Core Tools (apenas para desenvolvimento da Function).

```bash
# 1. Habilitar Kubernetes no Docker Desktop e aguardar o cluster subir

# 2. Subir toda a infraestrutura
bash scripts/bootstrap-dev.sh
```

O script cuida de tudo: instala Kong e a stack de observabilidade via Helm, carrega as imagens locais nos nós do cluster, aplica RabbitMQ/MongoDB/Redis, sobe os três microsserviços, configura as rotas do Gateway e abre os port-forwards.

Ao final, os seguintes endereços ficam disponíveis:

| Serviço | Endereço |
|---|---|
| Kong (Gateway) | http://localhost:8000 |
| UsersAPI (acesso direto, para debug) | http://localhost:8081 |
| CatalogAPI (acesso direto, para debug) | http://localhost:8082 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (usuário `admin`) |
| RabbitMQ / MongoDB / Redis | localhost:5672 / 27017 / 6379 |

Senha do Grafana:
```bash
kubectl get secret -n monitoring monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

**Para o fluxo serverless**, o adaptador roda localmente:
```bash
cd ../fcg-notifications-api/FCG.NotificationsAPI
dotnet run
```

---

## Decisões de arquitetura

### 1. JWT validado no Gateway

O plugin `jwt` do Kong valida o token antes que a requisição alcance qualquer microsserviço. Isso concentra a política de autenticação em um único lugar (em vez de replicá-la nos quatro serviços) e reduz a superfície de ataque: uma requisição sem token válido nunca consome CPU da aplicação nem aparece nos seus logs.

**A limitação que encontramos:** o recurso `Ingress` do Kubernetes roteia por path, não por método HTTP. Isso é um problema porque `POST /usuarios` (cadastro, público) e `GET /usuarios` (listagem, restrita a Admin) compartilham exatamente o mesmo path — aplicar o plugin ao path inteiro bloquearia o cadastro de novos usuários.

A solução foi usar a anotação `konghq.com/methods: "GET"` combinada com `pathType: Exact` em um `Ingress` dedicado, de modo que o plugin se aplique apenas ao verbo protegido. O Ingress geral de roteamento permanece sem o plugin, atendendo os endpoints públicos.

**Escopo consciente:** o Gateway valida a *autenticidade* do token; a *autorização* fina por role (`[Authorize(Roles = "Admin")]`) continua sendo responsabilidade de cada serviço. O Gateway é uma camada adicional de defesa, não um substituto da validação interna.

Um detalhe de integração que vale registrar: o plugin `jwt` do Kong identifica a credencial pelo claim `iss` do token. O valor real emitido pelo UsersAPI é `FCG.UsersAPI` (definido em `Jwt__Issuer`), e é esse valor que precisa constar no campo `key` do Secret da credencial.

### 2. Serverless com adaptador HTTP

O requisito era mover a lógica de notificações para uma função serverless acionada por evento. A pesquisa da documentação atual dos dois principais provedores revelou um impasse com RabbitMQ:

- **AWS Lambda** não aceita RabbitMQ self-hosted como gatilho nativo — exige Amazon MQ, o serviço gerenciado, com custo associado.
- **Azure Functions** possui trigger nativo de RabbitMQ, mas ele é suportado apenas nos planos Premium e Dedicated. O plano Consumption (o gratuito, que cobra apenas pela execução) não o suporta.

Ou seja: nenhum caminho oferecia trigger nativo de RabbitMQ sem custo recorrente.

**A decisão foi usar trigger HTTP no plano Consumption**, mantendo o NotificationsAPI como um adaptador leve: ele continua consumindo os eventos da fila via MassTransit, mas em vez de processar a notificação, serializa o evento e invoca a Function por HTTP.

Isso é um meio-termo consciente. A parte "sempre ligada" não desaparece por completo, mas fica reduzida a um encaminhador simples, e o processamento de fato ocorre em ambiente serverless com custo zero. O trade-off foi escolhido priorizando ausência de custo recorrente em um projeto acadêmico.

Uma consequência favorável do desenho: como é o adaptador (local) que faz a chamada de saída para a nuvem, não é necessário expor o RabbitMQ publicamente nem contratar um broker hospedado.

O ack da mensagem só ocorre após a resposta HTTP bem-sucedida (`EnsureSuccessStatusCode`), de modo que uma falha na Function devolve a mensagem à fila em vez de descartá-la silenciosamente.

**Repositório da Function:** https://github.com/Ellenith/fcg-notifications-function

### 3. Observabilidade com OpenTelemetry (Opção A)

A instrumentação usa **OpenTelemetry**, o padrão aberto da indústria, em vez de um SDK proprietário. A vantagem prática é o desacoplamento: o código instrumentado não conhece o Prometheus. Trocar o destino das métricas por Datadog, New Relic ou qualquer backend compatível com OTLP exigiria mudar o exportador, não a instrumentação.

Para ASP.NET Core a instrumentação é automática — `AddAspNetCoreInstrumentation()` se pluga no pipeline e captura duração, status code e rota de todas as requisições sem código manual por endpoint.

O Prometheus opera por **pull**: as aplicações apenas expõem `/metrics` e ele as consulta a cada 15 segundos. A aplicação não precisa saber que o Prometheus existe nem falhar se ele estiver indisponível. Dentro do Kubernetes, a descoberta dos alvos é automática via `ServiceMonitor`, então novos pods passam a ser monitorados sem configuração manual.

O dashboard cobre as três métricas exigidas:

| Painel | O que responde |
|---|---|
| Requisições por segundo | Volume de tráfego por serviço e status HTTP |
| Latência p95 | 95% das requisições foram mais rápidas que este valor |
| Taxa de erro | Percentual de respostas 4xx e 5xx sobre o total |

**Por que p95 e não média:** a média esconde os casos ruins. Cem requisições de 10ms e cinco de 3 segundos produzem uma média baixa e nenhum indício de que cinco usuários tiveram uma experiência péssima. O percentil 95 expõe exatamente esse comportamento de cauda.

O dashboard é versionado como código (`k8s/observability/`) e recarregado automaticamente a cada reset do cluster, já que o Grafana não persiste configuração por padrão nesta instalação.

### 4. Avaliações em NoSQL (persistência poliglota)

O CatalogAPI usa **dois bancos simultaneamente**: SQLite para jogos e promoções, MongoDB para avaliações. Não é substituição — é usar o banco adequado a cada tipo de dado.

Avaliações se encaixam no modelo de documento por duas razões:

- **Estrutura flexível.** Uma avaliação pode ganhar resposta do desenvolvedor, votos de "útil" ou tags no futuro, sem exigir migração de schema nem afetar os registros existentes.
- **Volume alto e desbalanceado.** Um jogo popular pode acumular milhares de avaliações enquanto outro não tem nenhuma — uma distribuição que o modelo de documento absorve naturalmente.

Jogos, por outro lado, têm estrutura fixa e relacionamentos (promoções, biblioteca) que o modelo relacional atende melhor. Cada tipo de dado permanece onde faz mais sentido.

A implementação segue o mesmo padrão DDD do restante do projeto: a entidade `Avaliacao` tem construtor privado e factory method com validação, e o repositório é acessado por interface no domínio. A única diferença é a implementação na camada de infraestrutura, que usa o driver do MongoDB em vez do EF Core.

### 5. Cache-aside com TTL curto

`GET /jogos` é o endpoint mais acessado da plataforma e o mais desperdiçador: repete a mesma consulta com joins, o mesmo cálculo de preço promocional e a mesma serialização, para produzir um resultado que raramente muda.

O padrão adotado é **cache-aside**: a aplicação consulta o Redis primeiro e, em caso de ausência, busca no banco e popula o cache. As operações de cache são envolvidas em `try/catch`, de forma que uma indisponibilidade do Redis degrade a performance sem derrubar o endpoint.

**O TTL de 30 segundos é uma decisão de negócio, não técnica.** Ele resolve o problema de invalidação da forma mais simples possível: em vez de rastrear todos os pontos do código que modificam o catálogo e apagar a chave em cada um (correto, porém trabalhoso e fácil de esquecer um caso), aceita-se uma janela de até 30 segundos de defasagem.

Para um catálogo de jogos essa defasagem é irrelevante. Para saldo bancário seria inaceitável. A escolha reflete a tolerância do domínio, não uma limitação da ferramenta.

Usa-se Redis em vez de cache em memória do processo porque, com múltiplas réplicas do CatalogAPI, cada instância teria sua própria cópia com estado divergente. O código trabalha contra a interface `IDistributedCache`, então o Redis é uma implementação substituível.

O header `X-Cache: HIT|MISS` foi adicionado à resposta para tornar o comportamento observável. Medição no cluster: **MISS ~568ms, HIT ~15ms**.

---

## Estrutura do repositório

```
fcg-orchestration/
├── k8s/
│   ├── gateway/          Ingress de roteamento, KongConsumer, KongPlugin, Secret da credencial JWT
│   ├── users-api/        ConfigMap, Secret, Deployment, Service
│   ├── catalog-api/      idem
│   ├── payments-api/     idem
│   ├── rabbitmq/         Deployment + Service
│   ├── mongodb/          Deployment + Service
│   ├── redis/            Deployment + Service
│   └── observability/    ServiceMonitors + dashboard do Grafana como ConfigMap
└── scripts/
    ├── bootstrap-dev.sh  Sobe o ambiente completo do zero
    └── load-image.sh     Carrega uma imagem local nos nós do cluster
```

---

## Notas sobre o ambiente de desenvolvimento

Estas observações são específicas do ambiente usado no desenvolvimento (Docker Desktop com provisionamento via `kind`, no Windows com Git Bash) e podem não se aplicar a outros ambientes.

**Imagens locais não são visíveis ao cluster automaticamente.** Cada nó do cluster é um container com seu próprio containerd, isolado do daemon Docker do host. Uma imagem construída com `docker build` existe no host mas não no nó, resultando em `ErrImageNeverPull`. O script `load-image.sh` resolve isso exportando a imagem e importando-a em cada nó.

Após qualquer alteração de código:
```bash
docker build -t fcg-catalog-api:latest .          # na pasta do serviço
bash scripts/load-image.sh fcg-catalog-api        # na raiz da orquestração
kubectl rollout restart deployment/catalog-api
```

**Services do tipo LoadBalancer não recebem IP externo.** O acesso se dá por `kubectl port-forward`, já automatizado no script de bootstrap.

**O estado não sobrevive à parada do cluster.** Os bancos SQLite não têm volume persistente, então os dados são recriados a cada sessão. O script de bootstrap deixa a infraestrutura pronta; os dados de teste precisam ser recriados manualmente.

**Labels nos Services são obrigatórios para a coleta de métricas.** O `ServiceMonitor` seleciona Services por label, não pods. O script de bootstrap reaplica os labels a cada execução.

**Ordem de aplicação importa no Gateway.** O admission webhook do Kong rejeita um `KongConsumer` cujo Secret de credencial ainda não exista. Como `kubectl apply -f <pasta>/` processa arquivos em ordem alfabética, o Secret é aplicado explicitamente antes do restante.

**Git Bash reescreve caminhos.** Argumentos contendo `:/` ou iniciados por `/` são convertidos para o formato de caminho do Windows antes de chegar ao programa de destino, corrompendo comandos como `kubectl cp pod:/caminho`. Prefixar com `MSYS_NO_PATHCONV=1` desativa a conversão.

---

## Limitações conhecidas

- **Condição de corrida na compra.** A validação de duplicidade em `POST /jogos/{id}/comprar` reduz, mas não elimina, a janela em que duas requisições simultâneas podem passar. A defesa em profundidade é o índice único no banco.
- **Avaliações não validam existência do jogo.** É possível avaliar um `jogoId` inexistente. Uma verificação prévia no repositório de jogos resolveria.
- **Cache sem invalidação explícita.** Alterações no catálogo só se refletem após a expiração do TTL.
- **Observabilidade limitada a métricas.** Traces distribuídos (que permitiriam seguir uma compra através de CatalogAPI → RabbitMQ → PaymentsAPI) não foram implementados — era o diferencial da Opção B, descartada por custo e prazo.
- **Apenas UsersAPI e CatalogAPI instrumentados.** PaymentsAPI e a Function não expõem métricas.
