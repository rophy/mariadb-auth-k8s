# MariaDB Kubernetes ServiceAccount Authentication Plugin

A MariaDB authentication plugin that validates Kubernetes ServiceAccount tokens, enabling database access control based on Kubernetes identities.

## Features

- **Kubernetes-native authentication**: Uses ServiceAccount tokens instead of passwords
- **TokenReview API integration**: Validates tokens against Kubernetes API server
- **Namespace-scoped users**: Username format `namespace/serviceaccount`
- **Zero password management**: Tokens are automatically mounted by Kubernetes
- **No client plugin required**: Uses built-in `mysql_clear_password` plugin
- **Production-ready**: Built with libcurl and json-c for robust API calls

## Architecture

```
┌─────────────┐                    ┌──────────────┐
│   Client    │ ServiceAccount     │   MariaDB    │
│     Pod     │ Token (password)   │     Pod      │
│             ├───────────────────>│              │
│             │                    │  auth_k8s    │
└─────────────┘                    │   plugin     │
                                   └──────┬───────┘
                                          │
                                          │ TokenReview API
                                          │
                                   ┌──────▼───────┐
                                   │  Kubernetes  │
                                   │  API Server  │
                                   └──────────────┘
```

## Quick Start

### Prerequisites

- Docker
- Kubernetes cluster (minikube, kind, or cloud provider)
- kubectl configured
- skaffold (for Kubernetes deployment)

### 1. Download MariaDB Headers

```bash
# Download and package MariaDB server headers (one-time setup)
make init
```

### 2. Build the Plugin

```bash
# Build the plugin and extract to ./build/
make build

# Output: build/auth_k8s.so
```

### 3. Deploy to Kubernetes

```bash
# Build and deploy MariaDB with the plugin
make deploy
```

### 4. Test Authentication

```bash
# Run automated tests
make test
```

Expected output:
```
==========================================
K8s ServiceAccount Authentication Tests
==========================================

==========================================
Testing User1 - Full Admin Access
==========================================

✅ User1 authentication SUCCESSFUL!

==========================================
Testing User2 - Limited Access (testdb only)
==========================================

✅ User2 authentication SUCCESSFUL!

✅ All tests PASSED!
==========================================
```

## Project Structure

```
mariadb-auth-k8s/
├── Dockerfile                    # Build environment for plugin
├── Dockerfile.mariadb            # Production MariaDB image with plugin
├── Dockerfile.client             # Test client image
├── Makefile                      # Build automation
├── skaffold.yaml                 # Kubernetes deployment automation
├── CMakeLists.txt                # Build configuration
│
├── src/                          # Source code
│   ├── auth_k8s_server.c         # Server-side authentication plugin
│   ├── k8s_token_validator.c     # TokenReview API client
│   └── k8s_token_validator.h     # TokenReview API interface
│
├── scripts/                      # Scripts
│   ├── download-headers.sh       # Download MariaDB headers
│   └── test-auth.sh              # Authentication tests
│
├── include/                      # MariaDB server headers (tarball)
│   └── mariadb-10.6.22-headers.tar.gz
│
├── init-auth-plugin.sh           # Plugin installation and user setup script
│
├── k8s/                          # Kubernetes manifests
│   ├── mariadb-deployment.yaml   # MariaDB Deployment and Service
│   ├── rbac.yaml                 # RBAC for TokenReview API
│   └── test-client.yaml          # Test client Deployments
│
└── build/                        # Build artifacts (created by make build)
    └── auth_k8s.so               # Server plugin
```

## Makefile Commands

```bash
make init         # Download and package MariaDB server headers
make build        # Build Docker image and extract plugin to ./build/
make clean        # Clean build artifacts
make test         # Run K8s ServiceAccount authentication tests
make deploy       # Build and deploy to Kubernetes
make undeploy     # Remove Kubernetes deployment
make help         # Show available commands
```

## Configuration

### Creating Users

Users are created in the format `namespace/serviceaccount`:

```sql
-- User1: Full admin access
CREATE USER 'mariadb-auth-test/user1'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON *.* TO 'mariadb-auth-test/user1'@'%';

-- User2: Limited access to testdb only
CREATE USER 'mariadb-auth-test/user2'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON testdb.* TO 'mariadb-auth-test/user2'@'%';
```

### Client Connection

From a pod with ServiceAccount token:

