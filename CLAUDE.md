# Development Guide for Claude

## Quick Commands

```bash
# Clean build artifacts
make clean

# Build plugin (Token Validator API - default, production)
make build

# Build with JWT validation
make build-jwt

# Build with TokenReview API
make build-tokenreview

# Deploy to local Kind clusters
make deploy

# Run tests
make test

# Destroy clusters when done
make destroy
```

## Local Development Setup

The project uses two Kind clusters for multi-cluster testing:
- **cluster-a**: Runs MariaDB + Federated K8s Auth service
- **cluster-b**: Remote cluster with test client

```bash
# Setup Kind clusters (if not exists)
make kind

# Deploy everything (builds images, deploys to both clusters)
make deploy

# Run authentication tests
make test
```

## Project Structure

```
src/                              # MariaDB authentication plugin (C)
  auth_k8s_validator_api.c        # Token Validator API client (production)
  auth_k8s_jwt.c                  # JWT validation with OIDC
  auth_k8s_tokenreview.c          # TokenReview API validation
  jwt_crypto.c/h                  # JWT cryptographic operations
  tokenreview_api.c/h             # TokenReview API client

federated-k8s-auth/               # Token validation service (Node.js)
  src/
    index.js                      # Entry point
    server.js                     # Express HTTP server
    validator.js                  # Token validation logic
    cluster-config.js             # Multi-cluster configuration
    jwks-cache.js                 # JWKS key caching
    oidc-discovery.js             # OIDC discovery client
  test/
    validator.test.js             # Unit tests

k8s/
  cluster-a/                      # MariaDB cluster manifests
    mariadb-nodeport.yaml         # MariaDB deployment + NodePort
    federated-k8s-auth-*.yaml     # Token validator service
    test-clients.yaml             # Local test clients
  cluster-b/                      # Remote cluster manifests
    test-client-remote.yaml       # Remote test client

scripts/
  setup-kind-clusters.sh          # Create Kind clusters
  setup-multicluster.sh           # Configure cross-cluster auth
  test.sh                         # Run authentication tests
  download-headers.sh             # Download MariaDB headers
```

## Build Targets

| Target | Description |
|--------|-------------|
| `make build` | Token Validator API (default, production, multi-cluster) |
| `make build-jwt` | JWT validation with OIDC discovery |
| `make build-tokenreview` | TokenReview API validation |

The built plugin is extracted to `./build/auth_k8s.so`.

## Testing the Federated K8s Auth Service

```bash
# Check logs
kubectl logs -n mariadb-auth-test -l app=federated-k8s-auth --tail=20 --context kind-cluster-a

# Health check
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  curl -s http://federated-k8s-auth:8080/health

# List configured clusters
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  curl -s http://federated-k8s-auth:8080/clusters

# Validate a token
TOKEN=$(kubectl create token user1 --context kind-cluster-a -n mariadb-auth-test --duration=1h)
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  curl -s -X POST http://federated-k8s-auth:8080/validate \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"$TOKEN\"}"
```

## Testing MariaDB Authentication

```bash
# Test local cluster authentication
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  mysql -h mariadb -u 'local/mariadb-auth-test/user1' -p"$(kubectl create token user1 -n mariadb-auth-test --context kind-cluster-a)" \
  -e "SELECT USER(), CURRENT_USER()"

# Test cross-cluster authentication (from cluster-b to cluster-a)
TOKEN=$(kubectl create token remote-user --context kind-cluster-b -n remote-test --duration=1h)
kubectl exec -n remote-test deploy/remote-client --context kind-cluster-b -- \
  mysql -h 192.168.128.2 -P 30306 -u 'cluster-b/remote-test/remote-user' -p"$TOKEN" \
  -e "SHOW DATABASES"
```

## Running Unit Tests (Federated K8s Auth)

```bash
cd federated-k8s-auth
npm install
npm test
```

## Git Commit Convention

```
<type>: <short description>

[optional body]
```

Types: feat, fix, refactor, chore, docs, build, test

No "Generated with Claude" footer or Co-Authored-By lines.
>>>>>>> f2ed779 (doc: CLAUDE.md)
