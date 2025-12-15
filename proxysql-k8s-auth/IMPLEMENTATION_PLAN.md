# ProxySQL K8s Authentication - Implementation Plan

## Overview

Create a patched ProxySQL container image that supports Kubernetes ServiceAccount token authentication, enabling passthrough to MariaDB's `auth_k8s` plugin.

## Architecture

```
┌─────────────┐    mysql_clear_password    ┌──────────────┐    mysql_clear_password    ┌─────────────┐
│   Client    │ ──────────────────────────>│   ProxySQL   │ ──────────────────────────>│   MariaDB   │
│  (kubectl)  │      JWT Token             │  (patched)   │      JWT Token             │  (auth_k8s) │
└─────────────┘                            └──────┬───────┘                            └─────────────┘
                                                  │
                                                  │ HTTP POST /validate
                                                  v
                                           ┌──────────────────┐
                                           │ kube-federated-  │
                                           │      auth        │
                                           └──────────────────┘
```

## Components

### 1. K8s Auth Plugin (`mysql_k8s_auth_plugin.so`)

**Purpose**: Drop-in replacement for LDAP plugin, validates K8s tokens via kube-federated-auth.

**Interface**: Implements `MySQL_LDAP_Authentication` class exactly.

**Key Method**: `lookup()` - validates token and returns session parameters.

### 2. ProxySQL Core Patches

**Purpose**: Enable `mysql_clear_password` for backend connections to MariaDB.

**Scope**: ~30 lines across 3 files.

### 3. Container Image

**Base**: `proxysql/proxysql:2.x` or build from source.

**Additions**: K8s auth plugin + core patches.

---

## Detailed Implementation

### Part 1: K8s Auth Plugin

#### Files to Create

```
proxysql-k8s-auth/
├── plugin/
│   ├── mysql_k8s_auth.h           # Plugin class definition
│   ├── mysql_k8s_auth.cpp         # Plugin implementation
│   ├── k8s_token_validator.h      # HTTP client for kube-federated-auth
│   ├── k8s_token_validator.cpp    # Token validation logic
│   └── Makefile                   # Build plugin .so
├── patches/
│   ├── 001-backend-clear-password.patch  # Core ProxySQL patch
│   └── apply-patches.sh           # Patch application script
├── Dockerfile                     # Build patched ProxySQL image
├── Makefile                       # Top-level build
└── IMPLEMENTATION_PLAN.md         # This file
```

#### Plugin Class Design

```cpp
class MySQL_K8s_Authentication : public MySQL_LDAP_Authentication {
private:
    // Configuration (set via ldap-* variables)
    std::string kube_federated_auth_url;  // default: "http://kube-federated-auth:8080/validate"
    int default_hostgroup;                 // default: 1
    int max_connections;                   // default: 10000
    int connect_timeout_ms;                // default: 5000

    // Connection tracking
    std::map<std::string, int> user_connections;
    pthread_rwlock_t lock;

    // Token validator
    K8sTokenValidator* validator;

public:
    // Constructor/Destructor
    MySQL_K8s_Authentication();
    ~MySQL_K8s_Authentication();

    // Core authentication - MAIN ENTRY POINT
    char* lookup(char *username, char *pass,
                 enum cred_username_type usertype,
                 bool *use_ssl, int *default_hostgroup,
                 char **default_schema, bool *schema_locked,
                 bool *transaction_persistent, bool *fast_forward,
                 int *max_connections, void **sha1_pass,
                 char **attributes, char **backend_username) override;

    // Connection tracking
    int increase_frontend_user_connections(char *username, int *max_connections) override;
    void decrease_frontend_user_connections(char *username) override;

    // Variable management (exposed as ldap-* in ProxySQL admin)
    char** get_variables_list() override;
    char* get_variable(char *name) override;
    bool set_variable(char *name, char *value) override;
    bool has_variable(const char *name) override;

    // Locking
    void wrlock() override;
    void wrunlock() override;

    // Stats/Debug
    std::unique_ptr<SQLite3_result> dump_all_users() override;
    SQLite3_result* SQL3_getStats() override;
    void print_version() override;

    // LDAP mapping table (repurposed for K8s user mappings)
    void load_mysql_ldap_mapping(SQLite3_result *result) override;
    SQLite3_result* dump_table_mysql_ldap_mapping() override;
};
```

#### lookup() Flow

```
1. Parse username
   Input: "cluster-b/remote-test/remote-user" or "local/ns/sa" or "ns/sa"
   Output: cluster, namespace, serviceaccount
   - 3-part with known cluster: cluster = first part
   - 3-part with "local": cluster = "local"
   - 2-part: cluster = "local" (implicit)

2. Validate token via kube-federated-auth
   POST http://kube-federated-auth:8080/validate
   Body: {"cluster": "cluster-b", "token": "<JWT>"}

3. Verify response
   - HTTP 200 = valid
   - Parse claims: cluster, kubernetes.io.namespace, kubernetes.io.serviceaccount.name
   - Verify claims match parsed username

4. Set output parameters
   - default_hostgroup = configured hostgroup
   - backend_username = username (SAME - no mapping)
   - use_ssl = false
   - fast_forward = false
   - No caching

5. Return
   - Success: return strdup(pass)  // Echo token back
   - Failure: return NULL
```

