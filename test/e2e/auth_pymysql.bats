#!/usr/bin/env bats

setup_file() {
    load sdk_helper
    wait_for_mariadb
}

setup() {
    load sdk_helper
}

# --- NEW SDK (latest PyMySQL) ---

@test "pymysql-new: user1 authenticates with valid token" {
    run sdk_query pymysql user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "pymysql-new: SELECT USER() returns correct identity" {
    run sdk_query pymysql user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "pymysql-new: auth with database name specified" {
    run sdk_query pymysql user1 "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "pymysql-new: invalid token is rejected" {
    run sdk_with_token pymysql user1 "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}

# --- OLD SDK (PyMySQL 0.9.3) ---

@test "pymysql-old: user1 authenticates with valid token" {
    run sdk_query pymysql user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "pymysql-old: SELECT USER() returns correct identity" {
    run sdk_query pymysql user1-old "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "pymysql-old: auth with database name specified" {
    run sdk_query pymysql user1-old "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}

@test "pymysql-old: invalid token is rejected" {
    run sdk_with_token pymysql user1-old "$NAMESPACE/user1" "invalid-token" "SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}
