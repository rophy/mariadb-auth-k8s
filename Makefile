.PHONY: init build clean kind deploy e2e-test unit-test test-legacy install-bats destroy release help

.DEFAULT_GOAL := help

MARIADB_VERSION := 10.6.27
export MARIADB_VERSION

init: ## Download MariaDB server headers
	@./scripts/download-headers.sh $(MARIADB_VERSION)

build: ## Build auth_k8s plugin
	@./scripts/build.sh "" $(MARIADB_VERSION)

clean: ## Clean build artifacts
	@echo "Cleaning build artifacts..."
	rm -rf build/
	@echo "Clean complete"

kind: ## Create Kind cluster (cluster-a)
	@./scripts/setup-kind-clusters.sh

deploy: build ## Build plugin, setup cluster, deploy everything
	@echo "Step 1: Ensuring kind cluster exists..."
	@./scripts/setup-kind-clusters.sh
	@echo ""
	@echo "Step 2: Building images with skaffold..."
	@skaffold build --file-output=/tmp/skaffold-build.json
	@echo ""
	@echo "Step 3: Loading images into Kind and deploying resources..."
	@./scripts/deploy-to-kind.sh
	@echo ""
	@echo "Deployment complete! Run 'make e2e-test' to verify."

unit-test: ## Run unit tests (no cluster needed)
	@docker build --build-arg MARIADB_VERSION=$(MARIADB_VERSION) --target test -t mariadb-auth-k8s:test .

e2e-test: ## Run E2E authentication tests (needs deployed cluster)
	@bats test/e2e/

test-legacy: ## Run legacy test script
	@./scripts/test.sh

install-bats: ## Install BATS test framework
	@command -v bats >/dev/null 2>&1 && echo "bats is already installed" || { \
		git clone https://github.com/bats-core/bats-core.git /tmp/bats-core && \
		cd /tmp/bats-core && sudo ./install.sh /usr/local && \
		rm -rf /tmp/bats-core && \
		echo "bats installed successfully"; \
	}

release: ## Build source release tarball (VERSION=1.0)
	@if [ -z "$(VERSION)" ]; then \
		VERSION=$$(git describe --tags --always 2>/dev/null || echo "0.0"); \
	else \
		VERSION="$(VERSION)"; \
	fi; \
	PREFIX="mariadb-auth-k8s-$$VERSION"; \
	echo "Building release tarball: $$PREFIX.tar.gz"; \
	./include/generate-version.sh "$$VERSION" src/version.h; \
	mkdir -p dist; \
	tar czf "dist/$$PREFIX.tar.gz" \
		--transform "s,^,$$PREFIX/," \
		src/ \
		CMakeLists.txt \
		LICENSE \
		README.md; \
	echo "Release tarball: dist/$$PREFIX.tar.gz"

destroy: ## Destroy Kind cluster and all deployments
	@kind delete cluster --name cluster-a 2>/dev/null || echo "Cluster-a already deleted"

help: ## Show this help
	@echo "MariaDB K8s Auth Plugin (MARIADB_VERSION=$(MARIADB_VERSION))"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | awk -F '\t' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:  make deploy && make e2e-test"
	@echo "Multi-version: make build MARIADB_VERSION=11.4.12"
