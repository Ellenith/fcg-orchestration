#!/bin/bash
set -e

echo "== 0. Garantindo Kong (Helm release + CRDs) =="
helm upgrade --install kong kong/ingress -n kong --create-namespace
kubectl apply -k github.com/kong/kubernetes-configuration/config/crd/ingress-controller
sleep 15

echo "== 1. Carregando imagens em todos os nós =="
for IMAGE in fcg-users-api fcg-catalog-api fcg-payments-api; do
  docker save "$IMAGE:latest" -o "$IMAGE.tar"
  for NODE in $(docker ps --filter "name=desktop-" --format "{{.Names}}"); do
    echo "→ carregando $IMAGE em $NODE"
    docker cp "$IMAGE.tar" "$NODE":/"$IMAGE.tar"
    MSYS_NO_PATHCONV=1 docker exec "$NODE" ctr -n k8s.io images import "/$IMAGE.tar"
    docker exec "$NODE" ctr -n k8s.io images tag "docker.io/library/$IMAGE:latest" "$IMAGE:latest"
  done
  rm "$IMAGE.tar"
done

echo "== 2. Aplicando RabbitMQ =="
kubectl apply -f ./rabbitmq/deployment.yaml
kubectl wait --for=condition=Ready pod -l app=rabbitmq --timeout=90s

echo "== 3. Aplicando ConfigMap/Secret/Deployment/Service dos 3 microsserviços =="
kubectl apply -f ./users-api/
kubectl apply -f ./catalog-api/
kubectl apply -f ./payments-api/

echo "== 4. Aplicando manifests do Gateway (Kong) =="
kubectl apply -f ./gateway/jwt-credential-secret.yaml
kubectl apply -f ./gateway/

echo "== 5. Aguardando os pods ficarem prontos =="
kubectl wait --for=condition=Ready pod -l app=users-api --timeout=90s
kubectl wait --for=condition=Ready pod -l app=catalog-api --timeout=90s
kubectl wait --for=condition=Ready pod -l app=payments-api --timeout=90s

echo "== 6. Iniciando port-forwards em background =="
kubectl port-forward -n kong service/kong-gateway-proxy 8000:80 > /tmp/pf-kong.log 2>&1 &
kubectl port-forward svc/users-api 8081:80 > /tmp/pf-users-api.log 2>&1 &
kubectl port-forward svc/catalog-api 8082:80 > /tmp/pf-catalog-api.log 2>&1 &
kubectl port-forward svc/rabbitmq 5672:5672 > /tmp/pf-rabbitmq.log 2>&1 &
sleep 3

echo "✅ Ambiente pronto:"
echo "   Kong (Gateway):       http://localhost:8000"
echo "   UsersAPI direto:      http://localhost:8081"
echo "   CatalogAPI direto:    http://localhost:8082"
echo "   RabbitMQ:             localhost:5672"
