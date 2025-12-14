#!/bin/bash
set -e

# Generate version.h from git describe or explicit version
# Usage: ./generate-version.sh [version]
#
# If no version provided, derives from git describe.
# Expected tag format: M.N (e.g., 1.0, 2.0)
# Git describe output: M.N or M.N-commits-ghash (e.g., 1.0-5-gabcdef)
#
# Plugin version uses M.N (hex 0xMMNN)
# Full version string preserved for display

OUTPUT="${2:-version.h}"

# Get version from argument or git
if [ -n "$1" ]; then
    VERSION="$1"
else
    VERSION=$(git describe --tags --always 2>/dev/null || echo "0.0")
fi

# Extract version number using multiple patterns
# Pattern 1: M.N or M.N.P at start (with optional v prefix)
# Pattern 2: M.N or M.N.P after a dash (prefix-M.N.P)
# Pattern 3: M.N followed by -commits-ghash

SEMVER=""

# Try to extract M.N.P or M.N from the version string
# First, try extracting from formats like "prefix-1.0.0-5-gabcdef" or "1.0.0-5-gabcdef"
if echo "$VERSION" | grep -qE '(^|-)v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9]+-g[a-f0-9]+)?$'; then
    # Extract the version part (handles prefix-M.N.P and M.N.P formats)
    SEMVER=$(echo "$VERSION" | grep -oE '(^|-)v?[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1 | sed 's/^-//' | sed 's/^v//')
fi

# If still empty, try simpler M.N pattern
if [ -z "$SEMVER" ] || ! echo "$SEMVER" | grep -qE '^[0-9]+\.[0-9]+'; then
    SEMVER=$(echo "$VERSION" | grep -oE '^v?[0-9]+\.[0-9]+' | sed 's/^v//')
fi

# Extract major and minor (ignore patch for plugin hex version)
if [ -n "$SEMVER" ]; then
    MAJOR=$(echo "$SEMVER" | cut -d. -f1)
    MINOR=$(echo "$SEMVER" | cut -d. -f2)
else
    MAJOR=""
    MINOR=""
fi

# Validate we got numbers
if ! [[ "$MAJOR" =~ ^[0-9]+$ ]] || ! [[ "$MINOR" =~ ^[0-9]+$ ]]; then
    echo "Warning: Could not parse version from '$VERSION', defaulting to 0.0"
    MAJOR=0
    MINOR=0
fi

# Convert to hex (format: 0xMMNN)
HEX_VERSION=$(printf "0x%02x%02x" "$MAJOR" "$MINOR")

# Generate version.h
cat > "$OUTPUT" <<EOF
/* Auto-generated version header */
#ifndef PLUGIN_VERSION_H
#define PLUGIN_VERSION_H

#define PLUGIN_VERSION ${HEX_VERSION}
#define PLUGIN_VERSION_STRING "${VERSION}"

#endif /* PLUGIN_VERSION_H */
EOF

echo "Generated $OUTPUT: ${MAJOR}.${MINOR} (${HEX_VERSION}) from '${VERSION}'"
