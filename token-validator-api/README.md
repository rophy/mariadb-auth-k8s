# Token Validator API

Centralized JWT token validation service for MariaDB Kubernetes authentication.

## Features

- JWT signature verification using OIDC discovery and JWKS
- Multi-cluster support with centralized configuration
- Auto-detection of local Kubernetes cluster
- JWKS caching with TTL
- Custom CA certificate support
- Simple HTTP API

## Architecture

```
┌──────────────┐         ┌─────────────────────────┐
│ MariaDB Pod  │────────>│ Token Validator API     │
│ Auth Plugin  │  HTTP   │ - JWT validation        │
└──────────────┘         │ - OIDC discovery        │
                         │ - JWKS caching          │
                         │ - Multi-cluster configs │
                         └─────────────────────────┘
                                    │
                                    │ Fetches JWKS
                                    ▼
                         ┌─────────────────┐
                         │ K8s API Servers │
                         │ (Local + Remote)│
                         └─────────────────┘
```

## Quick Start

### Install dependencies

```bash
npm install
```

### Run locally

```bash
# Create config file
cp config/clusters.example.yaml config/clusters.yaml

# Start server
npm start
```

### Build Docker image

```bash
docker build -t token-validator-api:latest .
```

## API Endpoints

### POST /api/v1/validate

Validate a JWT token.

**Request:**
```json
{
  "cluster_name": "production-us",
  "token": "eyJhbGc..."
}
```

**Response (Success):**
```json
{
  "authenticated": true,
  "username": "production-us/app-ns/user1",
  "expiration": 1735689600
}
```

**Response (Failure):**
```json
{
  "authenticated": false,
  "error": "invalid_signature",
  "message": "Token signature verification failed"
}
```

### GET /health

Health check endpoint.

**Response:**
```json
{
  "status": "ok",
  "clusters": 2
}
```

### GET /api/v1/clusters

List configured clusters (debug).

**Response:**
```json
{
  "clusters": ["local", "production-us"],
  "count": 2
}
```

## Configuration

### Environment Variables

- `PORT` - Server port (default: 8080)
- `CLUSTER_CONFIG_PATH` - Path to clusters.yaml file

### Cluster Configuration

Create a `clusters.yaml` file:

```yaml
clusters:
  # Auto-detect local cluster
  - name: local
    auto: true

  # External cluster
  - name: production-us
    issuer: https://kubernetes.default.svc.cluster.local
    api_server: https://10.20.30.40:6443
    ca_cert_path: /etc/secrets/prod-us-ca.crt
    token_path: /etc/secrets/prod-us-token
```

## Deployment

### Deploy to Kubernetes

Kubernetes manifests are located in the root `k8s/` directory:

```bash
# Deploy all components
kubectl apply -f ../k8s/token-validator-serviceaccount.yaml
kubectl apply -f ../k8s/token-validator-configmap.yaml
kubectl apply -f ../k8s/token-validator-deployment.yaml
kubectl apply -f ../k8s/token-validator-service.yaml
kubectl apply -f ../k8s/token-validator-networkpolicy.yaml

# Verify deployment
kubectl get pods -l app=token-validator-api
kubectl logs -l app=token-validator-api
```

### Build and push image

```bash
# Build image
docker build -t token-validator-api:latest .

# Push to registry (example)
docker tag token-validator-api:latest myregistry/token-validator-api:latest
docker push myregistry/token-validator-api:latest
```

## Development

### Run tests

```bash
npm test
```

### Watch mode

```bash
npm run dev
```

## Error Codes

- `invalid_request` - Missing or invalid request parameters
- `invalid_token` - Malformed JWT
- `invalid_signature` - Signature verification failed
- `token_expired` - Token has expired
- `cluster_not_found` - Unknown cluster name
- `jwks_fetch_failed` - Failed to fetch JWKS
- `oidc_discovery_failed` - Failed to fetch OIDC configuration
- `internal_error` - Unexpected server error

## License

MIT
