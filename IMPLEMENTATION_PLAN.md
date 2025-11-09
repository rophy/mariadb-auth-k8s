# Implementation Plan: Federated K8s Auth Architecture

## Overview

Refactor the MariaDB Kubernetes authentication system to use a centralized Federated K8s Auth. This architecture separates the complex JWT validation logic from the MariaDB plugin, enabling better multi-cluster support and operational simplicity.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster A (MariaDB + Federated K8s Auth)       │
│                                                             │
│  ┌──────────────┐         ┌─────────────────────────────┐ │
│  │ MariaDB Pod  │────────>│ Federated K8s Auth         │ │
│  │              │  HTTP   │ - JWT validation            │ │
│  │ Auth Plugin  │         │ - OIDC discovery            │ │
│  │ (Simplified) │         │ - JWKS caching              │ │
│  └──────────────┘         │ - Multi-cluster configs     │ │
│                           └─────────────────────────────┘ │
│                                      │                     │
│                                      │ Fetches JWKS from   │
│                                      ▼                     │
│                           ┌─────────────────┐             │
│                           │ K8s API Servers │             │
│                           │ (Local + Remote)│             │
│                           └─────────────────┘             │
└─────────────────────────────────────────────────────────────┘
                                     │
                                     │ Validates tokens from
                                     ▼
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster B (Client Applications)                 │
│                                                             │
│  ┌────────────────┐                                        │
│  │ Client App Pod │──── JWT Token ───> MariaDB (Cluster A)│
│  │ SA: ns/user1   │                                        │
│  └────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. Cluster Name is Primary Identity

**Problem:** JWT issuer is not unique across clusters (often `https://kubernetes.default.svc.cluster.local`)

**Solution:**
- MariaDB username MUST include cluster name: `cluster_name/namespace/serviceaccount`
- `clusters.yaml` maps cluster names to issuer/API server/credentials
- Federated K8s Auth validates token against the cluster specified by name

**Example:**
```sql
-- User definition
CREATE USER 'production-us/app-ns/user1'@'%' IDENTIFIED VIA auth_k8s;

-- Client connects
-- MariaDB extracts: cluster_name="production-us"
-- API validates token using "production-us" cluster config
-- Returns: "production-us/app-ns/user1"
```

### 2. No API Authentication (v1)

**Decision:** Federated K8s Auth has no authentication in initial version

**Rationale:**
- Deployed in same cluster as MariaDB
- Protected by Kubernetes NetworkPolicy (only MariaDB pods can access)
- Simpler initial implementation
- Can add mTLS/bearer token authentication later

**Future Work:** Add Bearer token authentication for multi-cluster API deployments

### 3. Three Authentication Plugin Implementations

| Implementation | Use Case | Dependencies |
|----------------|----------|--------------|
| `auth_k8s_tokenreview` | Simple, single cluster | curl, json-c |
| `auth_k8s_jwt` | Standalone, no external service | curl, json-c, openssl |
| `auth_k8s_api` | **Production, multi-cluster** (NEW) | curl, json-c |

**Build Options:**
```bash
# API-based (default, production)
cmake -DUSE_TOKEN_VALIDATOR_API=ON ..

# Standalone JWT validation
cmake -DUSE_JWT_VALIDATION=ON ..

# TokenReview API (legacy)
cmake ..  # or -DUSE_TOKEN_REVIEW=ON
```

### 4. Auto-detect Local Cluster

**Decision:** Federated K8s Auth automatically configures local cluster

**How:**
- Detect when running in Kubernetes pod (check `/var/run/secrets/kubernetes.io/serviceaccount/`)
- Auto-create "local" cluster config:
  - `name: local`
  - `issuer: <read from token>`
  - `api_server: https://kubernetes.default.svc`
  - `ca_cert_path: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt`
  - `token_path: /var/run/secrets/kubernetes.io/serviceaccount/token`
- External clusters loaded from `clusters.yaml` ConfigMap

### 5. Error Response Format

**Success:**
```json
HTTP 200 OK
{
  "authenticated": true,
  "username": "production-us/app-ns/user1",
  "expiration": 1735689600
}
```

