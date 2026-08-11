#!/bin/bash
set -e

echo "📜 Generating TLS certificates..."

mkdir -p certs
cd certs

# 生成 CA
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 365 -key ca.key -out ca.crt -subj "/CN=api-aggregator-ca"

# 生成服务证书
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -out tls.csr -subj "/CN=api-aggregator.kube-system.svc"

cat > tls.conf <<EOF
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = api-aggregator
DNS.2 = api-aggregator.kube-system
DNS.3 = api-aggregator.kube-system.svc
DNS.4 = api-aggregator.kube-system.svc.cluster.local
EOF

openssl x509 -req -days 365 -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -extensions v3_req -extfile tls.conf

cd ..
echo "✅ Certificates generated successfully!"
echo ""
echo "CA Certificate (base64):"
cat certs/ca.crt | base64 | tr -d '\n'
echo ""
