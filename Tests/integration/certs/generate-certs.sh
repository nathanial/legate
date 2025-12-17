#!/bin/bash
# Generate test certificates for TLS/mTLS testing
# This script generates:
# - ca.crt, ca.key: CA certificate and key
# - server.crt, server.key: Server certificate for localhost
# - client.crt, client.key: Client certificate for mTLS
# - wrong-host.crt, wrong-host.key: Server certificate with wrong hostname (for verification failure tests)

set -e

CERTS_DIR="$(dirname "$0")"
cd "$CERTS_DIR"

# Validity period (10 years)
DAYS=3650

echo "Generating CA certificate..."
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days $DAYS -key ca.key -out ca.crt \
    -subj "/C=US/ST=Test/L=Test/O=LegateTest/CN=LegateTestCA"

echo "Generating server certificate for localhost..."
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
    -subj "/C=US/ST=Test/L=Test/O=LegateTest/CN=localhost"

# Create extension file for SAN (Subject Alternative Name)
cat > server.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl x509 -req -days $DAYS -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -extfile server.ext

echo "Generating client certificate for mTLS..."
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/C=US/ST=Test/L=Test/O=LegateTest/CN=testclient"

cat > client.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

openssl x509 -req -days $DAYS -in client.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out client.crt -extfile client.ext

echo "Generating wrong-hostname certificate for verification failure tests..."
openssl genrsa -out wrong-host.key 2048
openssl req -new -key wrong-host.key -out wrong-host.csr \
    -subj "/C=US/ST=Test/L=Test/O=LegateTest/CN=wronghost.example.com"

cat > wrong-host.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = wronghost.example.com
EOF

openssl x509 -req -days $DAYS -in wrong-host.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out wrong-host.crt -extfile wrong-host.ext

# Cleanup temporary files
rm -f *.csr *.ext ca.srl

echo "Certificates generated successfully!"
echo "Files created:"
ls -la *.crt *.key