**Failure:**
```json
HTTP 401 Unauthorized
{
  "authenticated": false,
  "error": "invalid_signature",
  "message": "Token signature verification failed"
}
```

**Error Codes:**
- `invalid_token` - Malformed JWT
- `invalid_signature` - Signature verification failed
- `token_expired` - Token expiration claim exceeded
- `cluster_not_found` - No cluster config matches requested cluster_name
- `jwks_fetch_failed` - Failed to fetch JWKS from cluster
- `issuer_mismatch` - Token issuer doesn't match cluster config (warning, not error)

**Server Error:**
```json
HTTP 500 Internal Server Error
{
  "authenticated": false,
  "error": "internal_error",
  "message": "Unexpected error during validation"
}
```

## Implementation Stages

### Stage 1: Federated K8s Auth (Node.js)
**Goal:** Create standalone HTTP API for token validation
**Success Criteria:**
- API validates JWT tokens using OIDC discovery + JWKS
- Supports multiple cluster configurations
- Auto-detects local cluster
- Returns username in format: `cluster_name/namespace/serviceaccount`

**Tasks:**
1. Create `federated-k8s-auth/` folder structure
2. Implement Node.js HTTP server (Express or Fastify)
3. Implement JWT validation logic:
   - Parse JWT header/payload
   - Extract issuer claim
   - Fetch OIDC discovery document
   - Fetch and cache JWKS keys
   - Verify RS256 signature
   - Validate claims (exp, iss, sub)
4. Implement cluster configuration:
   - Load from YAML file
   - Auto-detect local cluster
   - Support multiple clusters
5. Create Dockerfile
6. Create package.json with dependencies
7. Write unit tests

**Files:**
```
federated-k8s-auth/
├── package.json
├── package-lock.json
├── Dockerfile
├── .dockerignore
├── src/
│   ├── index.js              # Main entry point
│   ├── server.js             # HTTP server (Express/Fastify)
│   ├── validator.js          # JWT validation logic
│   ├── cluster-config.js     # Load and manage cluster configs
│   ├── jwks-cache.js         # JWKS caching with TTL
│   └── oidc-discovery.js     # OIDC discovery logic
├── config/
│   └── clusters.example.yaml # Example configuration
└── test/
    ├── validator.test.js     # Unit tests
    └── fixtures/             # Test JWTs and keys
```

**Dependencies (package.json):**
```json
{
  "dependencies": {
    "express": "^4.18.x",
    "jose": "^5.x",           // Modern JWT library
    "axios": "^1.6.x",        // HTTP client for OIDC/JWKS
    "https-proxy-agent": "^7.x", // Support custom CA certs
    "js-yaml": "^4.1.x"       // Parse YAML configs
  },
  "devDependencies": {
    "jest": "^29.x",
    "supertest": "^6.x"
  }
}
```

**API Endpoints:**
```
POST /api/v1/validate      - Validate token
GET  /health               - Health check
GET  /api/v1/clusters      - List configured clusters (debug)
```

**Tests:**
- [ ] Validate token from local cluster
- [ ] Validate token with valid signature
- [ ] Reject token with invalid signature
- [ ] Reject expired token
- [ ] Handle cluster not found
- [ ] Cache JWKS keys (verify no duplicate fetches)
- [ ] Refresh JWKS on TTL expiration
- [ ] Auto-detect local cluster
- [ ] Return correct username format

**Status:** Complete

---

### Stage 2: Kubernetes Deployment Manifests
**Goal:** Deploy Federated K8s Auth in Kubernetes
**Success Criteria:**
- API runs as Deployment with multiple replicas
- Exposes Service for MariaDB to access
- Loads cluster configs from ConfigMap
- Loads cluster credentials from Secrets

**Tasks:**
1. Create Deployment manifest
2. Create Service manifest
3. Create ConfigMap for cluster configurations
4. Create Secret template for cluster credentials
5. Create NetworkPolicy (only MariaDB can access)
6. Document deployment process

