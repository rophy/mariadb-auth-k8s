.PHONY: init build build-api build-jwt build-tokenreview clean kind deploy test destroy help

# MariaDB version for headers
MARIADB_VERSION := 10.6.22

# Download and package MariaDB server headers
init:
	@echo "Downloading MariaDB server headers..."
	@./scripts/download-headers.sh $(MARIADB_VERSION)

# Build the plugin (compiles inside Docker image and extracts to ./build)
# Default: JWT validation
build:
	@echo "Building MariaDB K8s Auth Plugin Docker image (JWT validation)..."
	docker build -t mariadb-auth-k8s:latest .
	@echo "✓ Plugin compiled inside Docker image"
	@echo "Extracting plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:latest) && \
		docker cp $$CONTAINER_ID:/workspace/build/auth_k8s.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin extracted to ./build/auth_k8s.so"

# Build with Token Validator API (production, multi-cluster)
build-api:
	@echo "Building MariaDB K8s Auth Plugin Docker image (Token Validator API)..."
	docker build --build-arg CMAKE_OPTS="-DUSE_TOKEN_VALIDATOR_API=ON" -t mariadb-auth-k8s:api .
	@echo "✓ Plugin compiled inside Docker image"
	@echo "Extracting plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:api) && \
		docker cp $$CONTAINER_ID:/workspace/build/auth_k8s.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin extracted to ./build/auth_k8s.so"

# Build with JWT validation (default)
build-jwt:
	@echo "Building MariaDB K8s Auth Plugin Docker image (JWT validation)..."
	docker build --build-arg CMAKE_OPTS="-DUSE_JWT_VALIDATION=ON" -t mariadb-auth-k8s:jwt .
	@echo "✓ Plugin compiled inside Docker image"
	@echo "Extracting plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:jwt) && \
		docker cp $$CONTAINER_ID:/workspace/build/auth_k8s.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin extracted to ./build/auth_k8s.so"

# Build with TokenReview API
build-tokenreview:
	@echo "Building MariaDB K8s Auth Plugin Docker image (TokenReview API)..."
	docker build --build-arg CMAKE_OPTS="" -t mariadb-auth-k8s:tokenreview .
	@echo "✓ Plugin compiled inside Docker image"
	@echo "Extracting plugin to ./build/..."
	@mkdir -p build
	@CONTAINER_ID=$$(docker create mariadb-auth-k8s:tokenreview) && \
		docker cp $$CONTAINER_ID:/workspace/build/auth_k8s.so ./build/auth_k8s.so && \
		docker rm $$CONTAINER_ID > /dev/null
	@echo "✓ Plugin extracted to ./build/auth_k8s.so"

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
	@echo "Step 2: Building and deploying to cluster-a..."
	@kubectl config use-context kind-cluster-a
	@skaffold run --kube-context kind-cluster-a
	@echo ""
	@echo "Step 3: Deploying test client to cluster-b..."
	@kubectl config use-context kind-cluster-b
	@kind load docker-image test-client:latest --name cluster-b
	@kubectl apply -f k8s/cluster-b/namespace.yaml
	@kubectl apply -f k8s/cluster-b/test-client-remote.yaml
	@echo "Waiting for remote-client to be ready..."
	@kubectl wait --for=condition=ready pod -l app=remote-client -n remote-test --timeout=120s || echo "⚠️  Timeout waiting for remote-client"
	@echo ""
	@echo "Step 4: Configuring multi-cluster authentication..."
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
	@echo "Removing deployments from cluster-a..."
	@kubectl config use-context kind-cluster-a 2>/dev/null && skaffold delete || echo "Cluster-a not found or already cleaned"
	@echo ""
	@echo "Removing deployments from cluster-b..."
	@kubectl config use-context kind-cluster-b 2>/dev/null && kubectl delete namespace remote-test --ignore-not-found || echo "Cluster-b not found or already cleaned"
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
	@echo "  make build             - Build plugin (JWT validation, default)"
	@echo "  make build-api         - Build plugin with Token Validator API (production)"
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
	@echo "  - cluster-a: MariaDB + Token Validator API"
	@echo "  - cluster-b: Remote test client"
