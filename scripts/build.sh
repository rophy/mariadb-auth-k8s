#!/bin/bash
set -e

# Build MariaDB K8s Auth Plugin
# Usage: ./scripts/build.sh [version]
#
# If no version provided, derives from git describe.

cd "$(dirname "$0")/.."

# Get version from argument or git
if [ -n "$1" ]; then
    VERSION="$1"
else
    VERSION=$(git describe --tags --always 2>/dev/null || echo "0.0")
fi

echo "Building MariaDB K8s Auth Plugin v${VERSION}..."

# Build Docker image
docker build --build-arg VERSION="${VERSION}" \
    -t mariadb-auth-k8s:"${VERSION}" \
    -t mariadb-auth-k8s:latest \
    .

# Extract plugin to ./build/
echo "Extracting plugin to ./build/..."
mkdir -p build
CONTAINER_ID=$(docker create mariadb-auth-k8s:latest)
docker cp "${CONTAINER_ID}":/mariadb/auth_k8s.so ./build/auth_k8s.so
docker rm "${CONTAINER_ID}" > /dev/null

echo "Plugin v${VERSION} extracted to ./build/auth_k8s.so"
