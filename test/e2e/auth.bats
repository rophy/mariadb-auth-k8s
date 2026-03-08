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