**Files:**
```
k8s/
├── token-validator-deployment.yaml       # Deployment (3 replicas)
├── token-validator-service.yaml          # ClusterIP Service
├── token-validator-serviceaccount.yaml   # ServiceAccount & RBAC
├── token-validator-configmap.yaml        # Cluster configurations
├── token-validator-secrets.yaml.example  # Template for cluster tokens/certs
└── token-validator-networkpolicy.yaml    # Restrict access to MariaDB pods
```

**ConfigMap Example:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: token-validator-config
  namespace: default
data:
  clusters.yaml: |
    clusters:
      - name: local
        auto: true  # Auto-detect from pod's ServiceAccount

      - name: production-us
        issuer: https://kubernetes.default.svc.cluster.local
        api_server: https://10.20.30.40:6443
        ca_cert_path: /etc/secrets/prod-us-ca.crt
        token_path: /etc/secrets/prod-us-token
```

**Secret Example:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: token-validator-secrets
  namespace: default
type: Opaque
data:
  prod-us-ca.crt: <base64-encoded-ca-cert>
  prod-us-token: <base64-encoded-service-account-token>
```

**Tests:**
- [ ] Deploy API to Kubernetes
- [ ] Verify auto-detection of local cluster
- [ ] Verify external cluster config loaded
- [ ] Test API endpoint from within cluster
- [ ] Verify NetworkPolicy blocks external access

**Status:** Complete

---

### Stage 3: Simplified MariaDB Auth Plugin (API Client)
**Goal:** Create new MariaDB plugin that calls Federated K8s Auth
**Success Criteria:**
- Plugin extracts cluster_name from MariaDB username
- Calls Federated K8s Auth via HTTP
- Returns authenticated username to MariaDB
- All tests pass (user1, user2 authentication)

**Tasks:**
1. Create `src/auth_k8s_api.c` (new file)
2. Implement HTTP client to call API
3. Parse API JSON response
4. Extract username and set in `info->authenticated_as`
5. Update CMakeLists.txt with new build option
6. Update test scripts

**Implementation:**
```c
// src/auth_k8s_api.c

/*
 * Parse MariaDB username to extract cluster name
 * Input:  "production-us/app-ns/user1"
 * Output: cluster_name="production-us"
 */

/*
 * Call Federated K8s Auth
 * POST http://federated-k8s-auth:8080/api/v1/validate
 * {
 *   "cluster_name": "production-us",
 *   "token": "eyJhbGc..."
 * }
 */

/*
 * Parse JSON response
 * {
 *   "authenticated": true,
 *   "username": "production-us/app-ns/user1"
 * }
 */

/*
 * Set authenticated username
 * strncpy(info->authenticated_as, username, ...)
 */
```

**Configuration:**
```c
// Federated K8s Auth endpoint (configurable via environment variable)
const char *api_url = getenv("TOKEN_VALIDATOR_API_URL") ?:
                      "http://federated-k8s-auth.default.svc.cluster.local:8080";
```

**CMakeLists.txt:**
```cmake
OPTION(USE_TOKEN_VALIDATOR_API "Build with Federated K8s Auth support" ON)

IF(USE_TOKEN_VALIDATOR_API)
    MESSAGE(STATUS "Federated K8s Auth enabled")
    ADD_LIBRARY(auth_k8s MODULE src/auth_k8s_api.c)
    TARGET_LINK_LIBRARIES(auth_k8s ${CURL_LIBRARIES} ${JSON_C_LIBRARIES})
    TARGET_INCLUDE_DIRECTORIES(auth_k8s PRIVATE ${CURL_INCLUDE_DIRS} ${JSON_C_INCLUDE_DIRS})
ELSEIF(USE_JWT_VALIDATION)
    MESSAGE(STATUS "Standalone JWT validation enabled")
    ADD_LIBRARY(auth_k8s MODULE src/auth_k8s_server_jwt.c src/k8s_jwt_validator.c)
    TARGET_LINK_LIBRARIES(auth_k8s ${CURL_LIBRARIES} ${JSON_C_LIBRARIES} OpenSSL::SSL OpenSSL::Crypto)
    TARGET_INCLUDE_DIRECTORIES(auth_k8s PRIVATE ${CURL_INCLUDE_DIRS} ${JSON_C_INCLUDE_DIRS})
ELSE()
    MESSAGE(STATUS "TokenReview API validation enabled")
    ADD_LIBRARY(auth_k8s MODULE src/auth_k8s_server.c src/k8s_token_validator.c)
    TARGET_LINK_LIBRARIES(auth_k8s ${CURL_LIBRARIES} ${JSON_C_LIBRARIES})
    TARGET_INCLUDE_DIRECTORIES(auth_k8s PRIVATE ${CURL_INCLUDE_DIRS} ${JSON_C_INCLUDE_DIRS})
ENDIF()
```

