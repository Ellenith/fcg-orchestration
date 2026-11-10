# Uso: source scripts/env.sh   (carrega .env.local e define $ES)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || return
set -a; source .env.local; set +a
export ES="${ELASTIC_ENDPOINT%/}"
