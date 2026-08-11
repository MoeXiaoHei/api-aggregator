#!/bin/bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🚀 Deploying API Aggregator${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. 生成证书
print_header "📜 Generating certificates..."
./hack/generate-certs.sh

# 2. 创建 TLS Secret
print_header "🔑 Creating TLS Secret..."
kubectl create secret tls api-aggregator-tls \
  --cert=certs/tls.crt \
  --key=certs/tls.key \
  -n kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. 部署 RBAC
print_header "🛡️  Deploying RBAC..."
kubectl apply -f manifests/rbac.yaml

# 4. 部署 Deployment
print_header "🚀 Deploying Deployment..."
kubectl apply -f manifests/deployment.yaml

# 5. 部署 Service
print_header "🌐 Deploying Service..."
kubectl apply -f manifests/service.yaml

# 6. 等待 Deployment 就绪
print_header "⏳ Waiting for Deployment to be ready..."
kubectl wait --for=condition=ready pod -l app=api-aggregator -n kube-system --timeout=120s

# 7. 创建 APIService
print_header "📋 Creating APIService..."
CA_BUNDLE=$(cat certs/ca.crt | base64 | tr -d '\n')
cat manifests/apiservice.yaml | sed "s/<BASE64_ENCODED_CA_CERT>/${CA_BUNDLE}/g" | kubectl apply -f -

# 8. 创建命名空间和 ServiceAccount
print_header "🔐 Creating ServiceAccount..."
kubectl create namespace my-namespace --dry-run=client -o yaml | kubectl apply -f -

# 创建 ServiceAccount
kubectl create serviceaccount multi-node-operator-sa -n my-namespace --dry-run=client -o yaml | kubectl apply -f -

# 创建 Token Secret (Kubernetes 1.24+)
cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: Secret
metadata:
  name: multi-node-operator-sa-token
  namespace: my-namespace
  annotations:
    kubernetes.io/service-account.name: multi-node-operator-sa
type: kubernetes.io/service-account-token
EOF

# 获取 Token
sleep 2
SA_SECRET=$(kubectl get serviceaccount multi-node-operator-sa -n my-namespace -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
if [ -n "$SA_SECRET" ]; then
    TOKEN=$(kubectl get secret ${SA_SECRET} -n my-namespace -o jsonpath='{.data.token}' | base64 -d)
else
    print_warning "Failed to get token, creating new one..."
    kubectl delete secret multi-node-operator-sa-token -n my-namespace --ignore-not-found=true
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: multi-node-operator-sa-token
  namespace: my-namespace
  annotations:
    kubernetes.io/service-account.name: multi-node-operator-sa
type: kubernetes.io/service-account-token
EOF
    sleep 2
    TOKEN=$(kubectl get secret multi-node-operator-sa-token -n my-namespace -o jsonpath='{.data.token}' | base64 -d)
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Deployment complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}🔑 ServiceAccount Token:${NC}"
echo -e "${GREEN}${TOKEN}${NC}"
echo ""

# ============================================
# 测试部分
# ============================================
print_header "🧪 Running Tests"

# 测试函数
test_api() {
    local name=$1
    local method=$2
    local endpoint=$3
    local data=$4
    local expected=$5
    
    echo -e "\n${YELLOW}📌 Test: ${name}${NC}"
    
    if [ "$method" == "GET" ]; then
        RESPONSE=$(curl -k -s -w "\n%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
            "https://api-aggregator.kube-system.svc${endpoint}")
    else
        RESPONSE=$(curl -k -s -w "\n%{http_code}" -X ${method} \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "https://api-aggregator.kube-system.svc${endpoint}")
    fi
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" == "$expected" ] || [ "$HTTP_CODE" == "200" ] && [ "$expected" == "200/201" ]; then
        print_success "Test passed (HTTP ${HTTP_CODE})"
        echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
        return 0
    else
        print_error "Test failed (HTTP ${HTTP_CODE}, expected ${expected})"
        echo "$BODY"
        return 1
    fi
}

# 测试 1: 健康检查
print_header "📊 Test 1: Health Check"
kubectl get pods -n kube-system -l app=api-aggregator
echo ""
kubectl logs -n kube-system -l app=api-aggregator --tail=10

# 测试 2: 查询 Pod（应该返回空列表或正常响应）
print_header "📊 Test 2: List Pods (API Aggregator)"
test_api "List Pods" "GET" "/api/v1/namespaces/default/pods" "" "200"

# 测试 3: 创建 Pod（不指定 nodeName - 应该失败）
print_header "📊 Test 3: Create Pod without nodeName (Should fail)"
test_api "Create Pod (no nodeName)" "POST" "/api/v1/namespaces/default/pods" \
    '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"test-no-node"},"spec":{"containers":[{"name":"nginx","image":"nginx:latest"}]}}' \
    "400"