```bash
# Read ServiceAccount token
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Connect to MariaDB (send token as password)
mysql -h mariadb -u 'namespace/serviceaccount' -p"$SA_TOKEN"
```

The ServiceAccount token is automatically mounted at:
`/var/run/secrets/kubernetes.io/serviceaccount/token`

### RBAC Requirements

The MariaDB pod's ServiceAccount needs permission to create TokenReview objects:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tokenreview-creator
rules:
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: mariadb-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tokenreview-creator
subjects:
- kind: ServiceAccount
  name: mariadb
  namespace: mariadb-auth-test
```

See `k8s/rbac.yaml` for complete RBAC configuration.

## How It Works

### Authentication Flow

1. **Client requests connection** with username `namespace/serviceaccount`
2. **Client reads ServiceAccount token** from mounted secret
3. **Client sends token as password** using built-in `mysql_clear_password` plugin
4. **Server plugin receives token** and calls Kubernetes TokenReview API
5. **Kubernetes validates token** and returns identity information
6. **Server plugin extracts** namespace and serviceaccount from response:
   - Parses `system:serviceaccount:namespace:serviceaccount` from token
7. **Server plugin verifies** that `namespace/serviceaccount` matches username
8. **Access granted** if validation succeeds

### TokenReview API Call

```http
POST https://kubernetes.default.svc/apis/authentication.k8s.io/v1/tokenreviews
Content-Type: application/json
```

Request:
```json
{
  "kind": "TokenReview",
  "apiVersion": "authentication.k8s.io/v1",
  "spec": {
    "token": "eyJhbGciOiJSUzI1NiIsImtpZCI6..."
  }
}
```

Response:
```json
{
  "status": {
    "authenticated": true,
    "user": {
      "username": "system:serviceaccount:mariadb-auth-test:user1",
      "uid": "...",
      "groups": [...]
    }
  }
}
```

### Server Logs

Authentication attempts are logged:

```
K8s Auth: Received token (length=1149, preview=eyJhbGciOiJSUzI1NiIsImtpZCI6...)
K8s Auth: Authenticating user 'mariadb-auth-test/user1'
K8s Auth: Calling TokenReview API at https://kubernetes.default.svc/apis/authentication.k8s.io/v1/tokenreviews
K8s Auth: Token validated successfully
K8s Auth: Username: system:serviceaccount:mariadb-auth-test:user1
K8s Auth: Namespace: mariadb-auth-test
K8s Auth: ServiceAccount: user1
K8s Auth: ✅ Authentication successful for mariadb-auth-test/user1
```

## Security Considerations

- **Token validation**: All tokens are validated by Kubernetes API server via TokenReview API
- **No token caching**: Each authentication validates the token (can be optimized with caching)
- **Transport security**: TokenReview API uses HTTPS with cluster CA certificate
- **Namespace isolation**: Users must match their ServiceAccount's namespace
- **Audit logging**: All authentication attempts are logged by MariaDB
- **Built-in client plugin**: Uses `mysql_clear_password` - ensure TLS/SSL is enabled in production

## Troubleshooting

### Plugin Not Loading

```bash
# Check plugin status
mysql -u root -e "SELECT * FROM information_schema.PLUGINS WHERE PLUGIN_NAME='auth_k8s';"

# Check plugin maturity setting
mysql -u root -e "SHOW VARIABLES LIKE 'plugin_maturity';"

# Should be 'unknown' or higher
```

### TokenReview 403 Forbidden

```bash
# Check RBAC permissions
kubectl auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:mariadb-auth-test:mariadb

# Should return 'yes'

# Check ServiceAccount exists
kubectl get serviceaccount mariadb -n mariadb-auth-test
```

### Authentication Denied

```bash
# Check MariaDB logs for detailed error messages
kubectl logs -n mariadb-auth-test deployment/mariadb | grep "K8s Auth"

# Verify token is mounted in client pod
kubectl exec -n mariadb-auth-test deployment/client-user1 -- \
  ls -la /var/run/secrets/kubernetes.io/serviceaccount/

# Test token is valid
kubectl exec -n mariadb-auth-test deployment/client-user1 -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token

# Test manual connection
kubectl exec -n mariadb-auth-test deployment/client-user1 -- bash -c '
  SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  mysql -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "SELECT USER();"
'
```

### Running Tests

```bash
# Deploy to Kubernetes first
make deploy

