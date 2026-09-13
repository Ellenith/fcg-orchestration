#!/bin/bash
load_image() {
  local IMAGE=$1
  if [ -z "$IMAGE" ]; then
    echo "Uso: load-image.sh fcg-payments-api"
    return 1
  fi
  docker save "$IMAGE:latest" -o "$IMAGE.tar" || { echo "Falhou no docker save"; return 1; }
  for NODE in $(docker ps --filter "name=desktop-" --format "{{.Names}}"); do
    echo "→ carregando $IMAGE em $NODE"
    docker cp "$IMAGE.tar" "$NODE":/"$IMAGE.tar" || { echo "Falhou no docker cp"; return 1; }
    MSYS_NO_PATHCONV=1 docker exec "$NODE" ctr -n k8s.io images import "/$IMAGE.tar" || { echo "Falhou no ctr import"; return 1; }
    docker exec "$NODE" ctr -n k8s.io images tag "docker.io/library/$IMAGE:latest" "$IMAGE:latest" || { echo "Falhou no ctr tag"; return 1; }
  done
  rm "$IMAGE.tar"
  echo "✅ $IMAGE carregada com sucesso"
}
load_image "$1"
