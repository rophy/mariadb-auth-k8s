#!/bin/bash
# Setup Kind cluster for testing
set -e

CLUSTER="cluster-a"

echo "=========================================="
echo "Setting up Kind Cluster"
echo "=========================================="
echo ""

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
    echo "Cluster '$CLUSTER' already exists"
else
    echo "Creating cluster '$CLUSTER'..."
    kind create cluster --name "$CLUSTER" --wait 5m
    echo "Cluster '$CLUSTER' created"
fi

echo ""
echo "Kind cluster '$CLUSTER' is ready"
echo ""
