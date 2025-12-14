# Development Guide for Claude

## Quick Commands

```bash
# Clean build artifacts
make clean

# Build unified plugin (AUTH API + JWKS fallback)
make build

# Deploy to local Kind clusters
make deploy

# Run tests
make test

# Destroy clusters when done
make destroy
```

## Local Development Setup

The project uses two Kind clusters for multi-cluster testing:
- **cluster-a**: Runs MariaDB + kube-federated-auth service
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
  auth_k8s.c                      # Unified plugin (AUTH API + JWKS fallback)
  jwt_crypto.c/h                  # JWT cryptographic operations
  tokenreview_api.c/h             # TokenReview API client (kept for future use)
  auth_k8s_tokenreview.c          # TokenReview-only plugin (kept for future use)

k8s/
  cluster-a/                      # MariaDB cluster manifests
    mariadb-nodeport.yaml         # MariaDB deployment + NodePort
    kube-federated-auth-*.yaml    # Token validator service
    test-clients.yaml             # Local test clients
  cluster-b/                      # Remote cluster manifests
    test-client-remote.yaml       # Remote test client

scripts/
  setup-kind-clusters.sh          # Create Kind clusters
  setup-multicluster.sh           # Configure cross-cluster auth
  test.sh                         # Run authentication tests
  download-headers.sh             # Download MariaDB headers
```

## Unified Plugin Validation Flow

The unified plugin validates tokens with automatic fallback:

1. **AUTH API** (if `KUBE_FEDERATED_AUTH_URL` is set)
   - Supports multi-cluster validation via kube-federated-auth
   - Full revocation support (uses TokenReview internally)

2. **JWKS fallback** (for local cluster only)
   - Falls back when AUTH API is unavailable
   - Cross-cluster requests fail without AUTH API

Username format: `cluster/namespace/serviceaccount`
- 3-part: `cluster-b/default/myapp` (cross-cluster)
- 3-part with "local": `local/default/myapp` (local cluster)
- 2-part: `default/myapp` (local cluster, implicit)

## Testing the kube-federated-auth Service

```bash
# Check logs
kubectl logs -n mariadb-auth-test -l app=kube-federated-auth --tail=20 --context kind-cluster-a

# Health check
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  curl -s http://kube-federated-auth:8080/health

# List configured clusters
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  curl -s http://kube-federated-auth:8080/clusters

# Validate a token
TOKEN=$(kubectl create token user1 --context kind-cluster-a -n mariadb-auth-test --duration=1h)
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  curl -s -X POST http://kube-federated-auth:8080/validate \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"$TOKEN\", \"cluster\": \"local\"}"
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

## Git Commit Convention

```
<type>: <short description>

[optional body]
```

Types: feat, fix, refactor, chore, docs, build, test

No "Generated with Claude" footer or Co-Authored-By lines.
