FROM debian:bookworm

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
    cmake .. && \
    make && \
    echo 'Build complete! Artifacts:' && \
    ls -lh *.so

# Default command
CMD ["/bin/bash"]
