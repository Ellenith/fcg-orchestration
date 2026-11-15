#!/usr/bin/env bash
# ============================================================
# scripts/smoke-test.sh — Teste ponta a ponta da FCG no AKS
#
# Uso:
#   source scripts/up.sh        # liga o cluster e define $IP
#   bash scripts/smoke-test.sh
#
# Cobre: cadastro, login, JWT no Gateway, perfis (Admin x User),
# catálogo, cache (Redis), busca fuzzy (Elasticsearch),
# sincronização do índice, avaliações (MongoDB), promoção e compra
# (CatalogAPI -> RabbitMQ -> PaymentsAPI -> biblioteca).
#
# É idempotente: pode rodar várias vezes (cadastros repetidos
# retornam 400 e são aceitos).
# ============================================================

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@fcg.com}"
USER_EMAIL="${USER_EMAIL:-user@fcg.com}"
SENHA="${SENHA:-Senha@123}"           # contas de teste (cluster descartável)

if [ -z "${IP:-}" ]; then
  IP=$(kubectl get svc -n kong kong-gateway-proxy \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | tr -d '\r')
fi
if [ -z "$IP" ]; then echo "IP do Kong não encontrado. Rode: source scripts/up.sh"; exit 1; fi
BASE="http://$IP"

PASS=0; FAIL=0; BODY=""; CODE=""

# t "descrição" "códigos aceitos (ex.: 200|201)" METHOD /caminho [token] [json]
# (sem arquivo temporário: no Git Bash o curl é um programa do Windows e
#  não enxerga o /tmp do Git Bash; a resposta e o código vêm na mesma saída)
t() {
  local desc="$1" ok="$2" method="$3" path="$4" token="${5:-}" data="${6:-}"
  local args=(-s -m 30 -w $'\n%{http_code}' -X "$method" "$BASE$path")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$data" ]  && args+=(-H "Content-Type: application/json" -d "$data")
  local resp
  resp=$(curl "${args[@]}" | tr -d '\r')
  CODE="${resp##*$'\n'}"
  BODY="${resp%$'\n'*}"
  if [[ "$CODE" =~ ^($ok)$ ]]; then
    PASS=$((PASS+1)); printf "  [OK]    %-52s HTTP %s\n" "$desc" "$CODE"
  else
    FAIL=$((FAIL+1)); printf "  [FALHA] %-52s HTTP %s (esperado %s)\n" "$desc" "$CODE" "$ok"
    printf "          %s\n" "$(echo "$BODY" | head -c 220)"
  fi
}

pega() { sed -E "s/.*\"$1\":\"([^\"]+)\".*/\1/"; }          # valor de um campo string do JSON
primeiro_id() { echo "$1" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4; }

echo "== Kong: $BASE"

# ---------- 1. Usuários e login ----------
echo; echo "1) Usuários e autenticação"
t "Cadastrar Admin (1º usuário vira Admin)" "201|400" POST /usuarios "" \
  "{\"nome\":\"Admin\",\"email\":\"$ADMIN_EMAIL\",\"senha\":\"$SENHA\"}"
t "Cadastrar usuário comum"               "201|400" POST /usuarios "" \
  "{\"nome\":\"Usuario Teste\",\"email\":\"$USER_EMAIL\",\"senha\":\"$SENHA\"}"

