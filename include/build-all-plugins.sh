#!/bin/bash
set -e

# Build all three plugin variants

OUTPUT_DIR="/output"
mkdir -p "$OUTPUT_DIR"

echo "Building all MariaDB K8s Auth plugin variants..."
echo ""

# Build Token Validator API (Federated) version
echo "==> Building Token Validator API (Federated) version..."
mkdir -p build-api && cd build-api
cmake -DUSE_TOKEN_VALIDATOR_API=ON ..
make
mv auth_k8s.so "$OUTPUT_DIR/auth_k8s_federated_api.so"
cd .. && rm -rf build-api
echo "    ✓ auth_k8s_federated_api.so"
echo ""

# Build JWT version
echo "==> Building JWT version..."
mkdir -p build-jwt && cd build-jwt
cmake -DUSE_JWT_VALIDATION=ON ..
make
mv auth_k8s.so "$OUTPUT_DIR/auth_k8s_jwt.so"
cd .. && rm -rf build-jwt
echo "    ✓ auth_k8s_jwt.so"
echo ""

# Build TokenReview version
echo "==> Building TokenReview version..."
mkdir -p build-tokenreview && cd build-tokenreview
cmake ..
make
mv auth_k8s.so "$OUTPUT_DIR/auth_k8s_tokenreview.so"
cd .. && rm -rf build-tokenreview
echo "    ✓ auth_k8s_tokenreview.so"
echo ""

# Show all built plugins
echo "Build complete! All plugin variants:"
ls -lh "$OUTPUT_DIR"/*.so
