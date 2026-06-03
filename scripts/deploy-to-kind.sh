#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="kind-cluster-a"
CLUSTER_NAME="cluster-a"
NAMESPACE="mariadb-auth-test"
TAGS_FILE="${TAGS_FILE:-/tmp/skaffold-build.json}"
CHART_DIR="$(cd "$(dirname "$0")/../helm/mariadb-auth-k8s" && pwd)"

if [[ ! -f "$TAGS_FILE" ]]; then
    echo "Error: $TAGS_FILE not found. Run 'skaffold build --file-output=$TAGS_FILE' first."
    exit 1
fi

# Load all images into Kind
echo "Loading images into Kind cluster..."
for tag in $(jq -r '.builds[].tag' "$TAGS_FILE"); do
    kind load docker-image "$tag" --name "$CLUSTER_NAME"
done

# Deploy supporting resources (namespace, rbac, test clients) via skaffold
echo ""
echo "Deploying resources with skaffold..."
skaffold deploy --build-artifacts="$TAGS_FILE"

# Deploy MariaDB via Helm
MARIADB_IMAGE=$(jq -r '.builds[] | select(.imageName=="mariadb-server") | .tag' "$TAGS_FILE")
REPO="${MARIADB_IMAGE%%:*}"
TAG="${MARIADB_IMAGE#*:}"

echo ""
echo "Deploying MariaDB via Helm (image=$REPO:$TAG)..."
helm upgrade --install mariadb "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --kube-context "$KUBE_CONTEXT" \
    --set "image.repository=$REPO" \
    --set "image.tag=$TAG" \
    --set tls.enabled=true \
    --set service.type=NodePort \
    --set service.nodePort=30306 \
    --wait --timeout 90s
