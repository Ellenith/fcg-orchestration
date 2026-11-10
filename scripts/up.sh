#!/usr/bin/env bash
# ============================================================
# scripts/up.sh — Prepara a sessão de trabalho da Fase 4
#
# Uso (sempre com "source", para as variáveis ficarem no terminal):
#   source scripts/up.sh
#
# O que faz:
#   1. Garante o login no Azure
#   2. Liga o AKS (se estiver parado) e aponta o kubectl para ele
#   3. Carrega o .env.local e define $ES (Elasticsearch)
#   4. Descobre o IP público do Kong ($IP)
#   5. Faz login do Admin de teste e define $TOKEN
#
# Ao final, disponibiliza as funções:
#   login   -> gera um novo $TOKEN (vale 60 min)
#   down    -> para o AKS (economiza custo)
#
# Não usa "set -e": o script é "sourced" e fecharia o terminal.
# ============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || return 1

RG="rg-fcg"
AKS="aks-fcg"
TENANT="5602ebdc-a1cf-4f15-8f52-3793b7017caf"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@fcg.com}"
ADMIN_SENHA="${ADMIN_SENHA:-Senha@123}"   # conta de teste, cluster descartável

# 1) Login no Azure
if ! az account show --query state -o tsv >/dev/null 2>&1; then
  echo ">> Login no Azure..."
  az login --tenant "$TENANT" >/dev/null || return 1
fi

# 2) Cluster
estado=$(az aks show -g "$RG" -n "$AKS" --query powerState.code -o tsv 2>/dev/null | tr -d "\r")
if [ "$estado" != "Running" ]; then
  echo ">> Ligando o AKS (estado atual: ${estado:-desconhecido})..."
  az aks start -g "$RG" -n "$AKS" || return 1
fi
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing >/dev/null
kubectl config use-context "$AKS" >/dev/null
echo ">> kubectl: $(kubectl config current-context)"

echo ">> Aguardando o nó e os deployments ficarem prontos..."
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
kubectl wait --for=condition=Available deployment --all --timeout=300s >/dev/null \
  || echo "   (algum deployment ainda não está disponível — confira com 'kubectl get pods')"

# 3) Variáveis do .env.local
if [ -f .env.local ]; then
  set -a; source .env.local; set +a
  export ES="${ELASTIC_ENDPOINT%/}"
else
  echo "!! .env.local não encontrado em $ROOT"
fi

# 4) IP público do Kong (espera até ~5 min)
IP=""
for _ in $(seq 1 30); do
  IP=$(kubectl get svc -n kong kong-gateway-proxy \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$IP" ] && break
  sleep 10
done
export IP
echo ">> Kong: ${IP:-NÃO ENCONTRADO}"

# 5) Funções utilitárias
login() {
  TOKEN=$(curl -s -X POST "http://$IP/auth/login" -H "Content-Type: application/json" \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"senha\":\"$ADMIN_SENHA\"}" \
    | sed -E 's/.*"token":"([^"]+)".*/\1/')
  export TOKEN
  echo ">> token: ${#TOKEN} caracteres"
}

down() {
  az aks stop -g "$RG" -n "$AKS"
}

login
echo ">> Pronto. Use 'login' para renovar o token e 'down' ao encerrar."
