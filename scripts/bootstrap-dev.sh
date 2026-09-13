#!/bin/bash
set -e

echo "== 0. Garantindo Kong (Helm release + CRDs) =="
helm upgrade --install kong kong/ingress -n kong --create-namespace
kubectl apply -k github.com/kong/kubernetes-configuration/config/crd/ingress-controller

echo "== 0.1 Garantindo stack de observabilidade (Prometheus + Grafana) =="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
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

echo "== 2. Aplicando infraestrutura de dados (RabbitMQ, MongoDB, Redis) =="
kubectl apply -f ./k8s/rabbitmq/deployment.yaml
kubectl apply -f ./k8s/mongodb/deployment.yaml
kubectl apply -f ./k8s/redis/deployment.yaml
kubectl wait --for=condition=Ready pod -l app=rabbitmq --timeout=120s
kubectl wait --for=condition=Ready pod -l app=mongodb --timeout=120s
kubectl wait --for=condition=Ready pod -l app=redis --timeout=120s

echo "== 3. Aplicando os 3 microsserviços =="
kubectl apply -f ./k8s/users-api/
kubectl apply -f ./k8s/catalog-api/
kubectl apply -f ./k8s/payments-api/

echo "== 3.1 Garantindo labels nos Services (necessário pro ServiceMonitor) =="
kubectl label svc users-api app=users-api --overwrite
kubectl label svc catalog-api app=catalog-api --overwrite

echo "== 4. Aplicando manifests do Gateway (Kong) =="
kubectl apply -f ./k8s/gateway/jwt-credential-secret.yaml
kubectl apply -f ./k8s/gateway/

echo "== 4.1 Aplicando ServiceMonitors e dashboard =="
kubectl apply -f ./k8s/observability/servicemonitors.yaml
kubectl apply -f ./k8s/observability/dashboard-configmap.yaml

echo "== 5. Aguardando os pods ficarem prontos =="
kubectl wait --for=condition=Ready pod -l app=users-api --timeout=90s
kubectl wait --for=condition=Ready pod -l app=catalog-api --timeout=90s
kubectl wait --for=condition=Ready pod -l app=payments-api --timeout=90s

echo "== 6. Iniciando port-forwards em background =="
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2
kubectl port-forward -n kong service/kong-gateway-proxy 8000:80 > /tmp/pf-kong.log 2>&1 &
kubectl port-forward svc/users-api 8081:80 > /tmp/pf-users-api.log 2>&1 &
kubectl port-forward svc/catalog-api 8082:80 > /tmp/pf-catalog-api.log 2>&1 &
kubectl port-forward svc/rabbitmq 5672:5672 > /tmp/pf-rabbitmq.log 2>&1 &
kubectl port-forward svc/mongodb 27017:27017 > /tmp/pf-mongodb.log 2>&1 &
kubectl port-forward svc/redis 6379:6379 > /tmp/pf-redis.log 2>&1 &
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 > /tmp/pf-prometheus.log 2>&1 &
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 > /tmp/pf-grafana.log 2>&1 &
sleep 3

echo "✅ Ambiente pronto:"
echo "   Kong (Gateway):       http://localhost:8000"
echo "   UsersAPI direto:      http://localhost:8081"
echo "   CatalogAPI direto:    http://localhost:8082"
echo "   RabbitMQ:             localhost:5672"
echo "   MongoDB:              localhost:27017"
echo "   Redis:                localhost:6379"
echo "   Prometheus:           http://localhost:9090"
echo "   Grafana:              http://localhost:3000 (admin)"
