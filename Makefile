.PHONY: init build clean kind deploy e2e-test unit-test test-legacy install-bats destroy help

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
	@echo "Next: Run 'make e2e-test' to verify authentication"

# Run unit tests (no cluster needed)
unit-test:
	@docker build --target test -t mariadb-auth-k8s:test .

# Run E2E authentication tests (BATS, needs deployed cluster)
e2e-test:
	@bats test/e2e/

# Run legacy authentication tests
test-legacy:
	@echo "=========================================="
	@echo "Running Authentication Tests (legacy)"
	@echo "=========================================="
	@./scripts/test.sh

# Install BATS test framework
install-bats:
	@echo "Installing bats-core..."
	@command -v bats >/dev/null 2>&1 && echo "bats is already installed" || { \
		git clone https://github.com/bats-core/bats-core.git /tmp/bats-core && \
		cd /tmp/bats-core && sudo ./install.sh /usr/local && \
		rm -rf /tmp/bats-core && \
		echo "bats installed successfully"; \
	}

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
	@echo "  make unit-test    - Run unit tests (no cluster needed)"
	@echo "  make e2e-test     - Run E2E authentication tests (BATS)"
	@echo "  make test-legacy  - Run legacy test script"
	@echo "  make install-bats - Install BATS test framework"
	@echo "  make destroy      - Destroy everything (deployments + cluster)"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make kind    - Create cluster (one-time setup)"
	@echo "  2. make deploy  - Deploy MariaDB and test clients"
	@echo "  3. make e2e-test - Run authentication tests"
	@echo "  4. make destroy  - Destroy cluster when done"
	@echo ""
	@echo "Quick start:"
	@echo "  make deploy && make e2e-test"
