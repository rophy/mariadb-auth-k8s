#!/bin/bash
# Test script to verify K8s ServiceAccount authentication
# Runs locally and uses kubectl exec to test authentication in pods

set -e

NAMESPACE="mariadb-auth-test"

echo "=========================================="
echo "K8s ServiceAccount Authentication Tests"
echo "=========================================="
echo ""

# Test User1 - Full Admin Access
echo "=========================================="
echo "Testing User1 - Full Admin Access"
echo "=========================================="
echo ""

kubectl exec -n $NAMESPACE deployment/client-user1 -- bash -c '
    echo "Waiting for MariaDB to be ready..."
    until mysqladmin ping -h mariadb -u root --silent 2>/dev/null; do
        sleep 2
    done
    echo "✅ MariaDB is ready!"
    echo ""

    echo "ServiceAccount token:"
    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        echo "✅ Token found"
        echo "Preview: $(head -c 50 /var/run/secrets/kubernetes.io/serviceaccount/token)..."
    else
        echo "❌ Token NOT found"
        exit 1
    fi
    echo ""

    echo "Authenticating as mariadb-auth-test/user1..."
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

    mysql -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "
        SELECT \"✅ Authentication successful!\" AS status;
        SELECT USER() AS user, CURRENT_USER() AS authenticated_as;
        SHOW DATABASES;
    "
'

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ User1 authentication SUCCESSFUL!"
else
    echo ""
    echo "❌ User1 authentication FAILED"
    exit 1
fi

echo ""
echo "=========================================="
echo "Testing User2 - Limited Access (testdb only)"
echo "=========================================="
echo ""

kubectl exec -n $NAMESPACE deployment/client-user2 -- bash -c '
    echo "Waiting for MariaDB to be ready..."
    until mysqladmin ping -h mariadb -u root --silent 2>/dev/null; do
        sleep 2
    done
    echo "✅ MariaDB is ready!"
    echo ""

    echo "ServiceAccount token:"
    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        echo "✅ Token found"
        echo "Preview: $(head -c 50 /var/run/secrets/kubernetes.io/serviceaccount/token)..."
    else
        echo "❌ Token NOT found"
        exit 1
    fi
    echo ""

    echo "Authenticating as mariadb-auth-test/user2..."
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

    mysql -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -e "
        SELECT \"✅ Authentication successful!\" AS status;
        SELECT USER() AS user, CURRENT_USER() AS authenticated_as;
        SHOW DATABASES;
    "
'

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ User2 authentication SUCCESSFUL!"
else
    echo ""
    echo "❌ User2 authentication FAILED"
    exit 1
fi

echo ""
echo "=========================================="
echo "Testing User2 access restrictions..."
echo "=========================================="
echo ""

kubectl exec -n $NAMESPACE deployment/client-user2 -- bash -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

    echo "Attempting to access mysql database (should FAIL)..."
    if mysql -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -e "USE mysql; SHOW TABLES;" 2>&1 | grep -q "Access denied"; then
        echo "✅ Access denied as expected - permissions are correctly restricted"
    else
        echo "❌ User2 should NOT have access to mysql database!"
        exit 1
    fi
'

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ User2 access restrictions verified!"
else
    echo ""
    echo "❌ User2 access restriction test FAILED"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ All tests PASSED!"
echo "=========================================="
