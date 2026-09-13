## API Gateway (Kong)

### Arquitetura
- O quê: Kong Ingress Controller, rodando no cluster K8s local
- Rotas: /auth, /usuarios → UsersAPI; /jogos → CatalogAPI

### Como subir o ambiente
- Aponta pro scripts/bootstrap-dev.sh, explica em 2-3 frases o que ele faz

### Decisão: onde o JWT é validado
- Por que só GET /usuarios tem o plugin (não o prefixo inteiro) — a limitação
  de Ingress não discriminar método HTTP, e a solução via konghq.com/methods
- Deixa claro que autorização fina por Role continua no [Authorize] de cada
  serviço — o Gateway é uma camada extra, não substitui

### Ambiente de desenvolvimento (Docker Desktop + kind)
- Nota curta + link pro inventario_recursos_k8s.md pra detalhes