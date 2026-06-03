#!/usr/bin/env bats

setup_file() {
    load sdk_helper
    wait_for_mariadb
}

setup() {
    load sdk_helper
}

# --- NEW SDK (mysql2 latest) ---

@test "node-new: user1 authenticates with valid token" {
    run sdk_query node user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "node-new: SELECT USER() returns correct identity" {
    run sdk_query node user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "node-new: auth with database name specified" {
    run sdk_query node user1 "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "node-new: invalid token is rejected" {
    run sdk_with_token node user1 "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

# --- OLD SDK (mysql2 2.0.0) ---

@test "node-old: user1 authenticates with valid token" {
    run sdk_query node user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "node-old: SELECT USER() returns correct identity" {
    run sdk_query node user1-old "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "node-old: auth with database name specified" {
    run sdk_query node user1-old "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "node-old: invalid token is rejected" {
    run sdk_with_token node user1-old "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}
