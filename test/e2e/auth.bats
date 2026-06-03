#!/usr/bin/env bats

setup_file() {
    load test_helper
    wait_for_mariadb
}

setup() {
    load test_helper
}

@test "user1 authenticates with valid token" {
    run mysql_query "user1" "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "user1 SELECT USER() returns correct identity" {
    run mysql_query "user1" "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "invalid token is rejected" {
    run mysql_with_token "user1" "$NAMESPACE/user1" "invalid-token-here" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

@test "empty password is rejected" {
    run mysql_with_token "user1" "$NAMESPACE/user1" "" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

@test "wrong username (user1 token with user2 name) is rejected" {
    run kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$NAMESPACE/user2' -p\"\$SA_TOKEN\" -e 'SELECT 1'"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

@test "user1 authenticates with database name specified" {
    run kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$NAMESPACE/user1' -p\"\$SA_TOKEN\" -D mysql -e 'SELECT 1'"
    [[ "$status" -eq 0 ]]
}

@test "user1 authenticates with database name and default-auth cleartext (MDEV-38431)" {
    run kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$NAMESPACE/user1' -p\"\$SA_TOKEN\" --default-auth=mysql_clear_password -D mysql -e 'SELECT 1'"
    [[ "$status" -eq 0 ]]
}

# Kubernetes enforces a minimum token lifetime of 10 minutes, so we cannot
# create a truly expired token in a fast test. Uncomment and wait 10m+ to test.
# @test "expired token is rejected" {
#     EXPIRED_TOKEN=$(kubectl create token user1 -n "$NAMESPACE" --context "$KUBE_CONTEXT" --duration 10m)
#     sleep 601
#     run mysql_with_token "user1" "$NAMESPACE/user1" "$EXPIRED_TOKEN" "SELECT 1"
#     [[ "$status" -ne 0 ]]
#     [[ "$output" == *"Access denied"* ]]
# }

@test "non-existent MariaDB user is rejected" {
    run kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$NAMESPACE/nonexistent' -p\"\$SA_TOKEN\" -e 'SELECT 1'"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

@test "multiple sequential connections with same token succeed" {
    run kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$NAMESPACE/user1' -p\"\$SA_TOKEN\" -e 'SELECT 1' && mysql -h $MARIADB_HOST -u '$NAMESPACE/user1' -p\"\$SA_TOKEN\" -e 'SELECT 2' && mysql -h $MARIADB_HOST -u '$NAMESPACE/user1' -p\"\$SA_TOKEN\" -e 'SELECT 3'"
    [[ "$status" -eq 0 ]]
}

@test "user2 with database name and default-auth cleartext (MDEV-38431)" {
    run kexec_user2 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u '$NAMESPACE/user2' -p\"\$SA_TOKEN\" --default-auth=mysql_clear_password -D testdb -e 'SELECT 1'"
    [[ "$status" -eq 0 ]]
}

@test "wrong namespace in username is rejected" {
    run kexec_user1 "SA_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mysql -h $MARIADB_HOST -u 'wrong-namespace/user1' -p\"\$SA_TOKEN\" -e 'SELECT 1'"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

@test "random binary garbage as password is rejected" {
    run kexec_user1 "GARBAGE=\$(head -c 256 /dev/urandom | base64 | tr -d '\n') && mysql -h $MARIADB_HOST -u '$NAMESPACE/user1' -p\"\$GARBAGE\" -e 'SELECT 1'"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

