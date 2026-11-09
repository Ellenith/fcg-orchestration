#!/usr/bin/env bash
# Cria/atualiza os Secrets do cluster a partir de .env.local (local)
# ou de variáveis de ambiente (CI). Nenhum valor sensível fica no Git.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env.local ]; then set -a; source .env.local; set +a; fi

: "${JWT_SECRET:?defina JWT_SECRET}"
: "${RABBITMQ_PASSWORD:?defina RABBITMQ_PASSWORD}"
JWT_ISSUER="${JWT_ISSUER:-FCG.UsersAPI}"

apply() { kubectl create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -; }

for svc in users-api catalog-api; do
  apply "$svc-secret" \
    --from-literal=Jwt__Secret="$JWT_SECRET" \
    --from-literal=RabbitMQ__Senha="$RABBITMQ_PASSWORD"
done
for svc in payments-api notifications-api; do
  apply "$svc-secret" --from-literal=RabbitMQ__Senha="$RABBITMQ_PASSWORD"
done
apply rabbitmq-secret --from-literal=RABBITMQ_DEFAULT_PASS="$RABBITMQ_PASSWORD"

# Credencial JWT do Kong (mesmo segredo das APIs; key = claim "iss" do token)
apply fcg-jwt-credential \
  --from-literal=key="$JWT_ISSUER" \
  --from-literal=algorithm=HS256 \
  --from-literal=secret="$JWT_SECRET"
kubectl label secret fcg-jwt-credential konghq.com/credential=jwt --overwrite

echo "Secrets criados/atualizados."
