#!/usr/bin/env bats

setup_file() {
    load sdk_helper
    wait_for_mariadb
}

setup() {
    load sdk_helper
}

# --- NEW SDK (go-sql-driver latest) ---

@test "go-new: user1 authenticates with valid token" {
    run sdk_query go user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "go-new: SELECT USER() returns correct identity" {
    run sdk_query go user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "go-new: auth with database name specified" {
    run sdk_query go user1 "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "go-new: invalid token is rejected" {
    run sdk_with_token go user1 "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

# --- OLD SDK (go-sql-driver 1.5.0) ---

@test "go-old: user1 authenticates with valid token" {
    run sdk_query go user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "go-old: SELECT USER() returns correct identity" {
    run sdk_query go user1-old "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "go-old: auth with database name specified" {
    run sdk_query go user1-old "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "go-old: invalid token is rejected" {
    run sdk_with_token go user1-old "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}
