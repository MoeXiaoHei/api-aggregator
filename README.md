# API Aggregator

Kubernetes API 聚合层服务，用于限制 Pod 只能调度到白名单节点，并过滤 `kubectl get pods` 返回结果。

## ✨ 功能特性

- ✅ **节点白名单控制**：只允许 Pod 调度到指定的节点
- ✅ **LIST 请求过滤**：`kubectl get pods` 只返回白名单节点上的 Pod
- ✅ **创建 Pod 限制**：只能指定白名单节点创建 Pod
- ✅ **删除 Pod 限制**：只能删除白名单节点上的 Pod
- ✅ **更新 Pod 限制**：只能更新白名单节点上的 Pod
- ✅ **Token 认证**：使用 ServiceAccount Token 进行身份验证
- ✅ **透明代理**：其他请求（如 Service、ConfigMap 等）正常透传
- ✅ **高可用**：支持多副本部署，自动滚动更新
- ✅ **健康检查**：支持 liveness 和 readiness 探针

---

## 📐 架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           你的 Java 代码 / kubectl                          │
│                     (使用 ServiceAccount Token)                             │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         API Aggregator (自定义 API Server)                  │
│                                                                             │
│  1. 接收请求 → 验证 Token                                                  │
│  2. 解析请求路径 → /api/v1/namespaces/default/pods                         │
│  3. 判断操作类型 → LIST / GET / CREATE / DELETE / UPDATE                   │
│  4. LIST → 从 K8s 获取所有 Pod → 过滤白名单节点 → 返回过滤结果            │
│  5. CREATE → 检查 nodeName 是否在白名单中 → 通过则创建                    │
│  6. DELETE → 检查 Pod 是否在白名单节点 → 通过则删除                       │
│  7. 其他请求 → 透明代理到 Kubernetes API                                  │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes API Server                               │
│                                                                             │
│  处理经过 Aggregator 过滤后的请求                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📁 项目结构

```
api-aggregator/
├── cmd/
│   └── aggregator/
│       └── main.go              # 主程序入口
├── pkg/
│   └── apiserver/
│       └── apiserver.go         # API Server 核心逻辑
├── manifests/
│   ├── rbac.yaml               # RBAC 权限
│   ├── deployment.yaml         # Deployment
│   ├── service.yaml            # Service
│   └── apiservice.yaml         # APIService（注册到 K8s）
├── hack/
│   ├── build.sh               # 构建脚本
│   ├── deploy.sh              # 部署脚本
│   ├── cleanup.sh             # 清理脚本
│   ├── test.sh               # 测试脚本
│   └── generate-certs.sh      # 证书生成
├── Dockerfile                 # 镜像构建
├── go.mod                     # Go 依赖
├── go.sum                     # Go 依赖校验
└── README.md                  # 本文件
```

---

## 🚀 快速部署

### 前置条件

- Kubernetes 集群（版本 v1.19+）
- `kubectl` 已配置
- Docker（用于构建镜像）
- OpenSSL（用于生成证书）

### 1. 修改配置

编辑 `manifests/deployment.yaml`，修改白名单节点列表：

```yaml
args:
- --allowed-nodes=node01,node02,node03  # 👈 改为你的白名单节点
```

### 2. 构建镜像

```bash
# 给脚本添加执行权限
chmod +x hack/*.sh

# 构建镜像
./hack/build.sh
```

### 3. 部署

```bash
# 一键部署
./hack/deploy.sh
```

### 4. 验证

```bash
# 查看 Pod 状态
kubectl get pods -n kube-system -l app=api-aggregator

# 查看日志
kubectl logs -n kube-system -l app=api-aggregator --tail=20

# 运行测试
./hack/test.sh
```

---

## 📝 使用方式

### 方式一：修改 Java 代码（推荐）

```java
// 原来：直接调用 Kubernetes API
String url = "https://x.x.x.x:6443/api/v1/namespaces/default/pods";

// 改为：通过 API Aggregator
String url = "https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods";
```

**Token 完全不变**，继续使用 ServiceAccount Token。

### 方式二：使用 kubectl

```bash
# 1. 获取 Token
TOKEN=$(kubectl get secret -n my-namespace $(kubectl get serviceaccount multi-node-operator-sa -n my-namespace -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.token}' | base64 -d)

# 2. 通过 API Aggregator 查询（只返回白名单节点的 Pod）
curl -k -H "Authorization: Bearer ${TOKEN}" \
  https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods

# 3. 通过 API Aggregator 创建 Pod（必须指定白名单节点）
curl -k -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods \
  -d '{
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {"name": "my-pod"},
    "spec": {
      "nodeName": "hadoop02",
      "containers": [{"name": "nginx", "image": "nginx:latest"}]
    }
  }'
```

### 方式三：配置 kubectl context

