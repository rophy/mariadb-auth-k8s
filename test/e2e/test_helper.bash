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
    ka exec deployment/mariadb -- bash -c "\$(command -v mysql 2>/dev/null || command -v mariadb) -u root --skip-ssl -e \"$query\""
}

# Run mysql as root on a specific MariaDB deployment
mysql_root_on() {
    local deployment="$1"
    local query="$2"
    ka exec "deployment/$deployment" -- bash -c "\$(command -v mysql 2>/dev/null || command -v mariadb) -u root --skip-ssl -e \"$query\""
}

# Run mysql auth query against a specific MariaDB host from client-user1
mysql_query_host() {
    local host="$1"
    local mysql_user="$2"
    local query="$3"
    kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $host -u '$mysql_user' -p\"\$SA_TOKEN\" -e '$query'"
}

# Wait for a specific MariaDB service to be reachable
wait_for_mariadb_host() {
    local host="$1"
    local attempts="${2:-60}"
    local i=0
    echo "# Waiting for $host to be ready (${attempts}s timeout)..." >&3
    while [[ $i -lt $attempts ]]; do
        if kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
            exec deployment/client-user1 -- mysqladmin -h "$host" ping &>/dev/null; then
            echo "# $host is ready (after ${i}s)" >&3
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "# $host did not become ready within ${attempts}s" >&3
    return 1
}

# Helm chart path (relative to repo root)
HELM_CHART_DIR="${BATS_TEST_DIRNAME}/../../helm/mariadb-auth-k8s"

# Resolve the mariadb-server image tag from the running deployment
_mariadb_image() {
    ka get deployment/mariadb -o jsonpath='{.spec.template.spec.containers[0].image}'
}

# Install a MariaDB instance via Helm chart
# Usage: helm_install <release-name> [--set key=val ...]
helm_install() {
    local release="$1"; shift
    local image
    image=$(_mariadb_image)
    echo "# helm install $release (image=$image) ..." >&3
    helm install "$release" "$HELM_CHART_DIR" \
        --namespace "$NAMESPACE" \
        --kube-context "$KUBE_CONTEXT" \
        --set "image.repository=${image%%:*}" \
        --set "image.tag=${image#*:}" \
        "$@" 2>&3
    wait_for_mariadb_host "$release"
}

# Uninstall a Helm release
helm_uninstall() {
    local release="$1"
    echo "# helm uninstall $release ..." >&3
    helm uninstall "$release" \
        --namespace "$NAMESPACE" \
        --kube-context "$KUBE_CONTEXT" 2>&3 || true
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
