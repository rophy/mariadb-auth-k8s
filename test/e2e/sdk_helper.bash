# Shared helpers for SDK-based e2e tests

load test_helper

SCRIPTS_DIR="/opt/test-scripts"
TLS_CA_PATH="/etc/mysql/tls/ca.pem"

# Build the SDK command suffix
_sdk_cmd() {
    local sdk="$1"
    case "$sdk" in
        pymysql) echo "python3 $SCRIPTS_DIR/pymysql_test.py" ;;
        go)      echo "$SCRIPTS_DIR/go_mysql_test" ;;
        node)    echo "cd $SCRIPTS_DIR && node node_mysql_test.js" ;;
        java)    echo "java -cp '$SCRIPTS_DIR:$SCRIPTS_DIR/mariadb-java-client.jar:/usr/share/java/mariadb-java-client.jar' MariaDBTest" ;;
        java3)   echo "java -cp '$SCRIPTS_DIR:$SCRIPTS_DIR/mariadb-java-client-3.jar' MariaDBTest" ;;
        *) echo "echo 'Unknown SDK: $sdk'; false"; return 1 ;;
    esac
}

# Execute in the right pod
_exec_pod() {
    local pod="$1"
    local cmd="$2"
    case "$pod" in
        user1)     kexec_user1 "$cmd" ;;
        user2)     kexec_user2 "$cmd" ;;
        user1-old) ka exec deployment/client-user1-old -- bash -c "$cmd" ;;
        user2-old) ka exec deployment/client-user2-old -- bash -c "$cmd" ;;
        *) echo "Unknown pod: $pod"; return 1 ;;
    esac
}

# Run an SDK test script in a test pod with the pod's SA token
# Usage: sdk_query <sdk> <pod> <mysql_user> <query> [database]
sdk_query() {
    local sdk="$1"
    local pod="$2"
    local mysql_user="$3"
    local query="$4"
    local database="${5:-}"

    local cmd="export DB_HOST=$MARIADB_HOST DB_USER='$mysql_user' DB_QUERY='$query'"
    cmd+=" && export DB_PASSWORD=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    [[ -n "$database" ]] && cmd+=" && export DB_DATABASE='$database'"
    cmd+=" && $(_sdk_cmd "$sdk")"

    _exec_pod "$pod" "$cmd"
}

# Run an SDK test script with an explicit token (for negative tests)
# Usage: sdk_with_token <sdk> <pod> <mysql_user> <token> <query>
sdk_with_token() {
    local sdk="$1"
    local pod="$2"
    local mysql_user="$3"
    local token="$4"
    local query="$5"

    local cmd="export DB_HOST=$MARIADB_HOST DB_USER='$mysql_user' DB_PASSWORD='$token' DB_QUERY='$query'"
    cmd+=" && $(_sdk_cmd "$sdk")"

    _exec_pod "$pod" "$cmd"
}

# Run an SDK test script with TLS enabled
# Usage: sdk_query_tls <sdk> <pod> <mysql_user> <query> [database]
sdk_query_tls() {
    local sdk="$1"
    local pod="$2"
    local mysql_user="$3"
    local query="$4"
    local database="${5:-}"

    local cmd="export DB_HOST=$MARIADB_HOST DB_USER='$mysql_user' DB_QUERY='$query'"
    cmd+=" && export DB_PASSWORD=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    cmd+=" && export DB_TLS_CA=$TLS_CA_PATH"
    [[ -n "$database" ]] && cmd+=" && export DB_DATABASE='$database'"

    # Java SDKs use DB_JDBC_PARAMS instead of DB_TLS_CA
    case "$sdk" in
        java)  cmd+=" && export DB_JDBC_PARAMS='useSsl=true&serverSslCert=$TLS_CA_PATH'" ;;
        java3) cmd+=" && export DB_JDBC_PARAMS='sslMode=verify-ca&serverSslCert=$TLS_CA_PATH'" ;;
    esac

    cmd+=" && $(_sdk_cmd "$sdk")"

    _exec_pod "$pod" "$cmd"
}
