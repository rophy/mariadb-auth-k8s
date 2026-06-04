#!/bin/bash
set -euo pipefail

KUBE_CONTEXT="kind-cluster-a"
CLUSTER_NAME="cluster-a"
NAMESPACE="mariadb-auth-test"
TAGS_FILE="${TAGS_FILE:-/tmp/skaffold-build.json}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/../helm/mariadb-auth-k8s" && pwd)"

if [[ ! -f "$TAGS_FILE" ]]; then
    echo "Error: $TAGS_FILE not found. Run 'skaffold build --file-output=$TAGS_FILE' first."
    exit 1
fi

# 1. Load all images into Kind
echo "Loading images into Kind cluster..."
for tag in $(jq -r '.builds[].tag' "$TAGS_FILE"); do
    kind load docker-image "$tag" --name "$CLUSTER_NAME"
done

# 2. Create namespace (needed before TLS secret and skaffold deploy)
echo ""
echo "Ensuring namespace exists..."
kubectl create namespace "$NAMESPACE" --context "$KUBE_CONTEXT" --dry-run=client -o yaml | \
    kubectl apply --context "$KUBE_CONTEXT" -f -

# 3. Generate TLS certs (client pods mount this secret, must exist before they start)
echo ""
echo "Generating TLS certificates..."
"$SCRIPT_DIR/generate-tls-certs.sh"

# 4. Deploy supporting resources (rbac, test clients) via skaffold
echo ""
echo "Deploying resources with skaffold..."
skaffold deploy --build-artifacts="$TAGS_FILE"

# 5. Deploy MariaDB via Helm
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
