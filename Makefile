.PHONY: init build build-api build-jwt build-tokenreview clean test deploy undeploy help

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

# Test authentication in Kubernetes (run after skaffold run)
test:
	@echo "Waiting for Token Validator API to be ready..."
	@kubectl wait --for=condition=ready pod -l app=token-validator-api -n mariadb-auth-test --timeout=120s
	@echo "Waiting for MariaDB to be ready..."
	@kubectl wait --for=condition=ready pod -l app=mariadb -n mariadb-auth-test --timeout=120s
	@echo "Waiting for test clients to be ready..."
	@kubectl wait --for=condition=ready pod -l app=client-user1 -n mariadb-auth-test --timeout=60s
	@kubectl wait --for=condition=ready pod -l app=client-user2 -n mariadb-auth-test --timeout=60s
	@echo ""
	@echo "Running integration tests..."
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
	@echo "  make init              - Download and package MariaDB server headers"
	@echo "  make build             - Build plugin (JWT validation, default)"
	@echo "  make build-api         - Build plugin with Token Validator API (production)"
	@echo "  make build-jwt         - Build plugin with JWT validation"
	@echo "  make build-tokenreview - Build plugin with TokenReview API"
	@echo "  make clean             - Clean build artifacts"
	@echo "  make deploy            - Build and deploy to Kubernetes (skaffold run)"
	@echo "  make test              - Run integration tests (after skaffold run)"
	@echo "  make undeploy          - Remove Kubernetes deployment"
	@echo "  make help              - Show this help message"
	@echo ""
	@echo "Integration test workflow:"
	@echo "  1. skaffold run        - Build images and deploy everything"
	@echo "  2. make test           - Wait for pods and run tests"
