#!/bin/bash
# Test multi-cluster authentication
set -e

CLUSTER_A="cluster-a"
CLUSTER_B="cluster-b"
NAMESPACE_A="mariadb-auth-test"
NAMESPACE_B="remote-test"

echo "=========================================="
echo "Multi-Cluster Authentication Tests"
echo "=========================================="
echo ""

# Get MariaDB NodePort and cluster-a IP for cross-cluster access
kubectl config use-context kind-${CLUSTER_A} > /dev/null
MARIADB_SERVICE_IP=$(kubectl get svc mariadb -n ${NAMESPACE_A} -o jsonpath='{.spec.clusterIP}')
MARIADB_NODEPORT=$(kubectl get svc mariadb-nodeport -n ${NAMESPACE_A} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30306")
CLUSTER_A_IP=$(docker inspect ${CLUSTER_A}-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

echo "Test Configuration:"
echo "  MariaDB Service IP (internal): $MARIADB_SERVICE_IP"
echo "  MariaDB NodePort (cross-cluster): $CLUSTER_A_IP:$MARIADB_NODEPORT"
echo ""

# Test 1: Local cluster authentication (from cluster-a)
echo "=========================================="
echo "Test 1: Local Cluster Authentication"
echo "=========================================="
echo ""

kubectl config use-context kind-${CLUSTER_A} > /dev/null

echo "Testing user: local/mariadb-auth-test/user1..."
# Use mounted projected token (1 hour TTL configured in deployment)
kubectl exec -n ${NAMESPACE_A} deployment/client-user1 -- bash -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    mysql -h mariadb -u "local/mariadb-auth-test/user1" -p"$SA_TOKEN" -e "
        SELECT \"✅ Local authentication successful\" AS status;
        SELECT USER() AS user, CURRENT_USER() AS authenticated_as;
    " 2>&1
' || {
    echo "❌ Test 1 FAILED"
    exit 1
}

echo ""
echo "✅ Test 1 PASSED: Local cluster authentication works"
echo ""

# Test 2: Remote Cluster Authentication (Direct Connection via NodePort)
echo "=========================================="
echo "Test 2: Direct Cross-Cluster Authentication"
echo "=========================================="
echo ""

echo "Testing DIRECT connection from cluster-b to cluster-a MariaDB:"
echo "  - Extract ServiceAccount token from cluster-b"
echo "  - Connect directly to MariaDB via NodePort ($CLUSTER_A_IP:$MARIADB_NODEPORT)"
echo "  - kube-federated-auth validates against cluster-b's K8s API"
echo ""

kubectl config use-context kind-${CLUSTER_B} > /dev/null

# Get the token from cluster-b
echo "Extracting ServiceAccount token from cluster-b..."
REMOTE_TOKEN=$(kubectl create token remote-user -n ${NAMESPACE_B} --duration=1h)
echo "✅ Token extracted from cluster-b/remote-test/remote-user"
echo ""

# Connect directly from cluster-b pod to cluster-a MariaDB via NodePort
echo "Connecting DIRECTLY from cluster-b pod to cluster-a MariaDB..."
kubectl exec -n ${NAMESPACE_B} deployment/remote-client -- bash -c "
    mysql -h ${CLUSTER_A_IP} -P ${MARIADB_NODEPORT} -u 'cluster-b/remote-test/remote-user' -p'${REMOTE_TOKEN}' -e '
        SELECT \"🎉 Direct cross-cluster connection successful!\" AS status;
        SELECT USER() AS user, CURRENT_USER() AS authenticated_as;
        SELECT \"Pod in cluster-b → MariaDB in cluster-a via NodePort\" AS connection_path;
        SHOW DATABASES;
    ' 2>&1
" || {
    echo "❌ Test 2 FAILED"
    exit 1
}

echo ""
echo "✅ Test 2 PASSED: Direct cross-cluster authentication works!"
echo "   Pod in cluster-b successfully connected to MariaDB in cluster-a via NodePort"
echo ""

# Test 3: Token TTL validation (reject long-lived tokens)
echo "=========================================="
echo "Test 3: Token TTL Validation"
echo "=========================================="
echo ""

kubectl config use-context kind-${CLUSTER_A} > /dev/null

echo "Testing that tokens exceeding MAX_TOKEN_TTL are rejected..."
echo "Creating a 2-hour token (exceeds MAX_TOKEN_TTL=3600)..."
TOKEN_2H=$(kubectl create token user1 -n ${NAMESPACE_A} --duration=2h)

echo "Attempting authentication with 2-hour token (should fail)..."
kubectl run test-long-token --image=mysql:8.0 --rm -i --restart=Never -n ${NAMESPACE_A} -- \
    mysql --enable-cleartext-plugin -h mariadb -u "local/mariadb-auth-test/user1" -p"${TOKEN_2H}" -e "SELECT 1;" 2>&1 | \
    grep -q "Access denied" && echo "✅ 2-hour token rejected (as expected)" || {
    echo "❌ Test 3 FAILED: 2-hour token should have been rejected"
    exit 1
}

echo ""
echo "✅ Test 3 PASSED: Token TTL validation works correctly"
echo ""

# Test 4: Permission verification
echo "=========================================="
echo "Test 4: Permission Verification"
echo "=========================================="
echo ""

kubectl config use-context kind-${CLUSTER_A} > /dev/null

echo "Testing that local/mariadb-auth-test/user2 has limited access..."
# Use mounted projected token (1 hour TTL configured in deployment)
kubectl exec -n ${NAMESPACE_A} deployment/client-user2 -- bash -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

    # Should succeed
    mysql -h mariadb -u "local/mariadb-auth-test/user2" -p"$SA_TOKEN" -e "USE testdb; SELECT 1;" > /dev/null 2>&1 && echo "✅ Can access testdb"

    # Should fail
    mysql -h mariadb -u "local/mariadb-auth-test/user2" -p"$SA_TOKEN" -e "USE mysql; SELECT 1;" 2>&1 | grep -q "Access denied" && echo "✅ Cannot access mysql (as expected)"
' || {
    echo "❌ Test 4 FAILED"
    exit 1
}

echo ""
echo "✅ Test 4 PASSED: Permission restrictions work correctly"
echo ""

# Summary
echo "=========================================="
echo "✅ All Multi-Cluster Tests PASSED!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  ✅ Local cluster authentication (cluster-a → cluster-a)"
echo "  ✅ Remote cluster authentication (cluster-b token → cluster-a)"
echo "  ✅ Token TTL validation (2-hour tokens rejected)"
echo "  ✅ Permission restrictions enforced"
echo ""
echo "Multi-cluster authentication is working correctly!"
