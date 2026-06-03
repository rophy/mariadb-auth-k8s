# Shared helpers for SDK-based e2e tests

load test_helper

SCRIPTS_DIR="/opt/test-scripts"

# Run an SDK test script in a test pod with the pod's SA token
# Usage: sdk_query <sdk> <pod: user1|user2> <mysql_user> <query> [database]
sdk_query() {
    local sdk="$1"
    local pod="$2"
    local mysql_user="$3"
    local query="$4"
    local database="${5:-}"

    local cmd="export DB_HOST=$MARIADB_HOST DB_USER='$mysql_user' DB_QUERY='$query'"
    cmd+=" && export DB_PASSWORD=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    [[ -n "$database" ]] && cmd+=" && export DB_DATABASE='$database'"

    case "$sdk" in
        pymysql) cmd+=" && python3 $SCRIPTS_DIR/pymysql_test.py" ;;
        go)      cmd+=" && $SCRIPTS_DIR/go_mysql_test" ;;
        node)    cmd+=" && cd $SCRIPTS_DIR && node node_mysql_test.js" ;;
        java)    cmd+=" && java -cp '$SCRIPTS_DIR:/usr/share/java/mariadb-java-client.jar' MariaDBTest" ;;
        *) echo "Unknown SDK: $sdk"; return 1 ;;
    esac

    case "$pod" in
        user1) kexec_user1 "$cmd" ;;
        user2) kexec_user2 "$cmd" ;;
        *) echo "Unknown pod: $pod"; return 1 ;;
    esac
}

# Run an SDK test script with an explicit token (for negative tests)
# Usage: sdk_with_token <sdk> <pod: user1|user2> <mysql_user> <token> <query>
sdk_with_token() {
    local sdk="$1"
    local pod="$2"
    local mysql_user="$3"
    local token="$4"
    local query="$5"

    local cmd="export DB_HOST=$MARIADB_HOST DB_USER='$mysql_user' DB_PASSWORD='$token' DB_QUERY='$query'"

    case "$sdk" in
        pymysql) cmd+=" && python3 $SCRIPTS_DIR/pymysql_test.py" ;;
        go)      cmd+=" && $SCRIPTS_DIR/go_mysql_test" ;;
        node)    cmd+=" && cd $SCRIPTS_DIR && node node_mysql_test.js" ;;
        java)    cmd+=" && java -cp '$SCRIPTS_DIR:/usr/share/java/mariadb-java-client.jar' MariaDBTest" ;;
        *) echo "Unknown SDK: $sdk"; return 1 ;;
    esac

    case "$pod" in
        user1) kexec_user1 "$cmd" ;;
        user2) kexec_user2 "$cmd" ;;
        *) echo "Unknown pod: $pod"; return 1 ;;
    esac
}
