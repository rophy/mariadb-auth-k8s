#!/usr/bin/env bats

setup_file() {
    load test_helper
    wait_for_mariadb
}

setup() {
    load test_helper
}

@test "auth_k8s plugin is loaded" {
    run mysql_root "SHOW PLUGINS"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"auth_k8s"* ]]
}

@test "auth_k8s_api_url is set" {
    run mysql_root "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_api_url'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"https://kubernetes.default.svc"* ]]
}

@test "auth_k8s_token_path points to tokenreviewer" {
    run mysql_root "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_token_path'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/var/run/secrets/tokenreviewer/token"* ]]
}

@test "auth_k8s_ca_path points to tokenreviewer" {
    run mysql_root "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_ca_path'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"/var/run/secrets/tokenreviewer/ca.crt"* ]]
}

@test "auth_k8s_timeout has default value" {
    run mysql_root "SHOW GLOBAL VARIABLES LIKE 'auth_k8s_timeout'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"10"* ]]
}

@test "auth_k8s_timeout is read-only" {
    run mysql_root "SET GLOBAL auth_k8s_timeout = 30"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"read only"* ]]
}