**Tests:**
- [ ] Parse username correctly (cluster_name extraction)
- [ ] Call API successfully
- [ ] Handle API authentication success
- [ ] Handle API authentication failure
- [ ] Handle API connection error
- [ ] Handle malformed API response
- [ ] User1 can access all databases
- [ ] User2 can only access testdb

**Status:** Complete

---

### Stage 4: Integration Testing & Documentation
**Goal:** End-to-end testing and documentation
**Success Criteria:**
- Complete deployment works in Kubernetes
- External cluster authentication works
- Documentation covers setup, configuration, troubleshooting

**Tasks:**
1. Test local cluster authentication
2. Test external cluster authentication (simulate with 2nd minikube cluster)
3. Test multi-MariaDB instances sharing same API
4. Test API pod restart/failure (HA)
5. Update README.md with new architecture
6. Document migration from JWT plugin to API plugin
7. Create troubleshooting guide
8. Performance testing (latency, throughput)

**Documentation:**
```
README.md
├── Architecture Overview
│   ├── Diagram
│   ├── Components
│   └── Token Flow
├── Quick Start
│   ├── Deploy Federated K8s Auth
│   ├── Deploy MariaDB with API plugin
│   └── Create test users
├── Configuration
│   ├── Cluster Configuration (clusters.yaml)
│   ├── Multi-cluster Setup
│   └── Environment Variables
├── Migration Guide
│   └── From JWT Plugin to API Plugin
└── Troubleshooting
    ├── API not reachable
    ├── Token validation failing
    └── Cluster configuration errors
```

**Tests:**
- [ ] Deploy full stack (API + MariaDB + test pods)
- [ ] Test authentication from local cluster
- [ ] Test authentication from external cluster
- [ ] Test with 3 MariaDB instances
- [ ] Kill API pod, verify HA works
- [ ] Measure latency (target: <50ms p95)
- [ ] Test token rotation
- [ ] Test adding new cluster without downtime

**Status:** Complete

---

## File Structure (Final)

```
mariadb-auth-k8s/
├── IMPLEMENTATION_PLAN.md           # This file
├── README.md                        # Updated with new architecture
├── CMakeLists.txt                   # Updated with USE_TOKEN_VALIDATOR_API
├── Dockerfile                       # MariaDB plugin builder
├── Dockerfile.mariadb               # MariaDB runtime
├── Makefile
├── skaffold.yaml
│
├── src/                             # MariaDB plugins (C)
│   ├── auth_k8s_server.c           # TokenReview API plugin
│   ├── k8s_token_validator.c
│   ├── k8s_token_validator.h
│   ├── auth_k8s_server_jwt.c       # Standalone JWT plugin
│   ├── k8s_jwt_validator.c
│   ├── k8s_jwt_validator.h
│   └── auth_k8s_api.c              # NEW: API client plugin
│
├── federated-k8s-auth/             # NEW: Node.js API service
│   ├── package.json
│   ├── package-lock.json
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── README.md
│   ├── src/
│   │   ├── index.js
│   │   ├── server.js
│   │   ├── validator.js
│   │   ├── cluster-config.js
│   │   ├── jwks-cache.js
│   │   └── oidc-discovery.js
│   ├── config/
│   │   └── clusters.example.yaml
│   └── test/
│       ├── validator.test.js
│       └── fixtures/
│
├── k8s/                             # Kubernetes manifests
│   ├── mariadb-deployment.yaml
│   ├── rbac.yaml
│   ├── test-client.yaml
│   ├── token-validator-deployment.yaml
│   ├── token-validator-service.yaml
│   ├── token-validator-serviceaccount.yaml
│   ├── token-validator-configmap.yaml
│   ├── token-validator-secrets.yaml.example
│   └── token-validator-networkpolicy.yaml
│
└── scripts/
    ├── test-auth.sh                 # Updated for API plugin
    └── deploy.sh
```

