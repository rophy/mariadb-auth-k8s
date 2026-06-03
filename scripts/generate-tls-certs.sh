#!/bin/bash
# Generate self-signed TLS certificates for MariaDB and store as a K8s Secret.
# Idempotent: skips if the Secret already exists.

set -eo pipefail

NAMESPACE="${NAMESPACE:-mariadb-auth-test}"
SECRET_NAME="mariadb-tls"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-cluster-a}"
KUBECTL="kubectl --context $KUBE_CONTEXT"

if $KUBECTL -n "$NAMESPACE" get secret "$SECRET_NAME" &>/dev/null; then
    echo "TLS secret '$SECRET_NAME' already exists, skipping cert generation"
    exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Generating TLS certificates..."

# CA
openssl genrsa -out "$TMPDIR/ca-key.pem" 2048 2>/dev/null
openssl req -new -x509 -key "$TMPDIR/ca-key.pem" -out "$TMPDIR/ca.pem" \
    -days 3650 -subj "/CN=MariaDB Test CA" 2>/dev/null

# Server cert with SANs for K8s service names
cat > "$TMPDIR/san.cnf" <<EOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
CN = mariadb

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = mariadb
DNS.2 = mariadb.mariadb-auth-test.svc
DNS.3 = mariadb.mariadb-auth-test.svc.cluster.local
DNS.4 = localhost
EOF

openssl genrsa -out "$TMPDIR/server-key.pem" 2048 2>/dev/null
openssl req -new -key "$TMPDIR/server-key.pem" -out "$TMPDIR/server.csr" \
    -config "$TMPDIR/san.cnf" 2>/dev/null
openssl x509 -req -in "$TMPDIR/server.csr" -CA "$TMPDIR/ca.pem" -CAkey "$TMPDIR/ca-key.pem" \
    -CAcreateserial -out "$TMPDIR/server-cert.pem" -days 3650 \
    -extensions v3_req -extfile "$TMPDIR/san.cnf" 2>/dev/null

$KUBECTL -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-file=ca.pem="$TMPDIR/ca.pem" \
    --from-file=server-cert.pem="$TMPDIR/server-cert.pem" \
    --from-file=server-key.pem="$TMPDIR/server-key.pem"

echo "TLS secret '$SECRET_NAME' created"