```bash
# 1. 配置 context
kubectl config set-cluster aggregator-cluster \
  --server=https://api-aggregator.kube-system.svc \
  --insecure-skip-tls-verify=true

kubectl config set-credentials aggregator-user \
  --token=${TOKEN}

kubectl config set-context aggregator-context \
  --cluster=aggregator-cluster \
  --user=aggregator-user \
  --namespace=default

# 2. 切换到 aggregator context
kubectl config use-context aggregator-context

# 3. 现在 kubectl 命令走 API Aggregator
kubectl get pods  # 只返回白名单节点的 Pod

# 4. 切换回默认 context
kubectl config use-context default
```

---

## 🧪 验证

### 快速验证脚本

```bash
./hack/test.sh
```

### 手动验证

```bash
# 1. 检查 Pod 状态
kubectl get pods -n kube-system -l app=api-aggregator

# 2. 健康检查
kubectl run test-curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -k -s https://api-aggregator.kube-system.svc/healthz

# 3. 查询 Pod（通过 API Aggregator）
kubectl run test-curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -k -s -H "Authorization: Bearer ${TOKEN}" \
  https://api-aggregator.kube-system.svc/api/v1/namespaces/default/pods

# 4. 对比直接查询 K8s API
kubectl run test-curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -k -s -H "Authorization: Bearer ${TOKEN}" \
  https://kubernetes.default.svc/api/v1/namespaces/default/pods
```

### 预期结果

| 操作                                  | 预期结果               |
| ------------------------------------- | ---------------------- |
| `kubectl get pods`（通过 Aggregator） | 只返回白名单节点的 Pod |
| `kubectl get pods`（直接 K8s API）    | 返回所有 Pod           |
| 在白名单节点创建 Pod                  | ✅ 成功                 |
| 在非白名单节点创建 Pod                | ❌ 返回 403 Forbidden   |

---

## 📊 与 Webhook 方案对比

| 功能                              | Webhook 方案    | API Aggregator 方案 |
| --------------------------------- | --------------- | ------------------- |
| **拦截 CREATE**                   | ✅ 支持          | ✅ 支持              |
| **拦截 DELETE**                   | ✅ 支持          | ✅ 支持              |
| **拦截 UPDATE**                   | ✅ 支持          | ✅ 支持              |
| **拦截 LIST（kubectl get pods）** | ❌ 不支持        | ✅ 支持              |
| **过滤 LIST 结果**                | ❌ 不支持        | ✅ 支持              |
| **用户感知**                      | 创建时被拦截    | 完全透明            |
| **代码改动（Java）**              | 不需要改 URL    | 需要改 URL 地址     |
| **实现语言**                      | Python（Flask） | Go                  |
| **维护成本**                      | 低              | 中                  |

---

## 🔧 配置说明

### 修改白名单节点

编辑 `manifests/deployment.yaml`：

```yaml
args:
- --allowed-nodes=node01,node02,node03  # 用逗号分隔
```

重新部署：

```bash
kubectl apply -f manifests/deployment.yaml
kubectl rollout restart deployment/api-aggregator -n kube-system
```

### 修改日志级别

```yaml
args:
- --allowed-nodes=node01,node02,node03
- --v=4  # 日志级别：0-5，数字越大日志越详细
```

---

## 🧹 清理

### 一键清理

```bash
./hack/cleanup.sh
```

### 手动清理

```bash
# 删除 APIService
kubectl delete apiservice v1.node-pod.example.com

# 删除 Deployment
kubectl delete deployment api-aggregator -n kube-system

# 删除 Service
kubectl delete service api-aggregator -n kube-system

# 删除 Secret
kubectl delete secret api-aggregator-tls -n kube-system

# 删除 RBAC
kubectl delete clusterrolebinding api-aggregator
kubectl delete clusterrole api-aggregator
kubectl delete serviceaccount api-aggregator -n kube-system

# 删除证书目录
rm -rf certs/
```

---

## 🐛 故障排查

### 问题 1：Pod 无法启动

```bash
# 查看日志
kubectl logs -n kube-system -l app=api-aggregator

# 查看 Pod 详情
kubectl describe pod -n kube-system -l app=api-aggregator
```

### 问题 2：APIService 不可用

```bash
# 检查 APIService 状态
kubectl get apiservice v1.node-pod.example.com

# 查看详细信息
kubectl describe apiservice v1.node-pod.example.com
```

### 问题 3：连接被拒绝

```bash
# 检查 Service
kubectl get svc api-aggregator -n kube-system

# 检查 Endpoint
kubectl get endpoints api-aggregator -n kube-system

# 检查证书
kubectl get secret api-aggregator-tls -n kube-system
```

### 问题 4：Token 无效

```bash
# 重新生成 Token
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
```

---

## 🔐 安全说明

- **Token 认证**：所有请求必须携带有效的 ServiceAccount Token
- **最小权限原则**：API Aggregator 只授予必要的 RBAC 权限
- **证书管理**：使用 TLS 证书加密通信，证书需定期更新
- **审计日志**：所有请求都有日志记录，便于审计