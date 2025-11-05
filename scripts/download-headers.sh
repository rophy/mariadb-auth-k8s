#!/bin/bash
#
# Download MariaDB server headers and package them as a tarball
#
# Usage: ./scripts/download-headers.sh <version>
#   version: MariaDB version tag (required, e.g., 10.6.22)
#

set -e

# Check for required argument
if [ -z "$1" ]; then
    echo "Error: MariaDB version is required"
    echo "Usage: $0 <version>"
    echo "Example: $0 10.6.22"
    exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

# Configuration
MARIADB_VERSION="$1"
MARIADB_BRANCH="mariadb-${MARIADB_VERSION}"
OUTPUT_DIR="include"
OUTPUT_FILE="${OUTPUT_DIR}/mariadb-${MARIADB_VERSION}-headers.tar.gz"

echo "=========================================="
echo "MariaDB Headers Download Script"
echo "=========================================="
echo "Version: ${MARIADB_VERSION}"
echo "Output:  ${OUTPUT_FILE}"
echo "=========================================="
echo ""

# Check if output already exists
if [ -f "${OUTPUT_FILE}" ]; then
    echo "Error: ${OUTPUT_FILE} already exists"
    echo "Remove it first if you want to re-download"
    exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Download headers from MariaDB git repository
echo "Step 1/4: Cloning MariaDB repository (branch: ${MARIADB_BRANCH})..."
git clone --depth 1 --branch "${MARIADB_BRANCH}" \
    https://github.com/MariaDB/server.git "${TEMP_DIR}"

# Create include directory structure
echo "Step 2/4: Copying headers..."
mkdir -p include
cp -r "${TEMP_DIR}/include/"* include/

# Process mysql_version.h template if it exists
echo "Step 3/4: Processing version template..."
cd include
if [ -f mysql_version.h.in ]; then
    # Extract version components
    VERSION_MAJOR=$(echo "${MARIADB_VERSION}" | cut -d. -f1)
    VERSION_MINOR=$(echo "${MARIADB_VERSION}" | cut -d. -f2)
    VERSION_PATCH=$(echo "${MARIADB_VERSION}" | cut -d. -f3)

    sed "s/@MYSQL_VERSION_MAJOR@/${VERSION_MAJOR}/g; \
         s/@MYSQL_VERSION_MINOR@/${VERSION_MINOR}/g; \
         s/@MYSQL_VERSION_PATCH@/${VERSION_PATCH}/g; \
         s/@PROTOCOL_VERSION@/10/g; \
         s/@MARIADB_PACKAGE_VERSION@/\"${MARIADB_VERSION}\"/g; \
         s/@MARIADB_BASE_VERSION@/\"mariadb-${VERSION_MAJOR}.${VERSION_MINOR}\"/g; \
         s/@CMAKE_SYSTEM_NAME@/\"Linux\"/g; \
         s/@MACHINE_TYPE@/\"x86_64\"/g" \
        mysql_version.h.in > mysql_version.h
fi
cd ..

# Create tarball (in temp location to avoid self-reference issue)
echo "Step 4/4: Creating tarball..."
TEMP_TARBALL="${TEMP_DIR}/headers.tar.gz"
tar -czf "${TEMP_TARBALL}" include/

# Cleanup extracted headers
rm -rf include/

# Move tarball to final location
mkdir -p "${OUTPUT_DIR}"
mv "${TEMP_TARBALL}" "${OUTPUT_FILE}"

# Summary
TARBALL_SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)
echo ""
echo "=========================================="
echo "✓ Success!"
echo "=========================================="
echo "Tarball: ${OUTPUT_FILE}"
echo "Size:    ${TARBALL_SIZE}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Commit the tarball to git: git add ${OUTPUT_FILE}"
echo "2. Build the plugin: make build"
