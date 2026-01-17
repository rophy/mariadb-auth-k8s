#!/bin/sh

echo "MariaDB K8s Auth Plugin - Distribution Image"
echo ""
echo "Plugin: auth_k8s.so"
echo "  Authenticates using Kubernetes TokenReview API"
echo ""
echo "Usage:"
echo "  Copy /mariadb/auth_k8s.so to your MariaDB plugin directory"
echo ""
echo "Example:"
echo "  docker cp container:/mariadb/auth_k8s.so /usr/lib/mysql/plugin/"
echo ""