# Wait for pods to be ready
kubectl wait --for=condition=ready deployment -l app=client-user1 -n mariadb-auth-test --timeout=60s
kubectl wait --for=condition=ready deployment -l app=client-user2 -n mariadb-auth-test --timeout=60s

# Run tests
make test
```

## Technical Details

### Plugin Information

- **Version**: 2.0
- **Plugin Name**: `auth_k8s`
- **Plugin Type**: Authentication
- **Server Plugin**: `auth_k8s.so`
- **Client Plugin**: Built-in `mysql_clear_password`
- **MariaDB Version**: 10.6+

### Build Dependencies

**Build-time:**
- build-essential (gcc, g++)
- cmake
- pkg-config
- libmariadb-dev
- libcurl4-openssl-dev
- libjson-c-dev

**Runtime:**
- libcurl4
- libjson-c5

### Feature Flags

The plugin supports compile-time feature flags in `src/auth_k8s_server.c`:

```c
#define ENABLE_TOKEN_VALIDATION 1  // Enable/disable TokenReview validation
```

Set to `0` for testing without Kubernetes (accepts any non-empty token).

## Performance Considerations

- Each authentication requires a Kubernetes API call (~5-10ms latency in-cluster)
- Consider implementing token caching for high-traffic scenarios
- TokenReview API is highly available and scales with the cluster
- No impact on existing password-based authentication methods
- Connection pooling recommended for applications with frequent reconnections

## Limitations

- ServiceAccount tokens expire (default 1 hour, configurable via `expirationSeconds`)
- Requires network access to Kubernetes API server from MariaDB pod
- Username format restricted to `namespace/serviceaccount`
- No support for cross-namespace authentication
- Token sent in cleartext during authentication (use TLS/SSL in production)

## Use Cases

### Multi-Tenant SaaS Application

Each tenant gets their own Kubernetes namespace with ServiceAccounts for different roles:

```sql
-- Tenant 1 Admin
CREATE USER 'tenant1/admin'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON tenant1_db.* TO 'tenant1/admin'@'%';

-- Tenant 1 App
CREATE USER 'tenant1/app'@'%' IDENTIFIED VIA auth_k8s;
GRANT SELECT, INSERT, UPDATE ON tenant1_db.* TO 'tenant1/app'@'%';

-- Tenant 2 Admin
CREATE USER 'tenant2/admin'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON tenant2_db.* TO 'tenant2/admin'@'%';
```

### Microservices Architecture

Different services get different database permissions:

```sql
-- API Service: Full access
CREATE USER 'production/api-service'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON app_db.* TO 'production/api-service'@'%';

-- Analytics Service: Read-only access
CREATE USER 'production/analytics-service'@'%' IDENTIFIED VIA auth_k8s;
GRANT SELECT ON app_db.* TO 'production/analytics-service'@'%';

-- Backup Service: Read-only with LOCK TABLES
CREATE USER 'production/backup-service'@'%' IDENTIFIED VIA auth_k8s;
GRANT SELECT, LOCK TABLES ON *.* TO 'production/backup-service'@'%';
```

## Future Enhancements

- [ ] Token caching with TTL to reduce API calls
- [ ] Metrics and monitoring integration (Prometheus)
- [ ] Support for ServiceAccount token rotation
- [ ] Integration with Kubernetes audit logs
- [ ] OpenTelemetry tracing support
- [ ] mTLS support for TokenReview API calls

## Contributing

Contributions are welcome! Please ensure:

- Code compiles without warnings
- Plugin loads successfully in MariaDB 10.6+
- TokenReview validation works in Kubernetes
- Tests pass: `make test`
- Code follows existing style conventions

## License

GPL (matching MariaDB plugin license requirements)

## References

- [MariaDB Plugin API](https://mariadb.com/kb/en/plugin-api/)
- [MariaDB Authentication Plugin Development](https://mariadb.com/kb/en/authentication-plugin-api/)
- [Kubernetes TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)
- [ServiceAccount Tokens](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## Acknowledgments

This plugin demonstrates integrating Kubernetes-native authentication with MariaDB, enabling seamless database access control based on Kubernetes identities without managing separate database passwords.

## Support

For issues and questions:
- Open an issue on GitHub
- Check MariaDB logs: `kubectl logs -n mariadb-auth-test deployment/mariadb | grep "K8s Auth"`
- Verify RBAC permissions are correctly configured
- Run tests: `make test`