#### Token Validator Class

```cpp
class K8sTokenValidator {
private:
    CURL* curl;
    std::string url;
    int timeout_ms;

public:
    K8sTokenValidator(const std::string& url, int timeout_ms);
    ~K8sTokenValidator();

    struct ValidationResult {
        bool valid;
        std::string cluster;
        std::string ns;
        std::string sa;
        std::string error;
    };

    ValidationResult validate(const std::string& cluster, const std::string& token);
};
```

#### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ldap-kube_federated_auth_url` | `http://kube-federated-auth:8080/validate` | Validation endpoint |
| `ldap-default_hostgroup` | `1` | Default hostgroup for K8s users |
| `ldap-max_connections` | `10000` | Max connections per user |
| `ldap-connect_timeout_ms` | `5000` | HTTP timeout for validation |

---

### Part 2: ProxySQL Core Patches

#### Patch 1: Add flag to userinfo (`include/mysql_connection.h`)

```diff
 class MySQL_Connection_userinfo {
   private:
     uint64_t compute_hash();
   public:
     uint64_t hash;
     char *username;
     char *password;
     PASSWORD_TYPE::E passtype;
     char *schemaname;
     char *sha1_pass;
     char *fe_username;
+    bool use_clear_password_backend;  // For K8s auth passthrough
     MySQL_Connection_userinfo();
     ~MySQL_Connection_userinfo();
```

#### Patch 2: Initialize and copy flag (`lib/mysql_connection.cpp`)

```diff
 MySQL_Connection_userinfo::MySQL_Connection_userinfo() {
     hash = 0;
     username = NULL;
     password = NULL;
     passtype = PASSWORD_TYPE::PRIMARY;
     schemaname = NULL;
     sha1_pass = NULL;
     fe_username = NULL;
+    use_clear_password_backend = false;
 }

 void MySQL_Connection_userinfo::set(MySQL_Connection_userinfo *ui) {
     // ... existing code ...
     if (ui->fe_username) {
         fe_username = strdup(ui->fe_username);
     }
+    use_clear_password_backend = ui->use_clear_password_backend;
 }
```

#### Patch 3: Set mysql_clear_password option (`lib/mysql_connection.cpp`)

```diff
 void MySQL_Connection::connect_start() {
     PROXY_TRACE();
     mysql=mysql_init(NULL);
     assert(mysql);
     mysql_options(mysql, MYSQL_OPT_NONBLOCK, 0);

     connect_start_SetAttributes();
     connect_start_SetSslSettings();

     unsigned int timeout= 1;
     mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, (void *)&timeout);

     connect_start_SetCharset();

+    // K8s auth: force mysql_clear_password for backend
+    if (userinfo->use_clear_password_backend) {
+        mysql_options(mysql, MYSQL_DEFAULT_AUTH, "mysql_clear_password");
+    }

     unsigned long client_flags = 0;
     connect_start_SetClientFlag(client_flags);
```

#### Patch 4: Parse user_attributes (`lib/MySQL_Session.cpp`)

```diff
 // In handler___client_DSS_QUERY_SENT___server_DSS_NOT_INITIALIZED__get_connection()
 // Around line 7455-7459:

 if (mybe->server_myds->myconn->fd==-1) {
     proxy_debug(PROXY_DEBUG_MYSQL_CONNECTION, 5, "Sess=%p -- MySQL Connection has no FD\n", this);
     MySQL_Connection *myconn=mybe->server_myds->myconn;
     myconn->userinfo->set(client_myds->myconn->userinfo);

+    // K8s auth: check for use_clear_password_backend in user_attributes
+    if (user_attributes != NULL && strlen(user_attributes)) {
+        try {
+            nlohmann::json j_attrs = nlohmann::json::parse(user_attributes);
+            if (j_attrs.contains("use_clear_password_backend")) {
+                myconn->userinfo->use_clear_password_backend =
+                    j_attrs["use_clear_password_backend"].get<bool>();
+            }
+        } catch (...) {
+            // Ignore JSON parse errors
+        }
+    }

     myconn->handler(0);
```

---

### Part 3: Container Image Build

#### Dockerfile Strategy

**Option A: Patch ProxySQL Source (Recommended)**
- Clone ProxySQL source
- Apply patches
- Build from source
- Include K8s auth plugin

**Option B: Patch Binary Image**
- Start from `proxysql/proxysql:latest`
- Cannot patch core (binary)
- Only works if backend clear_password not needed

We'll use **Option A**.

#### Dockerfile Outline

