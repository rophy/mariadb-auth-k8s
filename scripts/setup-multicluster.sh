#!/bin/bash
# Setup multi-cluster authentication after deployment
set -e

CLUSTER_A="cluster-a"
CLUSTER_B="cluster-b"
NAMESPACE_A="mariadb-auth-test"
NAMESPACE_B="remote-test"

echo "=========================================="
echo "Configuring Multi-Cluster Authentication"
echo "=========================================="
echo ""

# Get cluster-b IP address
CLUSTER_B_IP=$(docker inspect ${CLUSTER_B}-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "Cluster-B API Server IP: $CLUSTER_B_IP"

# Switch to cluster-b and extract credentials
echo ""
echo "Extracting cluster-b credentials..."
kubectl config use-context kind-${CLUSTER_B} > /dev/null

# Wait for namespace to exist
echo "Waiting for namespace ${NAMESPACE_B} to be ready..."
timeout 60s bash -c "until kubectl get namespace ${NAMESPACE_B} > /dev/null 2>&1; do sleep 2; done" || {
    echo "ERROR: Namespace ${NAMESPACE_B} not ready"
    exit 1
}

# Wait for ServiceAccount to exist
echo "Waiting for ServiceAccount remote-user to be ready..."
timeout 60s bash -c "until kubectl get serviceaccount remote-user -n ${NAMESPACE_B} > /dev/null 2>&1; do sleep 2; done" || {
    echo "ERROR: ServiceAccount remote-user not ready"
    exit 1
}

# Create a long-lived token
TOKEN_FILE="/tmp/cluster-b-token-multicluster.txt"
kubectl create token remote-user -n ${NAMESPACE_B} --duration=24h > "$TOKEN_FILE"
echo "Created token"

# Extract CA certificate
CA_FILE="/tmp/cluster-b-ca-multicluster.crt"
kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' > "$CA_FILE"
echo "CA certificate extracted"

# Get issuer from token
ISSUER=$(cat "$TOKEN_FILE" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq -r '.iss')
echo "Cluster-B Issuer: $ISSUER"

# Switch to cluster-a
echo ""
echo "Configuring cluster-a..."
kubectl config use-context kind-${CLUSTER_A} > /dev/null

# Wait for namespace to exist
timeout 60s bash -c "until kubectl get namespace ${NAMESPACE_A} > /dev/null 2>&1; do sleep 2; done" || {
    echo "ERROR: Namespace ${NAMESPACE_A} not ready"
    exit 1
}

# Create or update secret with cluster-b credentials
kubectl delete secret kube-federated-auth-remote-clusters -n ${NAMESPACE_A} 2>/dev/null || true
kubectl create secret generic kube-federated-auth-remote-clusters \
  --from-file=cluster-b-ca.crt="$CA_FILE" \
  --from-file=cluster-b-token="$TOKEN_FILE" \
  -n ${NAMESPACE_A}
echo "Secret created in cluster-a"

# Update ConfigMap with cluster-b configuration (new format: map instead of list)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-federated-auth-config
  namespace: ${NAMESPACE_A}
data:
  clusters.yaml: |
    renewal:
      interval: "1h"
      token_duration: "168h"
      renew_before: "48h"

    clusters:
      # Local cluster - use in-cluster credentials for OIDC discovery
      local:
        issuer: "https://kubernetes.default.svc.cluster.local"
        ca_cert: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        token_path: "/var/run/secrets/kubernetes.io/serviceaccount/token"

      # External cluster-b
      cluster-b:
        issuer: "${ISSUER}"
        api_server: "https://${CLUSTER_B_IP}:6443"
        ca_cert: "/etc/secrets/cluster-b-ca.crt"
        token_path: "/etc/secrets/cluster-b-token"
EOF
echo "ConfigMap updated"

# Patch kube-federated-auth deployment to use the secret
echo ""
echo "Updating kube-federated-auth deployment..."
kubectl patch deployment kube-federated-auth -n ${NAMESPACE_A} --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/volumes/1/secret/secretName", "value":"kube-federated-auth-remote-clusters"},
  {"op": "replace", "path": "/spec/template/spec/volumes/1/secret/optional", "value":false}
]' 2>/dev/null || {
    echo "Note: Secret volume may already be configured"
}

# Wait for kube-federated-auth to be ready
echo "Waiting for kube-federated-auth to restart..."
kubectl rollout status deployment/kube-federated-auth -n ${NAMESPACE_A} --timeout=120s

# Verify kube-federated-auth sees both clusters
echo ""
echo "Verifying kube-federated-auth configuration..."
sleep 5
kubectl logs -n ${NAMESPACE_A} -l app=kube-federated-auth --tail=10 | grep -E "cluster|Loaded" || {
    echo "Note: Could not verify cluster configuration in logs"
}

# Create MariaDB user for cluster-b remote-user
echo ""
echo "Creating MariaDB user for cluster-b/remote-test/remote-user..."

# Wait for MariaDB to be ready
kubectl wait --for=condition=ready pod -l app=mariadb -n ${NAMESPACE_A} --timeout=120s

kubectl exec -n ${NAMESPACE_A} deployment/mariadb -- mysql -u root -e "
CREATE USER IF NOT EXISTS 'cluster-b/remote-test/remote-user'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON *.* TO 'cluster-b/remote-test/remote-user'@'%';
FLUSH PRIVILEGES;
" || {
    echo "Note: MariaDB user may already exist"
}

echo "MariaDB user created"

# Get MariaDB service IP for reference
MARIADB_IP=$(kubectl get svc mariadb -n ${NAMESPACE_A} -o jsonpath='{.spec.clusterIP}')
echo ""
echo "=========================================="
echo "Multi-Cluster Setup Complete"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  Cluster-A (MariaDB): kind-${CLUSTER_A}"
echo "  Cluster-B (Client):  kind-${CLUSTER_B}"
echo "  MariaDB Service IP:  $MARIADB_IP"
echo "  Cluster-B API:       https://${CLUSTER_B_IP}:6443"
echo ""
echo "MariaDB Users:"
echo "  - local/mariadb-auth-test/user1 (full access)"
echo "  - local/mariadb-auth-test/user2 (limited access)"
echo "  - cluster-b/remote-test/remote-user (full access)"
echo ""
