#!/bin/bash
set -e

echo "📜 Generating TLS certificates..."

# ============================================================
# 自动获取节点信息
# ============================================================

# 获取主机名
NODE_HOSTNAME=$(hostname)

# 方法1：通过默认路由获取主网卡 IP
NODE_IP=$(ip -4 route get 1 2>/dev/null | awk '{print $7}' | head -1)

# 如果方法1获取失败，用方法2：从 kubectl 获取
if [ -z "$NODE_IP" ]; then
    echo "   Method 1 failed, trying kubectl..."
    NODE_IP=$(kubectl get node ${NODE_HOSTNAME} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
fi

# 如果还是获取失败，报错
if [ -z "$NODE_IP" ]; then
    echo "❌ Failed to get node IP"
    echo "   Please set NODE_IP manually"
    exit 1
fi

echo "   Node Hostname: ${NODE_HOSTNAME}"
echo "   Node IP: ${NODE_IP}"

# ============================================================
# 生成证书
# ============================================================
mkdir -p certs
cd certs

# 生成 CA
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=api-aggregator-ca"

# 生成服务证书
openssl genrsa -out tls.key 2048

# 动态生成 OpenSSL 配置
cat > tls.conf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = api-aggregator.kube-system.svc

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = api-aggregator
DNS.2 = api-aggregator.kube-system
DNS.3 = api-aggregator.kube-system.svc
DNS.4 = api-aggregator.kube-system.svc.cluster.local
DNS.5 = localhost
DNS.6 = ${NODE_HOSTNAME}
IP.1 = 127.0.0.1
IP.2 = ${NODE_IP}
EOF

openssl req -new -key tls.key -out tls.csr -config tls.conf
openssl x509 -req -days 3650 -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -extensions v3_req -extfile tls.conf

cd ..

echo "✅ Certificates generated successfully!"
echo ""
echo "📊 Certificate Info:"
echo "   Node Hostname: ${NODE_HOSTNAME}"
echo "   Node IP: ${NODE_IP}"
echo "   SAN - DNS: api-aggregator, ..., ${NODE_HOSTNAME}"
echo "   SAN - IP: 127.0.0.1, ${NODE_IP}"
echo ""
echo "CA Certificate (base64):"
cat certs/ca.crt | base64 | tr -d '\n'
echo ""