# 测试 4: 创建 Pod（指定非白名单节点 - 应该失败）
print_header "📊 Test 4: Create Pod on non-allowed node (Should fail)"
test_api "Create Pod (non-allowed node)" "POST" "/api/v1/namespaces/default/pods" \
    '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"test-denied"},"spec":{"nodeName":"node-03","containers":[{"name":"nginx","image":"nginx:latest"}]}}' \
    "403"

# 测试 5: 创建 Pod（指定白名单节点 - 应该成功）
print_header "📊 Test 5: Create Pod on allowed node (Should succeed)"
test_api "Create Pod (allowed node)" "POST" "/api/v1/namespaces/default/pods" \
    '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"test-allowed"},"spec":{"nodeName":"hadoop02","containers":[{"name":"nginx","image":"nginx:latest"}]}}' \
    "201"

# 测试 6: 查询刚创建的 Pod
print_header "📊 Test 6: Get created Pod"
test_api "Get Pod" "GET" "/api/v1/namespaces/default/pods/test-allowed" "" "200"

# 测试 7: 删除刚创建的 Pod
print_header "📊 Test 7: Delete Pod"
test_api "Delete Pod" "DELETE" "/api/v1/namespaces/default/pods/test-allowed" "" "200"

# 测试 8: 验证 Pod 已删除
print_header "📊 Test 8: Verify Pod deleted"
sleep 2
test_api "Verify Pod deleted" "GET" "/api/v1/namespaces/default/pods/test-allowed" "" "404"

# 测试 9: 查看白名单节点上的 Pod（使用 field-selector）
print_header "📊 Test 9: List Pods with field-selector"
curl -k -s -H "Authorization: Bearer ${TOKEN}" \
    "https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods?fieldSelector=spec.nodeName=hadoop02" | jq '.items[] | {name: .metadata.name, node: .spec.nodeName}' 2>/dev/null || echo "No pods on hadoop02"

# 测试 10: 查看所有命名空间的 Pod
print_header "📊 Test 10: List Pods in all namespaces"
curl -k -s -H "Authorization: Bearer ${TOKEN}" \
    "https://api-aggregator.kube-system.svc/api/v1/pods" | jq '.items[] | {name: .metadata.name, namespace: .metadata.namespace, node: .spec.nodeName}' 2>/dev/null | head -20

# 测试 11: 创建第二个 Pod 在另一个白名单节点
print_header "📊 Test 11: Create Pod on another allowed node"
test_api "Create Pod (example.com227)" "POST" "/api/v1/namespaces/default/pods" \
    '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"test-allowed-2"},"spec":{"nodeName":"example.com227","containers":[{"name":"nginx","image":"nginx:latest"}]}}' \
    "201"

# 清理测试 Pod
print_header "🧹 Cleaning up test pods"
kubectl delete pod test-allowed-2 -n default --ignore-not-found=true 2>/dev/null || true

# 测试总结
print_header "📊 Test Summary"
echo -e "${GREEN}✅ All tests completed!${NC}"
echo ""
echo -e "${BLUE}📝 Manual test commands:${NC}"
echo -e "${YELLOW}  # List pods (only from allowed nodes)${NC}"
echo -e "  curl -k -H \"Authorization: Bearer ${TOKEN}\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods | jq ."
echo ""
echo -e "${YELLOW}  # Create a pod on allowed node${NC}"
echo -e "  curl -k -X POST -H \"Authorization: Bearer ${TOKEN}\" -H \"Content-Type: application/json\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods -d '{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"my-pod\"},\"spec\":{\"nodeName\":\"hadoop02\",\"containers\":[{\"name\":\"nginx\",\"image\":\"nginx:latest\"}]}}' | jq ."
echo ""
echo -e "${YELLOW}  # Delete a pod${NC}"
echo -e "  curl -k -X DELETE -H \"Authorization: Bearer ${TOKEN}\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods/my-pod"
echo ""
echo -e "${YELLOW}  # Use kubectl with aggregator${NC}"
echo -e "  kubectl config set-cluster aggregator --server=https://api-aggregator.kube-system.svc --insecure-skip-tls-verify=true"
echo -e "  kubectl config set-credentials aggregator-user --token=${TOKEN}"
echo -e "  kubectl config set-context aggregator --cluster=aggregator --user=aggregator-user --namespace=default"
echo -e "  kubectl config use-context aggregator"
echo -e "  kubectl get pods"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 All done!${NC}"
echo -e "${GREEN}========================================${NC}"
