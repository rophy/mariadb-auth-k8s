.PHONY: init build build-server clean test dev install deploy dev-k8s undeploy help

# MariaDB version for headers
MARIADB_VERSION := 10.6.22

# Download and package MariaDB server headers
init:
	@echo "Downloading MariaDB server headers..."
	@./scripts/download-headers.sh $(MARIADB_VERSION)

# Build the plugin (compiles inside Docker image and extracts to ./build)
build:
	@echo "Building MariaDB K8s Auth Plugin Docker image..."
	docker build -t mariadb-auth-k8s:latest .
	@echo "✓ Plugin compiled inside Docker image"
	@echo "Extracting plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:latest) && \
		docker cp $$CONTAINER_ID:/workspace/build/auth_k8s.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin extracted to ./build/auth_k8s.so"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf build/
	@echo "Clean complete"

# Test authentication in Kubernetes
test:
	@./scripts/test-auth.sh

# Build and deploy to Kubernetes
deploy: build
	@echo "Building and deploying to Kubernetes..."
	skaffold run

# Clean up Kubernetes deployment
undeploy:
	@echo "Removing Kubernetes deployment..."
	skaffold delete

# Show help
help:
	@echo "MariaDB K8s Auth Plugin - Makefile targets:"
	@echo ""
	@echo "  make init         - Download and package MariaDB server headers"
	@echo "  make build        - Build Docker image and extract plugin to ./build/"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make test         - Run K8s ServiceAccount authentication tests"
	@echo "  make deploy       - Build and deploy to Kubernetes"
	@echo "  make undeploy     - Remove Kubernetes deployment"
	@echo "  make help         - Show this help message"
