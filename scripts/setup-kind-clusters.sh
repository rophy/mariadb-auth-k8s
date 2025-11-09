#!/bin/bash
# Setup two kind clusters for multi-cluster testing
set -e

CLUSTER_A="cluster-a"
CLUSTER_B="cluster-b"

echo "=========================================="
echo "Setting up Kind Clusters for Multi-Cluster Testing"
echo "=========================================="
echo ""

# Function to check if cluster exists
cluster_exists() {
    kind get clusters 2>/dev/null | grep -q "^${1}$"
}

# Function to create cluster if it doesn't exist
create_cluster_if_needed() {
    local cluster_name=$1

    if cluster_exists "$cluster_name"; then
        echo "✅ Cluster '$cluster_name' already exists"
    else
        echo "Creating cluster '$cluster_name'..."
        kind create cluster --name "$cluster_name" --wait 5m
        echo "✅ Cluster '$cluster_name' created"
    fi
}

# Create both clusters
create_cluster_if_needed "$CLUSTER_A"
create_cluster_if_needed "$CLUSTER_B"

echo ""
echo "=========================================="
echo "Verifying Cluster Connectivity"
echo "=========================================="

# Get cluster IPs
CLUSTER_A_IP=$(docker inspect ${CLUSTER_A}-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
CLUSTER_B_IP=$(docker inspect ${CLUSTER_B}-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

echo "Cluster-A IP: $CLUSTER_A_IP"
echo "Cluster-B IP: $CLUSTER_B_IP"

# Verify both clusters are on the same network
CLUSTER_A_NETWORK=$(docker inspect ${CLUSTER_A}-control-plane --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}')
CLUSTER_B_NETWORK=$(docker inspect ${CLUSTER_B}-control-plane --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}')

if [ "$CLUSTER_A_NETWORK" = "$CLUSTER_B_NETWORK" ]; then
    echo "✅ Both clusters are on the same Docker network"
else
    echo "⚠️  WARNING: Clusters are on different networks!"
    echo "   This may prevent cross-cluster communication"
fi

echo ""
echo "=========================================="
echo "Cluster Information"
echo "=========================================="
kind get clusters

echo ""
echo "✅ Kind clusters are ready for multi-cluster testing"
echo ""
