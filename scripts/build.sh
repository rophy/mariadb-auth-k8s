#!/bin/bash
set -e

# Build MariaDB K8s Auth Plugin
# Usage: ./scripts/build.sh [version] [mariadb_version]
#
# If no version provided, derives from git describe.
# mariadb_version defaults to 10.6.22.

cd "$(dirname "$0")/.."

# Get version from argument or git
if [ -n "$1" ]; then
    VERSION="$1"
else
    VERSION=$(git describe --tags --always 2>/dev/null || echo "0.0")
fi

MARIADB_VERSION="${2:-10.6.22}"

echo "Building MariaDB K8s Auth Plugin v${VERSION} (MariaDB ${MARIADB_VERSION})..."

# Build Docker image
docker build --build-arg VERSION="${VERSION}" \
    --build-arg MARIADB_VERSION="${MARIADB_VERSION}" \
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
