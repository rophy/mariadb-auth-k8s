.PHONY: init build clean kind deploy test destroy help

# Default target
.DEFAULT_GOAL := help

# MariaDB version for headers
MARIADB_VERSION := 10.6.22

# Download and package MariaDB server headers
init:
	@./scripts/download-headers.sh $(MARIADB_VERSION)

# Build the unified plugin (AUTH API + JWKS fallback)
build:
	@./scripts/build.sh

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
deploy: build
	@echo "=========================================="
	@echo "Deploying to Multi-Cluster Environment"
	@echo "=========================================="
	@echo ""
	@echo "Step 1: Ensuring kind clusters exist..."
	@./scripts/setup-kind-clusters.sh
	@echo ""
	@echo "Step 2: Deploying with skaffold..."
	@skaffold run
	@echo ""
	@echo "Step 3: Configuring multi-cluster authentication..."
	@./scripts/setup-multicluster.sh
	@echo ""
	@echo "Deployment complete!"
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
	@echo "Destroy complete!"

# Show help
help:
	@echo "MariaDB K8s Auth Plugin - Multi-Cluster Testing"
	@echo ""
	@echo "Build targets:"
	@echo "  make init    - Download and package MariaDB server headers"
	@echo "  make build   - Build unified plugin (AUTH API + JWKS fallback)"
	@echo "  make clean   - Clean build artifacts"
	@echo ""
	@echo "Multi-cluster environment:"
	@echo "  make kind    - Create two kind clusters (cluster-a, cluster-b)"
	@echo "  make deploy  - Build plugin, setup clusters, deploy everything"
	@echo "  make test    - Run multi-cluster authentication tests"
	@echo "  make destroy - Destroy everything (deployments + clusters)"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make kind    - Create clusters (one-time setup)"
	@echo "  2. make deploy  - Deploy MariaDB, kube-federated-auth, test clients"
	@echo "  3. make test    - Run authentication tests"
	@echo "  4. make destroy - Destroy clusters when done"
	@echo ""
	@echo "Quick start:"
	@echo "  make deploy && make test"
	@echo ""
	@echo "Note: The unified plugin uses:"
	@echo "  - AUTH API (kube-federated-auth) for multi-cluster validation"
	@echo "  - JWKS fallback for local cluster when AUTH API unavailable"
