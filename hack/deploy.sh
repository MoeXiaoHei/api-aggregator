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

# 8. 给白名单节点打标签
print_header "🏷️  Labeling Allowed Nodes for Scheduler"
ALLOWED_NODES=$(kubectl get deployment api-aggregator -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args[0]}' 2>/dev/null | sed 's/--allowed-nodes=//' || echo "node01,node02,node03")
print_info "Allowed nodes from config: ${ALLOWED_NODES}"

IFS=',' read -ra NODE_ARRAY <<< "$ALLOWED_NODES"
for node in "${NODE_ARRAY[@]}"; do
    node=$(echo "$node" | xargs)
    if [ -n "$node" ]; then
        if kubectl label node "$node" node-group=allowed --overwrite 2>/dev/null; then
            print_success "Node '$node' labeled with node-group=allowed"
        else
            print_warning "Node '$node' not found or cannot be labeled"
        fi
    fi
done

# 9. 获取 Token（从 kube-system 获取 api-aggregator 的 Token）
print_header "🎫 Getting ServiceAccount Token"
SA_SECRET=$(kubectl get serviceaccount api-aggregator -n kube-system -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
if [ -n "$SA_SECRET" ]; then
    TOKEN=$(kubectl get secret ${SA_SECRET} -n kube-system -o jsonpath='{.data.token}' | base64 -d)
    print_success "Token retrieved successfully"
else
    print_warning "Creating token for api-aggregator..."
    kubectl delete secret api-aggregator-token -n kube-system --ignore-not-found=true
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: api-aggregator-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: api-aggregator
type: kubernetes.io/service-account-token
EOF
    sleep 2
    TOKEN=$(kubectl get secret api-aggregator-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
    print_success "Token created and retrieved"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Deployment complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}🔑 ServiceAccount Token:${NC}"
echo -e "${GREEN}${TOKEN}${NC}"
echo ""
echo -e "${BLUE}📊 Deployment Info:${NC}"
kubectl get pods -n kube-system -l app=api-aggregator
echo ""
echo -e "${BLUE}📝 Manual test commands:${NC}"
echo -e "${YELLOW}  # List pods (only from allowed nodes)${NC}"
echo -e "  curl -k -H \"Authorization: Bearer ${TOKEN}\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods"
echo ""
echo -e "${YELLOW}  # Create a pod WITHOUT nodeName (scheduler will choose)${NC}"
echo -e "  curl -k -X POST -H \"Authorization: Bearer ${TOKEN}\" -H \"Content-Type: application/json\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods -d '{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"my-pod\"},\"spec\":{\"containers\":[{\"name\":\"nginx\",\"image\":\"nginx:latest\"}]}}'"
echo ""
echo -e "${YELLOW}  # Create a pod with nodeName (must be in whitelist)${NC}"
echo -e "  curl -k -X POST -H \"Authorization: Bearer ${TOKEN}\" -H \"Content-Type: application/json\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods -d '{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"my-pod\"},\"spec\":{\"nodeName\":\"node01\",\"containers\":[{\"name\":\"nginx\",\"image\":\"nginx:latest\"}]}}'"
echo ""
echo -e "${YELLOW}  # Delete a pod${NC}"
echo -e "  curl -k -X DELETE -H \"Authorization: Bearer ${TOKEN}\" https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods/my-pod"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 All done!${NC}"
echo -e "${GREEN}========================================${NC}"