#!/bin/bash
set -e

# Convert M.N version to MariaDB plugin hex format
# Usage: ./generate-version.sh 1.0
# Output: Generates version.h with PLUGIN_VERSION 0x0100

if [ -z "$1" ]; then
    echo "Error: Version required (M.N format)"
    echo "Usage: $0 <version>"
    echo "Example: $0 1.0"
    exit 1
fi

VERSION="$1"
OUTPUT="${2:-version.h}"

# Validate M.N format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+$'; then
    echo "Error: Version must be in M.N format (e.g., 1.0)"
    exit 1
fi

# Extract major and minor version
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)

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

echo "Generated $OUTPUT with version $VERSION (hex: $HEX_VERSION)"
