# Development Guide for Claude

## Quick Commands

```bash
# Clean build artifacts
make clean

# Build auth_k8s plugin
make build

# Deploy to local Kind cluster
make deploy

# Run tests
make test

# Destroy cluster when done
make destroy
```

## Local Development Setup

The project uses a Kind cluster for testing:
- **cluster-a**: Runs MariaDB with K8s auth plugin and test clients

```bash
# Setup Kind cluster (if not exists)
make kind

# Deploy everything (builds images, deploys to cluster)
make deploy

# Run authentication tests
make test
```

## Project Structure

```
src/                              # MariaDB authentication plugin (C)
  auth_k8s.c                      # Main plugin source
  tokenreview_api.c/h             # TokenReview API client

k8s/
  cluster-a/                      # Kubernetes manifests
    mariadb-nodeport.yaml         # MariaDB deployment + NodePort
    test-clients.yaml             # Test clients

scripts/
  setup-kind-clusters.sh          # Create Kind cluster
  test.sh                         # Run authentication tests
  download-headers.sh             # Download MariaDB headers
```

## Authentication Flow

The plugin validates tokens using the Kubernetes TokenReview API:

1. Client connects with username `namespace/serviceaccount` and JWT token as password
2. Plugin calls K8s TokenReview API to validate the token
3. TokenReview returns the authenticated identity
4. Plugin verifies the identity matches the requested username

Username format: `namespace/serviceaccount`
- Example: `default/myapp`
- Example: `mariadb-auth-test/user1`

## Testing MariaDB Authentication

```bash
# Test authentication
kubectl exec -n mariadb-auth-test deploy/client-user1 --context kind-cluster-a -- \
  mysql -h mariadb -u 'mariadb-auth-test/user1' \
  -p"$(kubectl create token user1 -n mariadb-auth-test --context kind-cluster-a)" \
  -e "SELECT USER(), CURRENT_USER()"
```

## Git Commit Convention

```
<type>: <short description>

[optional body]
```

Types: feat, fix, refactor, chore, docs, build, test

No "Generated with Claude" footer or Co-Authored-By lines.