```dockerfile
# Stage 1: Build ProxySQL with patches
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential cmake git \
    libssl-dev libcurl4-openssl-dev \
    libmariadb-dev uuid-dev \
    ...

# Clone ProxySQL
ARG PROXYSQL_VERSION=2.6.3
RUN git clone --depth 1 --branch v${PROXYSQL_VERSION} \
    https://github.com/sysown/proxysql.git /proxysql

# Apply K8s auth patches
COPY patches/ /patches/
RUN cd /proxysql && \
    for p in /patches/*.patch; do patch -p1 < $p; done

# Build ProxySQL
RUN cd /proxysql && make -j$(nproc)

# Build K8s auth plugin
COPY plugin/ /plugin/
RUN cd /plugin && make

# Stage 2: Runtime image
FROM ubuntu:22.04

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libssl3 libcurl4 libmariadb3 \
    && rm -rf /var/lib/apt/lists/*

# Copy ProxySQL binary
COPY --from=builder /proxysql/src/proxysql /usr/bin/proxysql

# Copy K8s auth plugin
COPY --from=builder /plugin/mysql_k8s_auth_plugin.so /usr/lib/proxysql/

# Default config
COPY proxysql.cfg /etc/proxysql.cfg

EXPOSE 6033 6032
ENTRYPOINT ["proxysql", "-f", "-c", "/etc/proxysql.cfg"]
```

---

### Part 4: Integration with Existing Project

#### Makefile Targets

```makefile
# In main project Makefile
proxysql-build:
    cd proxysql-k8s-auth && docker build -t proxysql-k8s-auth:latest .

proxysql-deploy:
    # Deploy to Kind cluster
    kind load docker-image proxysql-k8s-auth:latest --name cluster-a
    kubectl apply -f k8s/cluster-a/proxysql-deployment.yaml

proxysql-test:
    # Test K8s auth through ProxySQL
    ./scripts/test-proxysql.sh
```

#### Kubernetes Deployment

```yaml
# k8s/cluster-a/proxysql-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: proxysql
  namespace: mariadb-auth-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: proxysql
  template:
    metadata:
      labels:
        app: proxysql
    spec:
      containers:
      - name: proxysql
        image: proxysql-k8s-auth:latest
        ports:
        - containerPort: 6033  # MySQL
        - containerPort: 6032  # Admin
        env:
        - name: KUBE_FEDERATED_AUTH_URL
          value: "http://kube-federated-auth:8080/validate"
        volumeMounts:
        - name: config
          mountPath: /etc/proxysql.cfg
          subPath: proxysql.cfg
      volumes:
      - name: config
        configMap:
          name: proxysql-config
```

---

## Testing Strategy

### Unit Tests (Plugin)

1. Username parsing: various formats
2. Token validation: mock HTTP responses
3. Variable get/set
4. Connection tracking

### Integration Tests

1. **Frontend auth**: Client → ProxySQL with K8s token
2. **Backend passthrough**: ProxySQL → MariaDB with K8s token
3. **Cross-cluster**: Token from cluster-b validated for cluster-b user
4. **Token TTL**: Reject tokens exceeding MAX_TOKEN_TTL
5. **Connection pooling**: Verify connections reused correctly

### Test Script Outline

```bash
#!/bin/bash
# test-proxysql.sh

# Test 1: Local cluster auth through ProxySQL
TOKEN=$(kubectl create token user1 -n mariadb-auth-test --context kind-cluster-a)
mysql -h proxysql -P 6033 -u 'local/mariadb-auth-test/user1' -p"$TOKEN" \
  -e "SELECT USER(), CURRENT_USER()"

# Test 2: Cross-cluster auth through ProxySQL
TOKEN=$(kubectl create token remote-user -n remote-test --context kind-cluster-b)
mysql -h proxysql -P 6033 -u 'cluster-b/remote-test/remote-user' -p"$TOKEN" \
  -e "SHOW DATABASES"
```

---

## Implementation Order

1. **Phase 1: Plugin Skeleton**
   - Create plugin with stub `lookup()` that always fails
   - Verify it loads in ProxySQL
   - Test variable get/set

2. **Phase 2: Token Validation**
   - Implement `K8sTokenValidator` with libcurl
   - Implement username parsing
   - Complete `lookup()` implementation

3. **Phase 3: ProxySQL Patches**
   - Create and test patches
   - Verify backend `mysql_clear_password` works

4. **Phase 4: Container Image**
   - Create Dockerfile
   - Build and test image

5. **Phase 5: Integration**
   - K8s deployment manifests
   - Integration tests
   - Documentation

---

## Design Decisions

1. **Connection pooling**: Let ProxySQL manage normally with `fast_forward=false`, `transaction_persistent=true`.

2. **Token caching**: **No caching.** Each connection validates fresh against kube-federated-auth.

3. **Username mapping**: **No mapping.** `backend_username = username` (same K8s username passed through to MariaDB).

4. **LDAP mapping table**: **Not used.** Stub implementation returns empty results.

---

## Dependencies

- ProxySQL source (git submodule at `proxysql/`, branch `v3.0` from `rophy/proxysql`)
- libcurl (HTTP client)
- nlohmann/json (JSON parsing) - already in ProxySQL
- libmariadb-dev (MariaDB client headers)

## Repository Setup

ProxySQL is included as a git submodule:

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/rophy/mariadb-auth-k8s.git

# Or if already cloned:
git submodule update --init --recursive
```

The submodule points to `rophy/proxysql` fork (branch `v3.0`) which will contain our patches.