## Migration Path

### For Existing Users (JWT Plugin → API Plugin)

**Step 1:** Deploy Federated K8s Auth
```bash
kubectl apply -f k8s/token-validator-serviceaccount.yaml
kubectl apply -f k8s/token-validator-configmap.yaml
kubectl apply -f k8s/token-validator-deployment.yaml
kubectl apply -f k8s/token-validator-service.yaml
kubectl apply -f k8s/token-validator-networkpolicy.yaml
```

**Step 2:** Configure cluster credentials
```bash
# Edit configmap with cluster details
kubectl edit configmap token-validator-config

# Add cluster tokens/certs as secrets
kubectl create secret generic token-validator-secrets \
  --from-file=prod-ca.crt=./prod-cluster-ca.crt \
  --from-file=prod-token=./prod-cluster-token
```

**Step 3:** Rebuild MariaDB with API plugin
```bash
cd mariadb-auth-k8s
make clean
make build-api  # or: cmake -DUSE_TOKEN_VALIDATOR_API=ON
make deploy
```

**Step 4:** Test
```bash
scripts/test-auth.sh
```

## Benefits Summary

| Aspect | Old (JWT Plugin) | New (API Plugin) |
|--------|------------------|------------------|
| **Plugin Complexity** | 500+ lines (JWT/crypto) | ~150 lines (HTTP client) |
| **Multi-cluster Config** | Each MariaDB instance | Centralized API |
| **Token Management** | N×M tokens distributed | M tokens in API only |
| **Add Cluster** | Update all MariaDB pods | Update API ConfigMap |
| **Token Rotation** | Restart all MariaDB | Restart API only |
| **JWKS Caching** | Per MariaDB instance | Shared in API |
| **Monitoring** | Distributed logs | Centralized metrics |
| **Dependencies** | curl, json-c, openssl | curl, json-c |
| **Language** | C (hard to maintain) | API: Node.js (easy) |

## Future Enhancements

### Phase 2 (Post-MVP)
- [ ] Add Bearer token authentication for API
- [ ] Add Prometheus metrics to API
- [ ] Add rate limiting to API
- [ ] Support for mTLS between MariaDB and API
- [ ] API high availability (multiple replicas + load balancing)
- [ ] Support for additional JWT algorithms (ES256, PS256)
- [ ] Automatic JWKS key rotation handling
- [ ] Admin API for managing cluster configs

### Phase 3 (Advanced)
- [ ] Multi-cluster API deployment (API in each cluster, sync configs)
- [ ] Token caching in plugin (reduce API calls)
- [ ] Support for custom claim validation
- [ ] Integration with external identity providers (Azure AD, Google, AWS IAM)
- [ ] Audit logging
- [ ] Dashboard for monitoring authentications

## Rollout Plan

1. **Week 1:** Stage 1 - Federated K8s Auth implementation
2. **Week 2:** Stage 2 - Kubernetes deployment + Stage 3 - API plugin
3. **Week 3:** Stage 4 - Integration testing + Documentation
4. **Week 4:** Beta testing with real workloads, bug fixes
5. **Week 5:** Production rollout, monitoring

## Success Metrics

- ✅ All existing tests pass with API plugin
- ✅ API latency p95 < 50ms
- ✅ API availability > 99.9%
- ✅ Support 3+ clusters per MariaDB instance
- ✅ Zero downtime when adding new clusters
- ✅ Documentation complete with troubleshooting guide
