# Plugin Unification Refactoring

## Overview

Merge the three separate plugin variants (Validator API, JWT, TokenReview) into a single unified plugin with automatic fallback.

## Current State

Three separate plugins compiled via CMake flags:

| Variant | CMake Flag | Source File | Use Case |
|---------|-----------|-------------|----------|
| Validator API | `-DUSE_TOKEN_VALIDATOR_API=ON` | `auth_k8s_validator_api.c` | Multi-cluster via kube-federated-auth |
| JWT | `-DUSE_JWT_VALIDATION=ON` | `auth_k8s_jwt.c` | Local OIDC/JWKS validation |
| TokenReview | (default) | `auth_k8s_tokenreview.c` | K8s TokenReview API |

## Target State

Single unified plugin (`auth_k8s.c`) with automatic fallback chain.

## Username Format

MariaDB username format: `cluster/namespace/serviceaccount`

- **3-part**: `cluster-b/default/myapp` → cross-cluster
- **3-part with "local"**: `local/default/myapp` → local cluster
- **2-part**: `default/myapp` → local cluster (implicit)

## Validation Flow

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
│  2. AUTH API configured? (KUBE_FEDERATED_AUTH_URL env set)  │
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

## Validation Methods

### 1. AUTH API (kube-federated-auth)

- **Endpoint**: `POST /validate`
- **Request**: `{"cluster": "...", "token": "..."}`
- **Response**: JWT claims including `cluster`, `kubernetes.io.namespace`, `kubernetes.io.serviceaccount.name`
- **Env var**: `KUBE_FEDERATED_AUTH_URL`
- **Supports**: Multi-cluster, revocation checking (uses TokenReview internally)

### 2. JWKS (Local OIDC)

- Fetches OIDC discovery from `https://kubernetes.default.svc.cluster.local/.well-known/openid-configuration`
- Fetches JWKS from discovered `jwks_uri`
- Validates JWT signature locally using public keys
- **Note**: Cannot detect revoked tokens (deleted ServiceAccount tokens still valid until expiry)
- **Use case**: Fallback when AUTH API unavailable, local cluster only

### 3. TokenReview (Not Used)

- Keep existing code in `tokenreview_api.c` and `tokenreview_api.h`
- Not wired into unified plugin
- Available for future use if needed

## Implementation Plan

### Step 1: Create unified source file

Create `src/auth_k8s.c` that:
1. Includes headers for both AUTH API (curl, json-c) and JWKS (jwt_crypto.h)
2. Implements `parse_username()` to extract cluster/namespace/sa
3. Implements `validate_via_auth_api()` (from auth_k8s_validator_api.c)
4. Implements `validate_via_jwks()` (from auth_k8s_jwt.c)
5. Implements main `auth_k8s_server()` with fallback logic

### Step 2: Update CMakeLists.txt

- Single build target `auth_k8s.so`
- Link all dependencies: curl, json-c, ssl, crypto
- Remove conditional compilation flags

### Step 3: Update build scripts

- `include/build-all-plugins.sh` → build single plugin
- `Makefile` → simplify build targets
- `Dockerfile` → single plugin output

### Step 4: Update deployment

- `Dockerfile.mariadb` → copy single plugin
- No changes to K8s manifests (env vars same)

### Step 5: Testing

- Test with AUTH API configured → should use AUTH API
- Test without AUTH API → should fallback to JWKS for local users
- Test cross-cluster without AUTH API → should fail
- Run full `make test`

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KUBE_FEDERATED_AUTH_URL` | AUTH API endpoint | (none - enables AUTH API if set) |
| `MAX_TOKEN_TTL` | Maximum allowed token lifetime in seconds | 3600 |

## Security Considerations

- **AUTH API**: Full revocation support (recommended for production)
- **JWKS fallback**: Accepts revocation risk for simplicity
  - Deleted ServiceAccount tokens remain valid until expiry
  - Mitigate by using short token TTL (`MAX_TOKEN_TTL`)

## Files to Modify

```
src/
  auth_k8s.c              # NEW: unified plugin
  auth_k8s_validator_api.c # DELETE after migration
  auth_k8s_jwt.c          # DELETE after migration
  auth_k8s_tokenreview.c  # KEEP (not used, future option)
  jwt_crypto.c            # KEEP (used by JWKS)
  jwt_crypto.h            # KEEP
  tokenreview_api.c       # KEEP (not used, future option)
  tokenreview_api.h       # KEEP

CMakeLists.txt            # Simplify to single target
Makefile                  # Simplify build targets
Dockerfile                # Single plugin output
include/build-all-plugins.sh # Remove or simplify
```

## Rollback Plan

If issues arise, revert to current 3-variant approach by:
1. Reverting CMakeLists.txt
2. Restoring build-all-plugins.sh
3. Using `-DUSE_TOKEN_VALIDATOR_API=ON` for production
