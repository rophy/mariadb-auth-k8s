# SDK Compatibility

The `auth_k8s` plugin uses `mysql_clear_password` as its client-side authentication mechanism. When a client connects, the server proposes its default auth plugin (e.g. `mysql_native_password`), the client responds, and the server sends an **auth switch request** to `mysql_clear_password`. The client must then send the JWT token in cleartext.

This auth switch mechanism is where most SDK compatibility issues arise.

## Tested Versions

We maintain two test client images (old and new) to verify compatibility across SDK versions. All tests run against MariaDB 10.6, 10.11, and 11.4.

| SDK | Old (tested) | New (tested) | Non-TLS | TLS |
|-----|-------------|-------------|---------|-----|
| **mysql CLI** (mariadb-client) | — | Debian bookworm | Works | Works |
| **Python** (PyMySQL) | 0.9.3 (2019) | 1.2.0 | Works | Works |
| **Go** (go-sql-driver/mysql) | 1.5.0 (2019) | 1.10.0 | Works | Works |
| **Node.js** (mysql2) | 2.3.0 (2021) | 3.22.4 | Works | Works |
| **Java** (Connector/J 2.x) | 2.7.6 | 2.7.13 | Works | Works |
| **Java** (Connector/J 3.x) | — | 3.5.2 | **Incompatible** | Works |

## SDK-Specific Notes

### Python (PyMySQL)

PyMySQL handles the `mysql_clear_password` auth switch transparently. No special configuration is needed.

```python
import pymysql

# Without TLS
conn = pymysql.connect(
    host="mariadb",
    user="namespace/serviceaccount",
    password=jwt_token,
)

# With TLS
conn = pymysql.connect(
    host="mariadb",
    user="namespace/serviceaccount",
    password=jwt_token,
    ssl={"ca": "/path/to/ca.pem"},
)
```

Oldest tested working version: **0.9.3** (2019).

### Go (go-sql-driver/mysql)

The Go driver refuses to send cleartext passwords by default, even when the server requests it via auth switch. You must set `allowCleartextPasswords=true` in the DSN.

```go
// Without TLS
dsn := fmt.Sprintf("%s:%s@tcp(%s:3306)/?allowCleartextPasswords=true",
    user, password, host)

// With TLS (register config first)
rootCertPool := x509.NewCertPool()
pem, _ := os.ReadFile("/path/to/ca.pem")
rootCertPool.AppendCertsFromPEM(pem)
mysql.RegisterTLSConfig("custom", &tls.Config{RootCAs: rootCertPool})

dsn := fmt.Sprintf("%s:%s@tcp(%s:3306)/?allowCleartextPasswords=true&tls=custom",
    user, password, host)
```

Oldest tested working version: **1.5.0** (2019). The `allowCleartextPasswords` parameter was added in v1.4.0.

### Node.js (mysql2)

mysql2 does not include a built-in handler for `mysql_clear_password`. You must register one via the `authPlugins` option. Without it, the connection fails with "Server requests authentication using unknown plugin mysql_clear_password."

```javascript
const mysql = require("mysql2/promise");
const fs = require("fs");

// Without TLS
const conn = await mysql.createConnection({
    host: "mariadb",
    user: "namespace/serviceaccount",
    password: jwtToken,
    authPlugins: {
        mysql_clear_password: () => () => Buffer.from(password + "\0"),
    },
});

// With TLS — add ssl option
const conn = await mysql.createConnection({
    // ... same as above, plus:
    ssl: { ca: fs.readFileSync("/path/to/ca.pem") },
});
```

Oldest tested working version: **2.3.0** (2021). Versions before 2.3.0 (including 2.0.0) do not support the `authPlugins` option and cannot handle `mysql_clear_password` at all.

### Java (MariaDB Connector/J)

#### Connector/J 2.x (non-TLS and TLS)

Connector/J 2.x handles the cleartext auth switch. Without TLS, set `useSsl=false`. With TLS, point to the CA certificate.

```java
// Without TLS
String url = "jdbc:mariadb://mariadb:3306/?useSsl=false";

// With TLS
String url = "jdbc:mariadb://mariadb:3306/?useSsl=true&serverSslCert=/path/to/ca.pem";

Connection conn = DriverManager.getConnection(url, user, jwtToken);
```

Tested working range: **2.7.6** through **2.7.13** (latest 2.x).

#### Connector/J 3.x (TLS only)

Connector/J 3.x works with `auth_k8s` **only over TLS connections**. It hardcodes `requireSsl = true` for `mysql_clear_password` — there is no way to use it without SSL.

```java
// TLS required — non-TLS connections are rejected by the driver
String url = "jdbc:mariadb://mariadb:3306/?sslMode=verify-ca&serverSslCert=/path/to/ca.pem";

Connection conn = DriverManager.getConnection(url, user, jwtToken);
```

Tested version: **3.5.2**.

## Known Incompatibilities

### MariaDB Connector/J 3.x without TLS

Connector/J 3.x hardcodes `requireSsl = true` in its `ClearPasswordPluginFactory`. This means the driver unconditionally refuses to use `mysql_clear_password` without an SSL connection. There is no configuration property to override this — it is a compile-time constant in the driver source.

```java
// From Connector/J 3.5.2 — ClearPasswordPluginFactory.class
public boolean requireSsl() {
    return true;  // hardcoded, not configurable
}
```

Error message: `Cannot use authentication plugin mysql_clear_password if SSL is not enabled.`

**Workarounds:**
- Enable TLS on the MariaDB server (recommended)
- Use Connector/J 2.x (2.7.13 is the latest) if TLS is not available

### Node.js mysql2 < 2.3.0

Versions before 2.3.0 do not support the `authPlugins` configuration option. When the server sends an auth switch to `mysql_clear_password`, the driver has no handler registered and fails.

Error message: `Server requests authentication using unknown plugin mysql_clear_password.`

**Workaround:** Upgrade to mysql2 >= 2.3.0.

## TLS Setup

The test environment generates self-signed certificates automatically during `make deploy`. The certificates are stored as a Kubernetes Secret (`mariadb-tls`) and mounted into both the MariaDB server and client pods.

Server cert SANs include: `mariadb`, `mariadb.mariadb-auth-test.svc`, `mariadb.mariadb-auth-test.svc.cluster.local`, `localhost`.

## Running the Tests

```bash
# Deploy everything (builds images, generates TLS certs, deploys to Kind)
make deploy

# Run all e2e tests
make e2e-test
```

The test suite runs 66 tests total:
- 12 mysql CLI auth tests (including MDEV-38431 coverage)
- 32 SDK tests (4 SDKs x 4 tests x 2 versions, non-TLS)
- 13 TLS tests (all SDKs over TLS, including Connector/J 3.x)
- 3 authorization tests
- 6 plugin configuration tests
