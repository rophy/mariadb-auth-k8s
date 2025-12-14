# MariaDB Kubernetes ServiceAccount Authentication Plugin

A MariaDB authentication plugin that validates Kubernetes ServiceAccount tokens, enabling database access control based on Kubernetes identities.

## Features

- **Kubernetes-native authentication**: Uses ServiceAccount tokens instead of passwords
- **Multi-cluster support**: Authenticate users from multiple Kubernetes clusters via [kube-federated-auth](https://github.com/rophy/kube-federated-auth)
- **Automatic fallback**: AUTH API (primary) → JWKS (local fallback)
- **Zero password management**: Tokens are automatically mounted by Kubernetes
- **No client plugin required**: Uses built-in `mysql_clear_password` plugin

## Dependencies

For multi-cluster support, this plugin requires [kube-federated-auth](https://github.com/rophy/kube-federated-auth) - a Kubernetes-native token validation service that federates authentication across multiple clusters.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Token Validation Flow                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Parse username                                          │
│     ├─ 3-part (cluster/ns/sa) → extract cluster             │
│     │   └─ if cluster == "local" → is_local = true          │
│     └─ 2-part (ns/sa) → is_local = true, cluster = "local"  │
│                                                             │
│  2. AUTH API configured? (KUBE_FEDERATED_AUTH_URL set)      │
│     ├─ Yes → Try AUTH API (kube-federated-auth service)     │
│     │        ├─ Success → DONE                              │
│     │        └─ Unavailable (network error) → Fallback      │
│     └─ No → Fallback                                        │
│                                                             │
│  3. Is cross-cluster? (cluster != "local" && 3-part)        │
│     └─ Yes → FAIL (cannot validate without AUTH API)        │
│                                                             │
│  4. JWKS validation (local OIDC discovery)                  │
│     ├─ Success → DONE                                       │
│     └─ Fail → FAIL                                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Username Format

MariaDB username format: `cluster/namespace/serviceaccount`

| Format | Example | Cluster |
|--------|---------|---------|
| 3-part | `cluster-b/default/myapp` | cross-cluster |
| 3-part with "local" | `local/default/myapp` | local cluster |
| 2-part | `default/myapp` | local cluster (implicit) |

## Quick Start

### Prerequisites

- Docker
- kind (Kubernetes in Docker)
- kubectl
- skaffold

### Multi-Cluster Testing

```bash
# Deploy everything (builds plugin, creates clusters, deploys)
make deploy

# Run tests
make test

# Clean up
make destroy
```

Expected output:
```
✅ Test 1 PASSED: Local cluster authentication works
✅ Test 2 PASSED: Direct cross-cluster authentication works!
✅ Test 3 PASSED: Token TTL validation works correctly
✅ Test 4 PASSED: Permission restrictions work correctly
✅ All Multi-Cluster Tests PASSED!
```

## Makefile Commands

```bash
make init      # Download MariaDB server headers (one-time)
make build     # Build unified plugin
make clean     # Clean build artifacts

make kind      # Create kind clusters (cluster-a, cluster-b)
make deploy    # Build + deploy everything
make test      # Run authentication tests
make destroy   # Destroy clusters
```

## Configuration

### Creating Users

```sql
-- Local cluster user
CREATE USER 'local/mariadb-auth-test/user1'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON *.* TO 'local/mariadb-auth-test/user1'@'%';

-- Cross-cluster user
CREATE USER 'cluster-b/remote-test/remote-user'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON *.* TO 'cluster-b/remote-test/remote-user'@'%';

-- 2-part format (local cluster implied)
CREATE USER 'app-ns/api-service'@'%' IDENTIFIED VIA auth_k8s;
GRANT SELECT ON app_db.* TO 'app-ns/api-service'@'%';
```

### Client Connection

```bash
# Read ServiceAccount token
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Connect to MariaDB
mysql -h mariadb -u 'local/namespace/serviceaccount' -p"$TOKEN"
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KUBE_FEDERATED_AUTH_URL` | AUTH API endpoint | (none - enables AUTH API if set) |
| `MAX_TOKEN_TTL` | Maximum allowed token lifetime in seconds | 3600 |

## Project Structure

```
src/
  auth_k8s.c              # Unified plugin (AUTH API + JWKS fallback)
  jwt_crypto.c/h          # JWT cryptographic operations
  tokenreview_api.c/h     # TokenReview API client (kept for future use)
  auth_k8s_tokenreview.c  # TokenReview-only plugin (kept for future use)

k8s/
  cluster-a/              # MariaDB + kube-federated-auth
  cluster-b/              # Remote test client

scripts/
  setup-kind-clusters.sh  # Create Kind clusters
  setup-multicluster.sh   # Configure cross-cluster auth
  test.sh                 # Run authentication tests
```

## Security Considerations

- **AUTH API**: Full revocation support via TokenReview (recommended for production)
- **JWKS fallback**: Deleted ServiceAccount tokens remain valid until expiry
  - Mitigate by using short token TTL (`MAX_TOKEN_TTL`)
- **Transport**: Use TLS/SSL in production (tokens sent as cleartext password)

## Troubleshooting

```bash
# Check plugin loaded
mysql -u root -e "SHOW PLUGINS" | grep auth_k8s

# Check MariaDB logs
kubectl logs -n mariadb-auth-test -l app=mariadb | grep "K8s Auth"

# Check kube-federated-auth logs
kubectl logs -n mariadb-auth-test -l app=kube-federated-auth

# Test token validation manually
kubectl exec -n mariadb-auth-test deploy/client-user1 -- \
  curl -s http://kube-federated-auth:8080/clusters
```

## License

GPL (matching MariaDB plugin license requirements)