t "Login do Admin" "200" POST /auth/login "" "{\"email\":\"$ADMIN_EMAIL\",\"senha\":\"$SENHA\"}"
TOKEN=$(echo "$BODY" | pega token)
t "Login do usuário comum" "200" POST /auth/login "" "{\"email\":\"$USER_EMAIL\",\"senha\":\"$SENHA\"}"
UTOKEN=$(echo "$BODY" | pega token)
echo "  tokens: admin=${#TOKEN} chars, user=${#UTOKEN} chars"
if [ ${#TOKEN} -lt 100 ] || [ ${#UTOKEN} -lt 100 ]; then
  echo "Falha ao obter os tokens; os próximos passos dependem deles. Abortando."; exit 1
fi
if [ "${#TOKEN}" -lt 100 ] || [ "${#UTOKEN}" -lt 100 ]; then
  echo "  !! Não foi possível obter os tokens; os testes seguintes não fazem sentido. Verifique os logins acima."
  exit 1
fi

t "Login com senha errada é recusado"     "400|401" POST /auth/login "" \
  "{\"email\":\"$ADMIN_EMAIL\",\"senha\":\"Errada@999\"}"

# ---------- 2. JWT no Gateway e perfis ----------
echo; echo "2) JWT no Gateway e perfis"
t "GET /usuarios sem token -> barrado no Kong"  "401" GET /usuarios
t "GET /usuarios com token inválido"            "401" GET /usuarios "token.invalido.xyz"
t "GET /usuarios com usuário comum (não Admin)" "403" GET /usuarios "$UTOKEN"
t "GET /usuarios com Admin"                     "200" GET /usuarios "$TOKEN"

# ---------- 3. Catálogo ----------
echo; echo "3) Catálogo"
t "Cadastrar jogo como usuário comum é proibido" "401|403" POST /jogos "$UTOKEN" \
  '{"titulo":"Nao Deve Criar","descricao":"teste","preco":10}'
t "Cadastrar jogo (Admin)" "201|400" POST /jogos "$TOKEN" \
  '{"titulo":"Stardew Valley","descricao":"Simulador de fazenda e vida no campo","preco":49.9}'

# ---------- 4. Cache ----------
echo; echo "4) Cache (Redis): GET /jogos duas vezes"
for i in 1 2; do
  H=$(curl -s -m 30 -o /dev/null -D - "$BASE/jogos" | tr -d '\r')
  echo "  chamada $i -> $(echo "$H" | grep -i '^x-cache' | tr -d '\n')  |  $(echo "$H" | grep -i '^x-kong-upstream-latency' | tr -d '\n') ms"
done
echo "  (esperado: 1ª MISS e latência maior; 2ª HIT e latência menor)"

# ---------- 5. Busca ----------
echo; echo "5) Busca (Elasticsearch)"
sleep 5
t "Busca exata: stardew"                        "200" GET "/search?q=stardew"
JOGO=$(primeiro_id "$BODY")
[ -z "$JOGO" ] && { t "Reindexar (Admin)" "200" POST /search/reindexar "$TOKEN"; sleep 5; \
                    t "Busca exata: stardew" "200" GET "/search?q=stardew"; JOGO=$(primeiro_id "$BODY"); }
echo "  jogo de teste: ${JOGO:-NÃO ENCONTRADO}"
if [ -z "$JOGO" ]; then
  echo "  !! Jogo de teste não encontrado no índice; abortando os blocos 6 a 8."
  exit 1
fi
t "Busca com erro de digitação: stardw"          "200" GET "/search?q=stardw"
echo "  $(echo "$BODY" | head -c 160)"
t "Busca sem termo é rejeitada"                  "400" GET "/search"
t "Reindexar como usuário comum é proibido"      "401|403" POST /search/reindexar "$UTOKEN"

# ---------- 6. Avaliações ----------
echo; echo "6) Avaliações (MongoDB)"
t "Avaliar o jogo (usuário comum)" "201" POST "/jogos/$JOGO/avaliacoes" "$UTOKEN" \
  '{"nota":5,"comentario":"Relaxante e viciante"}'
t "Listar avaliações do jogo"      "200" GET  "/jogos/$JOGO/avaliacoes"
echo "  $(echo "$BODY" | head -c 200)"

# ---------- 7. Promoção ----------
echo; echo "7) Promoção"
INI=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S)
FIM=$(date -u -d '+7 days' +%Y-%m-%dT%H:%M:%S)
t "Criar promoção de 20% (Admin)" "200|201|400" POST "/jogos/$JOGO/promocoes" "$TOKEN" \
  "{\"percentualDesconto\":20,\"inicio\":\"$INI\",\"fim\":\"$FIM\"}"
t "Listar promoções ativas"       "200" GET /jogos/promocoes
echo "  $(echo "$BODY" | head -c 220)"

# ---------- 8. Compra (fluxo assíncrono) ----------
echo; echo "8) Compra: CatalogAPI -> RabbitMQ -> PaymentsAPI -> biblioteca"
t "Comprar o jogo (usuário comum)" "202|400" POST "/jogos/$JOGO/comprar" "$UTOKEN"
echo "  aguardando o processamento do pagamento..."
sleep 8
t "Biblioteca do usuário"          "200|404" GET /biblioteca "$UTOKEN"
echo "  $(echo "$BODY" | head -c 220)"
t "Comprar de novo é recusado (já possui)" "400" POST "/jogos/$JOGO/comprar" "$UTOKEN"

echo; echo "== Resultado: $PASS OK, $FAIL falha(s)"
if [ "$FAIL" -gt 0 ]; then
  echo "Dicas:"
  echo "  - 404 em /biblioteca: a rota pode não existir no Gateway; confira com 'kubectl logs deployment/catalog-api --tail=30'"
  echo "  - compra sem efeito: 'kubectl logs deployment/payments-api --tail=30' e 'kubectl get pods'"
  exit 1
fi
