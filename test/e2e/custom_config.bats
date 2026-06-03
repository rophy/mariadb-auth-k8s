#!/usr/bin/env bats
# Tests for custom auth_k8s plugin configuration via Helm chart

RELEASE_CUSTOM_URL="mariadb-custom-url"
RELEASE_BAD_URL="mariadb-bad-url"
RELEASE_BAD_TOKEN="mariadb-bad-token"

setup_file() {
    load test_helper
    wait_for_mariadb

    helm_install "$RELEASE_CUSTOM_URL" \
        --set auth_k8s.api_url=https://kubernetes.default.svc.cluster.local

    helm_install "$RELEASE_BAD_URL" \
        --set auth_k8s.api_url=https://invalid-api-server.nonexistent:6443 \
        --set auth_k8s.timeout=3

    helm_install "$RELEASE_BAD_TOKEN" \
        --set auth_k8s.token_path=/tmp/nonexistent-token
}

teardown_file() {
    load test_helper
    helm_uninstall "$RELEASE_CUSTOM_URL"
    helm_uninstall "$RELEASE_BAD_URL"
    helm_uninstall "$RELEASE_BAD_TOKEN"
}

setup() {
    load test_helper
}

# --- Verify custom config variables are set correctly ---

@test "custom-config: custom-url has explicit api_url" {
    run mysql_root_on "$RELEASE_CUSTOM_URL" "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_api_url'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"kubernetes.default.svc.cluster.local"* ]]
}

@test "custom-config: bad-url has invalid api_url" {
    run mysql_root_on "$RELEASE_BAD_URL" "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_api_url'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"invalid-api-server.nonexistent"* ]]
}

@test "custom-config: bad-url has reduced timeout" {
    run mysql_root_on "$RELEASE_BAD_URL" "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_timeout'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"3"* ]]
}

@test "custom-config: bad-token has nonexistent token_path" {
    run mysql_root_on "$RELEASE_BAD_TOKEN" "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_token_path'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/tmp/nonexistent-token"* ]]
}

# --- Positive: custom api_url works when pointing to valid endpoint ---

@test "custom-config: auth succeeds with custom api_url" {
    run mysql_query_host "$RELEASE_CUSTOM_URL" "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "custom-config: SELECT USER() correct with custom api_url" {
    run mysql_query_host "$RELEASE_CUSTOM_URL" "$NAMESPACE/user1" "SELECT USER()"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"mariadb-auth-test/user1"* ]]
}

# --- Negative: bad api_url rejects auth ---

@test "custom-config: auth fails with unreachable api_url" {
    run mysql_query_host "$RELEASE_BAD_URL" "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -ne 0 ]]
}

# --- Negative: bad token_path rejects auth ---

@test "custom-config: auth fails with nonexistent token_path" {
    run mysql_query_host "$RELEASE_BAD_TOKEN" "$NAMESPACE/user1" "SELECT 1"
    [[ "$status" -ne 0 ]]
}

# --- Verify bad config doesn't crash the server ---

@test "custom-config: bad-url server still accepts root connections" {
    run mysql_root_on "$RELEASE_BAD_URL" "SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "custom-config: bad-token server still accepts root connections" {
    run mysql_root_on "$RELEASE_BAD_TOKEN" "SELECT 1"
    [[ "$status" -eq 0 ]]
}
