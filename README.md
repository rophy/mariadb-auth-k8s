# MariaDB Kubernetes ServiceAccount Authentication Plugin

[![CI](https://github.com/rophy/mariadb-auth-k8s/actions/workflows/ci.yml/badge.svg)](https://github.com/rophy/mariadb-auth-k8s/actions/workflows/ci.yml)

A MariaDB authentication plugin that validates Kubernetes ServiceAccount tokens, enabling database access control based on Kubernetes identities.

## Features

- **Kubernetes-native authentication**: Uses ServiceAccount tokens instead of passwords
- **TokenReview API**: Validates tokens through the standard Kubernetes API
- **Zero password management**: Tokens are automatically mounted by Kubernetes
- **No client plugin required**: Uses built-in `mysql_clear_password` plugin
- **Multi-version support**: Builds against MariaDB 10.6, 10.11, and 11.4

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
- bats (for e2e tests — install via `make install-bats`)

### Local Testing

```bash
# Download headers and build plugin
make init
make build

# Run unit tests (no cluster needed)
make unit-test

# Deploy everything (builds plugin, creates cluster, deploys)
make deploy

# Run e2e tests (requires deployed cluster)
make e2e-test

# Clean up
make destroy
```

### Multi-Version Builds

Build against a specific MariaDB version by passing `MARIADB_VERSION`:

```bash
make init MARIADB_VERSION=11.4.5
make build MARIADB_VERSION=11.4.5
make unit-test MARIADB_VERSION=11.4.5
```

Default is `10.6.22`. Supported versions: `10.6.22`, `10.11.10`, `11.4.5`.

## Makefile Commands

```bash
# Build
make init           # Download MariaDB server headers
make build          # Build auth_k8s plugin
make clean          # Clean build artifacts

# Test
make unit-test      # Run unit tests (no cluster needed)
make e2e-test       # Run e2e tests with BATS (needs deployed cluster)
make install-bats   # Install BATS test framework

# Development environment
make kind           # Create kind cluster
make deploy         # Build + deploy everything
make destroy        # Destroy cluster
```

All build/test targets accept `MARIADB_VERSION=<version>` (default: `10.6.22`).

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
  auth_k8s.c                      # Main plugin source
  tokenreview_api.c/h              # TokenReview API client

test/
  unit/                            # CMocka unit tests
  e2e/                             # BATS e2e tests

k8s/
  cluster-a/                       # Kubernetes manifests

scripts/
  download-headers.sh              # Download MariaDB headers
  build.sh                         # Build plugin via Docker
  setup-kind-clusters.sh           # Create Kind cluster

.github/workflows/
  ci.yml                           # CI pipeline (matrix: 10.6, 10.11, 11.4)
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
