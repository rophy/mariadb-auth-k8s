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

## Installation

### From Release Tarball

Download from [Releases](https://github.com/rophy/mariadb-auth-k8s/releases):

```bash
tar xzf mariadb-auth-k8s-0.1.tar.gz
cd mariadb-auth-k8s-0.1
```

Build dependencies: `build-essential`, `cmake`, `libmariadb-dev`, `libcurl4-openssl-dev`, `libjson-c-dev`

```bash
# Debian/Ubuntu
apt install build-essential cmake libmariadb-dev libcurl4-openssl-dev libjson-c-dev

# Build and install
mkdir build && cd build
cmake ..
make
sudo make install
```

The plugin installs to your MariaDB plugin directory (auto-detected via `mysql_config --plugindir`).

### Enable the Plugin

Add to your MariaDB config (`/etc/mysql/mariadb.conf.d/auth_k8s.cnf`):

```ini
[mysqld]
plugin_load_add = auth_k8s
```

### Plugin Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `auth_k8s_api_url` | `https://kubernetes.default.svc` | Kubernetes API server URL |
| `auth_k8s_token_path` | `/var/run/secrets/kubernetes.io/serviceaccount/token` | Path to ServiceAccount token for TokenReview calls |
| `auth_k8s_ca_path` | `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` | Path to Kubernetes CA certificate |
| `auth_k8s_timeout` | `10` | HTTP timeout in seconds |

All variables are read-only (set via config file or command line only).

## Development

### Prerequisites

- Docker
- kind (Kubernetes in Docker)
- kubectl
- skaffold
- helm
- bats (install via `make install-bats`)

### Quick Start

```bash
make deploy && make e2e-test
```

### Available Targets

```
make help
```

### Multi-Version Builds

```bash
make init MARIADB_VERSION=11.4.12
make build MARIADB_VERSION=11.4.12
make unit-test MARIADB_VERSION=11.4.12
```

Supported versions: `10.6.27`, `10.11.18`, `11.4.12` (default: `10.6.27`).

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
src/                                # Plugin source (C)
helm/mariadb-auth-k8s/              # Helm chart for MariaDB deployment
test/
  unit/                             # CMocka unit tests
  e2e/                              # BATS e2e tests
k8s/cluster-a/                      # Kubernetes manifests for test environment
scripts/                            # Build, deploy, and test scripts
.github/workflows/
  ci.yml                            # CI pipeline (MariaDB 10.6, 10.11, 11.4)
  release.yml                       # Source tarball release on tag push
```

## Client SDK Compatibility

The plugin uses `mysql_clear_password` via auth switch. Most SDKs work out of the box; some need configuration. See [SDK Compatibility](docs/sdk_compatibility.md) for tested versions and code examples.

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
