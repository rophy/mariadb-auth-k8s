.PHONY: init build clean kind deploy test destroy help

# Default target
.DEFAULT_GOAL := help

# MariaDB version for headers
MARIADB_VERSION := 10.6.22

# Download and package MariaDB server headers
init:
	@./scripts/download-headers.sh $(MARIADB_VERSION)

# Build the auth_k8s plugin
build:
	@./scripts/build.sh

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf build/
	@echo "Clean complete"

# Create kind cluster for testing
kind:
	@echo "=========================================="
	@echo "Setting up Kind Cluster"
	@echo "=========================================="
	@./scripts/setup-kind-clusters.sh

# Deploy to kind cluster
deploy: build
	@echo "=========================================="
	@echo "Deploying to Kind Cluster"
	@echo "=========================================="
	@echo ""
	@echo "Step 1: Ensuring kind cluster exists..."
	@./scripts/setup-kind-clusters.sh
	@echo ""
	@echo "Step 2: Deploying with skaffold..."
	@skaffold run
	@echo ""
	@echo "Deployment complete!"
	@echo ""
	@echo "Next: Run 'make test' to verify authentication"

# Run authentication tests
test:
	@echo "=========================================="
	@echo "Running Authentication Tests"
	@echo "=========================================="
	@./scripts/test.sh

# Destroy kind cluster and all deployments
destroy:
	@echo "=========================================="
	@echo "Destroying Kind Cluster"
	@echo "=========================================="
	@echo ""
	@echo "Deleting kind cluster..."
	@kind delete cluster --name cluster-a 2>/dev/null || echo "Cluster-a already deleted"
	@echo ""
	@echo "Destroy complete!"

# Show help
help:
	@echo "MariaDB K8s Auth Plugin"
	@echo ""
	@echo "Build targets:"
	@echo "  make init    - Download and package MariaDB server headers"
	@echo "  make build   - Build auth_k8s plugin"
	@echo "  make clean   - Clean build artifacts"
	@echo ""
	@echo "Development environment:"
	@echo "  make kind    - Create kind cluster (cluster-a)"
	@echo "  make deploy  - Build plugin, setup cluster, deploy everything"
	@echo "  make test    - Run authentication tests"
	@echo "  make destroy - Destroy everything (deployments + cluster)"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make kind    - Create cluster (one-time setup)"
	@echo "  2. make deploy  - Deploy MariaDB and test clients"
	@echo "  3. make test    - Run authentication tests"
	@echo "  4. make destroy - Destroy cluster when done"
	@echo ""
	@echo "Quick start:"
	@echo "  make deploy && make test"
