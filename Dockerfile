FROM debian:bookworm AS builder

# Build arguments
ARG CMAKE_OPTS="-DUSE_JWT_VALIDATION=ON"

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

# Build the plugin
RUN mkdir -p build && \
    cd build && \
    cmake ${CMAKE_OPTS} .. && \
    make && \
    echo 'Build complete! Artifacts:' && \
    ls -lh *.so

# Distribute the plugin with a minimal image.
FROM busybox

COPY --from=builder /workspace/build/auth_k8s.so /mariadb/auth_k8s.so

# Create an entrypoint to hint user that this is a distribution-only image.
RUN echo -e '#!/bin/sh\n\necho "This image is intended for distributing the auth_k8s.so plugin only."\necho "Please copy /mariadb/auth_k8s.so to your MariaDB plugin directory."' > /entrypoint.sh && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
