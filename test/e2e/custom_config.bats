#!/usr/bin/env bats
# Tests for custom auth_k8s plugin configuration (api_url, token_path, ca_path)

setup_file() {
    load test_helper
    wait_for_mariadb
    wait_for_mariadb_deployment mariadb-custom-url mariadb-custom-url
    wait_for_mariadb_deployment mariadb-bad-url mariadb-bad-url
    wait_for_mariadb_deployment mariadb-bad-token mariadb-bad-token
}

setup() {
    load test_helper
}

# --- Verify custom config variables are set correctly ---

@test "custom-config: custom-url has explicit api_url" {
    run mysql_root_on mariadb-custom-url "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_api_url'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"kubernetes.default.svc.cluster.local"* ]]
}

@test "custom-config: bad-url has invalid api_url" {
    run mysql_root_on mariadb-bad-url "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_api_url'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"invalid-api-server.nonexistent"* ]]
}

@test "custom-config: bad-url has reduced timeout" {
    run mysql_root_on mariadb-bad-url "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_timeout'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"3"* ]]
}

@test "custom-config: bad-token has nonexistent token_path" {
    run mysql_root_on mariadb-bad-token "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_token_path'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/tmp/nonexistent-token"* ]]
}

# --- Positive: custom api_url works when pointing to valid endpoint ---

@test "custom-config: auth succeeds with custom api_url" {
    run mysql_query_host mariadb-custom-url "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "custom-config: SELECT USER() correct with custom api_url" {
    run mysql_query_host mariadb-custom-url "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

# --- Negative: bad api_url rejects auth ---

@test "custom-config: auth fails with unreachable api_url" {
    run mysql_query_host mariadb-bad-url "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -ne 0 ]]
}

# --- Negative: bad token_path rejects auth ---

@test "custom-config: auth fails with nonexistent token_path" {
    run mysql_query_host mariadb-bad-token "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -ne 0 ]]
}

# --- Verify bad config doesn't crash the server ---

@test "custom-config: bad-url server still accepts root connections" {
    run mysql_root_on mariadb-bad-url "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "custom-config: bad-token server still accepts root connections" {
    run mysql_root_on mariadb-bad-token "SELECT 1"
    [[ "$status" -eq 0 ]]
}
