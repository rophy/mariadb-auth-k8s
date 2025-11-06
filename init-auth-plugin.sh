#!/bin/bash
# This script runs in /docker-entrypoint-initdb.d/ after MariaDB is initialized
# by the official MariaDB docker-entrypoint.sh

set -eo pipefail

echo "=== Installing K8s Auth Plugin ==="

# Install plugin and create users
mysql -u root <<EOF
-- Install the K8s auth plugin
INSTALL SONAME 'auth_k8s';

-- Create users for different namespaces/serviceaccounts
-- Format: 'cluster_name/namespace/serviceaccount'@'%'
-- For Token Validator API architecture, cluster name is required

-- User1: Full admin access to all databases
CREATE USER IF NOT EXISTS 'local/mariadb-auth-test/user1'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON *.* TO 'local/mariadb-auth-test/user1'@'%';

-- User2: Limited access to testdb only
CREATE USER IF NOT EXISTS 'local/mariadb-auth-test/user2'@'%' IDENTIFIED VIA auth_k8s;
GRANT ALL PRIVILEGES ON testdb.* TO 'local/mariadb-auth-test/user2'@'%';

-- Create test database
CREATE DATABASE IF NOT EXISTS testdb;

-- Show configuration
SELECT PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY
FROM information_schema.PLUGINS
WHERE PLUGIN_NAME='auth_k8s';

SELECT user, host, plugin FROM mysql.user WHERE plugin='auth_k8s';

FLUSH PRIVILEGES;
EOF

echo "=== K8s Auth Plugin Installed Successfully ==="
