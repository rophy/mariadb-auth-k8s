#!/bin/bash
# Test Kubernetes TokenReview authentication
set -e

CLUSTER_A="cluster-a"
NAMESPACE="mariadb-auth-test"

echo "=========================================="
echo "Kubernetes TokenReview Authentication Tests"
echo "=========================================="
echo ""

kubectl config use-context kind-${CLUSTER_A} > /dev/null

# Test 1: Basic authentication
echo "=========================================="
echo "Test 1: Basic Authentication"
echo "=========================================="
echo ""

echo "Testing user: mariadb-auth-test/user1..."
# Use mounted projected token (1 hour TTL configured in deployment)
kubectl exec -n ${NAMESPACE} deployment/client-user1 -- bash -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    mysql -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "
        SELECT \"✅ Authentication successful\" AS status;
        SELECT USER() AS user, CURRENT_USER() AS authenticated_as;
    " 2>&1
' || {
    echo "❌ Test 1 FAILED"
    exit 1
}

echo ""
echo "✅ Test 1 PASSED: Basic authentication works"
echo ""

# Test 2: Permission verification
echo "=========================================="
echo "Test 2: Permission Verification"
echo "=========================================="
echo ""

echo "Testing that mariadb-auth-test/user2 has limited access..."
# Use mounted projected token (1 hour TTL configured in deployment)
kubectl exec -n ${NAMESPACE} deployment/client-user2 -- bash -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

    # Should succeed
    mysql -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -e "USE testdb; SELECT 1;" > /dev/null 2>&1 && echo "✅ Can access testdb"

    # Should fail
    mysql -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -e "USE mysql; SELECT 1;" 2>&1 | grep -q "Access denied" && echo "✅ Cannot access mysql (as expected)"
' || {
    echo "❌ Test 2 FAILED"
    exit 1
}

echo ""
echo "✅ Test 2 PASSED: Permission restrictions work correctly"
echo ""

# Summary
echo "=========================================="
echo "✅ All Tests PASSED!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  ✅ Basic authentication (namespace/serviceaccount)"
echo "  ✅ Permission restrictions enforced"
echo ""
echo "TokenReview authentication is working correctly!"
