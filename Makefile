.PHONY: init build build-api build-jwt build-tokenreview clean kind deploy test destroy help

# Default target
.DEFAULT_GOAL := help

# Plugin version (M.N format)
VERSION := 1.0

# MariaDB version for headers
MARIADB_VERSION := 10.6.22

# Download and package MariaDB server headers
init:
	@echo "Downloading MariaDB server headers..."
	@./scripts/download-headers.sh $(MARIADB_VERSION)

# Build the plugin (compiles all variants inside Docker image and extracts federated_api)
# Default: Feoderated Auth API (production, multi-cluster)
build:
	@echo "Building MariaDB K8s Auth Plugin Docker image v$(VERSION) (all variants)..."
	docker build --build-arg VERSION=$(VERSION) -t mariadb-auth-k8s:$(VERSION) -t mariadb-auth-k8s:latest .
	@echo "Extracting Feoderated Auth API plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:latest) && \
		docker cp $$CONTAINER_ID:/mariadb/auth_k8s_federated_api.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin v$(VERSION) extracted to ./build/auth_k8s.so (Feoderated Auth API variant)"

# Extract Feoderated Auth API variant
build-api: build

# Extract JWT validation variant
build-jwt:
	@echo "Building MariaDB K8s Auth Plugin Docker image v$(VERSION) (all variants)..."
	docker build --build-arg VERSION=$(VERSION) -t mariadb-auth-k8s:$(VERSION) -t mariadb-auth-k8s:latest .
	@echo "✓ All plugin variants compiled inside Docker image"
	@echo "Extracting JWT plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:latest) && \
		docker cp $$CONTAINER_ID:/mariadb/auth_k8s_jwt.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin v$(VERSION) extracted to ./build/auth_k8s.so (JWT variant)"

# Extract TokenReview API variant
build-tokenreview:
	@echo "Building MariaDB K8s Auth Plugin Docker image v$(VERSION) (all variants)..."
	docker build --build-arg VERSION=$(VERSION) -t mariadb-auth-k8s:$(VERSION) -t mariadb-auth-k8s:latest .
	@echo "✓ All plugin variants compiled inside Docker image"
	@echo "Extracting TokenReview plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:latest) && \
		docker cp $$CONTAINER_ID:/mariadb/auth_k8s_tokenreview.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin v$(VERSION) extracted to ./build/auth_k8s.so (TokenReview variant)"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf build/
	@echo "Clean complete"

# Create kind clusters for multi-cluster testing
kind:
	@echo "=========================================="
	@echo "Setting up Kind Clusters"
	@echo "=========================================="
	@./scripts/setup-kind-clusters.sh

# Deploy to multi-cluster environment
deploy:
	@echo "=========================================="
	@echo "Deploying to Multi-Cluster Environment"
	@echo "=========================================="
	@echo ""
	@echo "Step 1: Ensuring kind clusters exist..."
	@./scripts/setup-kind-clusters.sh
	@echo ""
	@echo "Step 2: Building and deploying with skaffold..."
	@skaffold run
	@echo ""
	@echo "Step 3: Configuring multi-cluster authentication..."
	@./scripts/setup-multicluster.sh
	@echo ""
	@echo "✅ Deployment complete!"
	@echo ""
	@echo "Next: Run 'make test' to verify authentication"

# Run multi-cluster authentication tests
test:
	@echo "=========================================="
	@echo "Running Multi-Cluster Authentication Tests"
	@echo "=========================================="
	@./scripts/test.sh

# Destroy kind clusters and all deployments
destroy:
	@echo "=========================================="
	@echo "Destroying Multi-Cluster Environment"
	@echo "=========================================="
	@echo ""
	@echo "Deleting kind clusters..."
	@kind delete cluster --name cluster-a 2>/dev/null || echo "Cluster-a already deleted"
	@kind delete cluster --name cluster-b 2>/dev/null || echo "Cluster-b already deleted"
	@echo ""
	@echo "✅ Destroy complete!"

# Show help
help:
	@echo "MariaDB K8s Auth Plugin - Multi-Cluster Testing"
	@echo ""
	@echo "Build targets:"
	@echo "  make init              - Download and package MariaDB server headers"
	@echo "  make build             - Build plugin (Feoderated Auth API, default)"
	@echo "  make build-api         - Alias for 'make build'"
	@echo "  make build-jwt         - Build plugin with JWT validation"
	@echo "  make build-tokenreview - Build plugin with TokenReview API"
	@echo "  make clean             - Clean build artifacts"
	@echo ""
	@echo "Multi-cluster environment:"
	@echo "  make kind              - Create two kind clusters (cluster-a, cluster-b)"
	@echo "  make deploy            - Setup clusters and deploy everything"
	@echo "  make test              - Run multi-cluster authentication tests"
	@echo "  make destroy           - Destroy everything (deployments + clusters)"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make kind           - Create clusters (one-time setup)"
	@echo "  2. make deploy         - Deploy MariaDB, Token Validator, test clients"
	@echo "  3. make test           - Run authentication tests"
	@echo "  4. make destroy        - Destroy clusters when done"
	@echo ""
	@echo "Quick start:"
	@echo "  make deploy && make test"
	@echo ""
	@echo "Note: The default setup uses multi-cluster architecture with:"
	@echo "  - cluster-a: MariaDB + Feoderated Auth API"
	@echo "  - cluster-b: Remote test client"
