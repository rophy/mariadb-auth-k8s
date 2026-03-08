#!/usr/bin/env bats

setup_file() {
    load test_helper
    wait_for_mariadb
}

setup() {
    load test_helper
}

@test "user1 has full privileges (can query mysql db)" {
    run mysql_query "user1" "$NAMESPACE/user1" "SELECT user FROM mysql.user LIMIT 1"
    [[ "$status" -eq 0 ]]
}

@test "user2 can access testdb" {
    run mysql_query "user2" "$NAMESPACE/user2" "USE testdb; SELECT 1"
    [[ "$status" -eq 0 ]]
}

@test "user2 is denied access to mysql database" {
    run mysql_query "user2" "$NAMESPACE/user2" "USE mysql; SELECT 1"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Access denied"* ]]
}
