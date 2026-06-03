#!/usr/bin/env bats

setup_file() {
    load sdk_helper
    wait_for_mariadb
}

setup() {
    load sdk_helper
}

# --- NEW SDK (MariaDB Connector/J 3.x) ---

@test "java-new: user1 authenticates with valid token" {
    run sdk_query java user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "java-new: SELECT USER() returns correct identity" {
    run sdk_query java user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "java-new: auth with database name specified" {
    run sdk_query java user1 "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "java-new: invalid token is rejected" {
    run sdk_with_token java user1 "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

# --- OLD SDK (MariaDB Connector/J 2.7.6) ---

@test "java-old: user1 authenticates with valid token" {
    run sdk_query java user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "java-old: SELECT USER() returns correct identity" {
    run sdk_query java user1-old "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "java-old: auth with database name specified" {
    run sdk_query java user1-old "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "java-old: invalid token is rejected" {
    run sdk_with_token java user1-old "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}
