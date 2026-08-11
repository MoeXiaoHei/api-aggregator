#!/bin/bash
set -e

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }

echo -e "${BOLD}${YELLOW}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║           🧹  API Aggregator Cleanup                        ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# 1. 删除 APIService
print_header "📋 Deleting APIService"
if kubectl delete apiservice v1.node-pod.example.com --ignore-not-found=true 2>/dev/null; then
    print_success "APIService deleted"
else
    print_info "APIService not found, skipping"
fi

# 2. 删除 Deployment
print_header "🚀 Deleting Deployment"
if kubectl delete deployment api-aggregator -n kube-system --ignore-not-found=true 2>/dev/null; then
    print_success "Deployment deleted"
else
    print_info "Deployment not found, skipping"
fi

# 3. 删除 Service
print_header "🌐 Deleting Service"
if kubectl delete service api-aggregator -n kube-system --ignore-not-found=true 2>/dev/null; then
    print_success "Service deleted"
else
    print_info "Service not found, skipping"
fi

# 4. 删除 TLS Secret
print_header "🔑 Deleting TLS Secret"
if kubectl delete secret api-aggregator-tls -n kube-system --ignore-not-found=true 2>/dev/null; then
    print_success "TLS Secret deleted"
else
    print_info "TLS Secret not found, skipping"
fi

# 5. 删除 RBAC
print_header "🛡️  Deleting RBAC"
if kubectl delete clusterrolebinding api-aggregator --ignore-not-found=true 2>/dev/null; then
    print_success "ClusterRoleBinding deleted"
else
    print_info "ClusterRoleBinding not found, skipping"
fi

if kubectl delete clusterrole api-aggregator --ignore-not-found=true 2>/dev/null; then
    print_success "ClusterRole deleted"
else
    print_info "ClusterRole not found, skipping"
fi

if kubectl delete serviceaccount api-aggregator -n kube-system --ignore-not-found=true 2>/dev/null; then
    print_success "ServiceAccount deleted"
else
    print_info "ServiceAccount not found, skipping"
fi

# 6. 询问是否删除证书文件
print_header "📜 Certificate Files Cleanup"
echo -e -n "${YELLOW}❓ Do you want to delete the 'certs' directory? (y/N): ${NC}"
read -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if rm -rf certs/ 2>/dev/null; then
        print_success "Certificates deleted!"
    else
        print_warning "Failed to delete certs/ (maybe already deleted)"
    fi
else
    print_info "Certificates preserved at ${WHITE}./certs/${NC}"
fi

# 7. 询问是否删除镜像
print_header "🐳 Docker Image Cleanup"
echo -e -n "${YELLOW}❓ Do you want to delete the Docker image 'oicq/api-aggregator:latest'? (y/N): ${NC}"
read -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if docker rmi oicq/api-aggregator:latest 2>/dev/null; then
        print_success "Docker image deleted!"
    else
        print_warning "Failed to delete Docker image (maybe not exists)"
    fi
else
    print_info "Docker image preserved"
fi

echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅  Cleanup complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}"

echo ""
echo -e "${BOLD}${WHITE}📝 Manual cleanup (if needed):${NC}"
echo -e "${YELLOW}  # Delete the entire project directory${NC}"
echo -e "  cd .. && rm -rf api-aggregator/"
echo ""
echo -e "${YELLOW}  # Delete the Docker image manually${NC}"
echo -e "  docker rmi oicq/api-aggregator:latest"
echo ""
