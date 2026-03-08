# Shared helpers for BATS e2e tests

KUBE_CONTEXT="kind-cluster-a"
NAMESPACE="mariadb-auth-test"
MARIADB_HOST="mariadb"

# kubectl wrapper with context + namespace
ka() {
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"
}

# Exec into test client pods
kexec_user1() {
    ka exec deployment/client-user1 -- bash -c "$1"
}

kexec_user2() {
    ka exec deployment/client-user2 -- bash -c "$1"
}

# Read projected SA tokens from pods
get_token_user1() {
    kexec_user1 'cat /var/run/secrets/kubernetes.io/serviceaccount/token'
}

get_token_user2() {
    kexec_user2 'cat /var/run/secrets/kubernetes.io/serviceaccount/token'
}

# Run mysql query in a test pod with given user and token
# Usage: mysql_query <pod: user1|user2> <mysql_user> <query>
# Token is read from the pod's projected SA token
mysql_query() {
    local pod="$1"
    local mysql_user="$2"
    local query="$3"

    case "$pod" in
        user1) kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$mysql_user' -p\"\$SA_TOKEN\" -e '$query'" ;;
        user2) kexec_user2 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$mysql_user' -p\"\$SA_TOKEN\" -e '$query'" ;;
        *) echo "Unknown pod: $pod"; return 1 ;;
    esac
}

# Run mysql with an explicit token (for negative tests)
# Usage: mysql_with_token <pod: user1|user2> <mysql_user> <token> <query>
mysql_with_token() {
    local pod="$1"
    local mysql_user="$2"
    local token="$3"
    local query="$4"

    case "$pod" in
        user1) kexec_user1 "mysql -h $MARIADB_HOST -u '$mysql_user' -p'$token' -e '$query'" ;;
        user2) kexec_user2 "mysql -h $MARIADB_HOST -u '$mysql_user' -p'$token' -e '$query'" ;;
        *) echo "Unknown pod: $pod"; return 1 ;;
    esac
}

# Run mysql as root on the MariaDB pod (for checking server config)
mysql_root() {
    local query="$1"
    ka exec deployment/mariadb -- mysql -u root -e "$query"
}

# Wait for MariaDB to be ready (30s timeout)
wait_for_mariadb() {
    local attempts=30
    local i=0
    echo "# Waiting for MariaDB to be ready..." >&3
    while (( i < attempts )); do
        if kexec_user1 "mysqladmin -h $MARIADB_HOST ping" &>/dev/null; then
            echo "# MariaDB is ready" >&3
            return 0
        fi
        sleep 1
        (( i++ ))
    done
    echo "# MariaDB did not become ready within ${attempts}s" >&3
    return 1
}
