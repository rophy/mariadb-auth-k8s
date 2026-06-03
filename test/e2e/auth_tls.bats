#!/usr/bin/env bats
# TLS authentication tests — verify all SDKs work over encrypted connections

setup_file() {
    load sdk_helper
    wait_for_mariadb
}

setup() {
    load sdk_helper
}

# --- Verify MariaDB has TLS enabled ---

@test "tls: MariaDB server has SSL enabled" {
    run mysql_root "SHOW VARIABLES LIKE 'have_ssl'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"YES"* ]]
}

# --- New SDKs over TLS ---

@test "tls-pymysql-new: authenticates over TLS" {
    run sdk_query_tls pymysql user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-go-new: authenticates over TLS" {
    run sdk_query_tls go user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-node-new: authenticates over TLS" {
    run sdk_query_tls node user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-java-new: authenticates over TLS (Connector/J 2.x)" {
    run sdk_query_tls java user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-java3-new: authenticates over TLS (Connector/J 3.x)" {
    run sdk_query_tls java3 user1 "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

# --- Old SDKs over TLS ---

@test "tls-pymysql-old: authenticates over TLS" {
    run sdk_query_tls pymysql user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-go-old: authenticates over TLS" {
    run sdk_query_tls go user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-node-old: authenticates over TLS" {
    run sdk_query_tls node user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "tls-java-old: authenticates over TLS (Connector/J 2.x)" {
    run sdk_query_tls java user1-old "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

# --- TLS identity verification ---

@test "tls-pymysql-new: SELECT USER() returns correct identity" {
    run sdk_query_tls pymysql user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

@test "tls-java3-new: SELECT USER() returns correct identity (Connector/J 3.x)" {
    run sdk_query_tls java3 user1 "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

# --- TLS with database name ---

@test "tls-java3-new: auth with database name (Connector/J 3.x)" {
    run sdk_query_tls java3 user1 "$NAMESPACE/user1" "SELECT 1" "testdb"
    [[ "$status" -eq 0 ]]
}
