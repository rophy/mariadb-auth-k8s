#!/usr/bin/env bats

setup_file() {
    load sdk_helper
    wait_for_mariadb
}

setup() {
    load sdk_helper
}

@test "java: user1 authenticates with valid token" {
    run sdk_query java user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "java: SELECT USER() returns correct identity" {
    run sdk_query java user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "java: auth with database name specified" {
    run sdk_query java user1 "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "java: invalid token is rejected" {
    run sdk_with_token java user1 "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}
