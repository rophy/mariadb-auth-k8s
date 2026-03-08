#!/bin/bash
# Setup Kind cluster for testing
# Usage: ./scripts/setup-kind-clusters.sh [kind-node-image]
set -e

CLUSTER="cluster-a"
KIND_NODE_IMAGE="${1:-}"

echo "=========================================="
echo "Setting up Kind Cluster"
echo "=========================================="
echo ""

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
    echo "Cluster '$CLUSTER' already exists"
else
    echo "Creating cluster '$CLUSTER'..."
    KIND_ARGS=(create cluster --name "$CLUSTER" --wait 5m)
    if [ -n "$KIND_NODE_IMAGE" ]; then
        echo "Using node image: $KIND_NODE_IMAGE"
        KIND_ARGS+=(--image "$KIND_NODE_IMAGE")
    fi
    kind "${KIND_ARGS[@]}"
    echo "Cluster '$CLUSTER' created"
fi

echo ""
echo "Kind cluster '$CLUSTER' is ready"
echo ""
