FROM debian:bookworm AS builder

# Build arguments
ARG VERSION=dev

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    libmariadb-dev \
    libcurl4-openssl-dev \
    libjson-c-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy and extract MariaDB headers to /opt
COPY include/mariadb-*-headers.tar.gz /tmp/mariadb-headers.tar.gz
RUN tar -xzf /tmp/mariadb-headers.tar.gz -C /opt && \
    rm /tmp/mariadb-headers.tar.gz

# Set working directory
WORKDIR /workspace

# Copy source files
COPY src/ /workspace/src/
COPY CMakeLists.txt /workspace/
COPY include/build-all-plugins.sh /workspace/
COPY include/generate-version.sh /workspace/

# Generate version.h
RUN chmod +x generate-version.sh && \
    ./generate-version.sh "${VERSION}" src/version.h

# Build all three plugin variants
RUN chmod +x build-all-plugins.sh && ./build-all-plugins.sh

# Distribute the plugin with a minimal image.
FROM busybox

COPY --from=builder /output/*.so /mariadb/
COPY include/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
