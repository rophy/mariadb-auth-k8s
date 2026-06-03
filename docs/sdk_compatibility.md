# SDK Compatibility

The `auth_k8s` plugin uses `mysql_clear_password` as its client-side authentication mechanism. When a client connects, the server proposes its default auth plugin (e.g. `mysql_native_password`), the client responds, and the server sends an **auth switch request** to `mysql_clear_password`. The client must then send the JWT token in cleartext.

This auth switch mechanism is where most SDK compatibility issues arise.

## Tested Versions

We maintain two test client images (old and new) to verify compatibility across SDK versions. All tests run against MariaDB 10.6, 10.11, and 11.4.

| SDK | Old (tested) | New (tested) | Status |
|-----|-------------|-------------|--------|
| **mysql CLI** (mariadb-client) | — | Debian bookworm | Works |
| **Python** (PyMySQL) | 0.9.3 (2019) | 1.2.0 | Works |
| **Go** (go-sql-driver/mysql) | 1.5.0 (2019) | 1.10.0 | Works (requires `allowCleartextPasswords=true`) |
| **Node.js** (mysql2) | 2.3.0 (2021) | 3.22.4 | Works (requires `authPlugins` config) |
| **Java** (MariaDB Connector/J) | 2.7.6 | 2.7.13 | Works with 2.x (requires `useSsl=false`) |

## SDK-Specific Notes

### Python (PyMySQL)

PyMySQL handles the `mysql_clear_password` auth switch transparently. No special configuration is needed.

```python
import pymysql

conn = pymysql.connect(
    host="mariadb",
    user="namespace/serviceaccount",
    password=jwt_token,
)
```

Oldest tested working version: **0.9.3** (2019).

### Go (go-sql-driver/mysql)

The Go driver refuses to send cleartext passwords by default, even when the server requests it via auth switch. You must set `allowCleartextPasswords=true` in the DSN.

```go
dsn := fmt.Sprintf("%s:%s@tcp(%s:3306)/?allowCleartextPasswords=true",
    user, password, host)
db, err := sql.Open("mysql", dsn)
```

Oldest tested working version: **1.5.0** (2019). The `allowCleartextPasswords` parameter was added in v1.4.0.

### Node.js (mysql2)

mysql2 does not include a built-in handler for `mysql_clear_password`. You must register one via the `authPlugins` option. Without it, the connection fails with "Server requests authentication using unknown plugin mysql_clear_password."

```javascript
const mysql = require("mysql2/promise");

const conn = await mysql.createConnection({
    host: "mariadb",
    user: "namespace/serviceaccount",
    password: jwtToken,
    authPlugins: {
        mysql_clear_password: () => () => Buffer.from(password + "\0"),
    },
});
```

Oldest tested working version: **2.3.0** (2021). Versions before 2.3.0 (including 2.0.0) do not support the `authPlugins` option and cannot handle `mysql_clear_password` at all.

### Java (MariaDB Connector/J)

**Only the 2.x series is compatible.** Connector/J 3.x is not supported (see below).

Connector/J 2.x handles the cleartext auth switch, but requires `useSsl=false` in the JDBC URL — otherwise it refuses to send cleartext credentials.

```java
String url = "jdbc:mariadb://mariadb:3306/?useSsl=false";
Connection conn = DriverManager.getConnection(url, user, jwtToken);
```

Tested working range: **2.7.6** through **2.7.13** (latest 2.x).

## Known Incompatibilities

### MariaDB Connector/J 3.x

Connector/J 3.x hardcodes `requireSsl = true` in its `ClearPasswordPluginFactory`. This means the driver unconditionally refuses to use `mysql_clear_password` without an SSL connection. There is no configuration property to override this — it is a compile-time constant in the driver source.

```java
// From Connector/J 3.5.2 — ClearPasswordPluginFactory.class
public boolean requireSsl() {
    return true;  // hardcoded, not configurable
}
```

Error message: `Cannot use authentication plugin mysql_clear_password if SSL is not enabled.`

**Workarounds:**
- Use Connector/J 2.x (2.7.13 is the latest)
- Configure SSL/TLS between the client and MariaDB server
- Use a different JDBC driver (MySQL Connector/J may behave differently)

### Node.js mysql2 < 2.3.0

Versions before 2.3.0 do not support the `authPlugins` configuration option. When the server sends an auth switch to `mysql_clear_password`, the driver has no handler registered and fails.

Error message: `Server requests authentication using unknown plugin mysql_clear_password.`

**Workaround:** Upgrade to mysql2 >= 2.3.0.

## Running the Tests

```bash
# Deploy both old and new client images
make deploy

# Run all e2e tests (includes old/new SDK tests)
make e2e-test
```

The test suite runs 53 tests total: 12 mysql CLI auth tests, 32 SDK tests (4 SDKs x 4 tests x 2 versions), 3 authorization tests, and 6 plugin configuration tests.
