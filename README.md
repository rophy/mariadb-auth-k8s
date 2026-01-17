# MariaDB Kubernetes ServiceAccount Authentication Plugin

A MariaDB authentication plugin that validates Kubernetes ServiceAccount tokens, enabling database access control based on Kubernetes identities.

## Features

- **Kubernetes-native authentication**: Uses ServiceAccount tokens instead of passwords
- **TokenReview API**: Validates tokens through the standard Kubernetes API
- **Zero password management**: Tokens are automatically mounted by Kubernetes
- **No client plugin required**: Uses built-in `mysql_clear_password` plugin

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Token Validation Flow                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Client connects with:                                   │
│     - Username: namespace/serviceaccount                    │
│     - Password: ServiceAccount JWT token                    │
│                                                             │
│  2. Plugin calls Kubernetes TokenReview API                 │
│     POST /apis/authentication.k8s.io/v1/tokenreviews        │
│                                                             │
│  3. Kubernetes validates token and returns identity         │
│     - Namespace                                             │
│     - ServiceAccount name                                   │
│                                                             │
│  4. Plugin verifies identity matches requested username     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Username Format

MariaDB username format: `namespace/serviceaccount`

| Example | Description |
|---------|-------------|
| `default/myapp` | ServiceAccount "myapp" in namespace "default" |
| `production/api-server` | ServiceAccount "api-server" in namespace "production" |

## Quick Start

### Prerequisites

- Docker
- kind (Kubernetes in Docker)
- kubectl
- skaffold

### Local Testing

```bash
# Deploy everything (builds plugin, creates cluster, deploys)
make deploy

# Run tests
make test

# Clean up
make destroy
```

Expected output:
```
✅ Test 1 PASSED: Basic authentication works
✅ Test 2 PASSED: Permission restrictions work correctly
✅ All Tests PASSED!
```

## Makefile Commands

```bash
make init      # Download MariaDB server headers (one-time)
make build     # Build auth_k8s plugin
make clean     # Clean build artifacts

make kind      # Create kind cluster
make deploy    # Build + deploy everything
make test      # Run authentication tests
make destroy   # Destroy cluster
```

## Configuration

### Creating Users

```sql
-- Grant full access
CREATE USER 'mariadb-auth-test/user1'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON *.* TO 'mariadb-auth-test/user1'@'%';

-- Grant limited access
CREATE USER 'app-ns/api-service'@'%' IDENTIFIED VIA auth_k8s;
GRANT SELECT ON app_db.* TO 'app-ns/api-service'@'%';
```

### Client Connection

```bash
# Read ServiceAccount token
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Connect to MariaDB
mysql -h mariadb -u 'namespace/serviceaccount' -p"$TOKEN"
```

## Project Structure

```
src/
  auth_k8s.c              # Main plugin source
  tokenreview_api.c/h     # TokenReview API client

k8s/
  cluster-a/              # Kubernetes manifests

scripts/
  setup-kind-clusters.sh  # Create Kind cluster
  test.sh                 # Run authentication tests
```

## Security Considerations

- **Token revocation**: TokenReview API checks token validity in real-time; deleted ServiceAccounts are immediately rejected
- **Transport**: Use TLS/SSL in production (tokens sent as cleartext password)
- **Token lifetime**: Use short-lived tokens via projected volumes or `kubectl create token --duration`

## Troubleshooting

```bash
# Check plugin loaded
mysql -u root -e "SHOW PLUGINS" | grep auth_k8s

# Check MariaDB logs
kubectl logs -n mariadb-auth-test -l app=mariadb | grep "K8s Auth"

# Verify ServiceAccount token
kubectl create token myapp -n mynamespace
```

## License

MIT
