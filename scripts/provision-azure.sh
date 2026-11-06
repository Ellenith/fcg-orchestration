#!/usr/bin/env bash
# Provisiona RG + ACR + AKS (1 nó, tier Free) para a Fase 4.
# Uso: bash scripts/provision-azure.sh
set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RG="${RG:-rg-fcg}"
AKS_NAME="${AKS_NAME:-aks-fcg}"
NODE_SIZE="${NODE_SIZE:-Standard_D2s_v4}"
# Nome do ACR precisa ser único globalmente, minúsculo e alfanumérico.
# Derivado do ID da assinatura para ser sempre o mesmo nas reexecuções.
SUB_ID="$(az account show --query id -o tsv)"
ACR_NAME="${ACR_NAME:-fcgacr$(echo "$SUB_ID" | tr -d '-' | cut -c1-8)}"

echo ">> Assinatura: $SUB_ID | Região: $LOCATION | ACR: $ACR_NAME"

echo ">> Registrando resource providers (necessário em assinatura nova)"
for ns in Microsoft.ContainerService Microsoft.ContainerRegistry \
          Microsoft.Compute Microsoft.Network Microsoft.Storage; do
  az provider register --namespace "$ns" --wait
done

echo ">> Resource Group"
az group create --name "$RG" --location "$LOCATION" -o none

echo ">> ACR (SKU Basic)"
az acr create --resource-group "$RG" --name "$ACR_NAME" --sku Basic -o none

echo ">> AKS (tier Free, 1 nó, ACR anexado)"
az aks create \
  --resource-group "$RG" \
  --name "$AKS_NAME" \
  --tier free \
  --node-count 1 \
  --node-vm-size "$NODE_SIZE" \
  --generate-ssh-keys \
  --attach-acr "$ACR_NAME" \
  -o none

echo ">> Credenciais do kubectl"
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing

kubectl get nodes
echo ">> Pronto. Lembre de rodar 'az aks stop -g $RG -n $AKS_NAME' ao fim da sessão."