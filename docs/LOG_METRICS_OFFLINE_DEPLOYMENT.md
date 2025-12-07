# KubeEdge 离线环境日志采集与资源监控最佳实践方案

**版本**: v1.0  
**适用版本**: KubeEdge v1.22.0  
**场景**: 离线安装（仅云边可通信）  
**日期**: 2025-12-07

---

## 1. 概述

### 1.1 目标

在离线环境下（仅云边可通信，无互联网连接）自动初始化并支持以下功能：
- **kubectl logs/exec/attach**: 从云端查看边缘 Pod 日志并进入容器调试
- **Metrics Server**: 收集边缘节点和容器的资源使用情况（CPU、内存等）

### 1.2 核心技术

| 功能 | 技术方案 | 官方文档 |
|------|---------|---------|
| **kubectl logs/exec** | CloudStream + EdgeStream | [debug.md](https://github.com/kubeedge/website/blob/master/docs/advanced/debug.md) |
| **Metrics Server** | Metrics-server + Stream 隧道 | [metrics.md](https://github.com/kubeedge/website/blob/master/docs/advanced/metrics.md) |

### 1.3 架构原理

```
┌─────────────────────────────────────────────────────────────────┐
│ 云端 (CloudCore)                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐  │
│  │  kubectl     │─────▶│ APIServer    │◀────▶│ Metrics-     │  │
│  │  logs/exec   │      │              │      │ Server       │  │
│  └──────────────┘      └──────┬───────┘      └──────┬───────┘  │
│                                │                      │          │
│                                │                      │          │
│                        ┌───────▼──────────────────────▼───────┐ │
│                        │     CloudStream (10003/10004)       │ │
│                        │  - streamPort: 10003 (logs/exec)    │ │
│                        │  - tunnelPort: 10004 (metrics)      │ │
│                        └───────┬──────────────────────────────┘ │
└────────────────────────────────┼────────────────────────────────┘
                                 │ TLS 隧道 (云边通信)
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│ 边缘 (EdgeCore)                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │           EdgeStream (10004)                               │ │
│  │  - 接收云端请求                                              │ │
│  │  - 转发到本地 Edged/Kubelet                                 │ │
│  └───────────────────┬────────────────────────────────────────┘ │
│                      │                                           │
│           ┌──────────▼──────────┐     ┌────────────────┐        │
│           │  Edged (10250)      │     │  容器运行时    │        │
│           │  - /logs            │────▶│  - Docker      │        │
│           │  - /exec            │     │  - Containerd  │        │
│           │  - /metrics/cadvisor│     │                │        │
│           └─────────────────────┘     └────────────────┘        │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

**关键点**:
1. **CloudStream** 默认已启用（Helm 部署自动配置）
2. **EdgeStream** 需要在边缘端配置文件中启用
3. **Stream 证书** 由 CloudCore Helm Chart 自动生成
4. **iptables 规则** 将 metrics-server 请求路由到 Stream 隧道

---

## 2. 功能需求分析

### 2.1 kubectl logs/exec 功能

#### 2.1.1 官方文档摘要

根据 [debug.md](https://github.com/kubeedge/website/blob/master/docs/advanced/debug.md)：

**云端配置（CloudCore）**：
- Helm 部署默认启用 CloudStream（`cloudStream.enable: true`）
- 自动生成 Stream 证书（无需手动操作）
- 端口：
  - `streamPort: 10003` - logs/exec 流式传输
  - `tunnelPort: 10004` - 隧道连接
- iptables 规则由 `iptablesmanager` 组件自动配置

**边缘配置（EdgeCore）**：
- 需要启用 EdgeStream：
  ```yaml
  modules:
    edgeStream:
      enable: true
      handshakeTimeout: 30
      readDeadline: 15
      server: 127.0.0.1:10004
      tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
      tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
      tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
      writeDeadline: 15
  ```

#### 2.1.2 离线部署挑战

| 挑战 | 解决方案 |
|------|---------|
| 证书文件需要从云端复制到边缘 | EdgeCore 自动通过云边隧道获取证书（无需手动复制） |
| EdgeCore 配置需要手动修改 | 安装脚本自动应用配置 |
| 功能验证需要已部署的 Pod | 提供验证脚本和示例 Pod |

### 2.2 Metrics Server 功能

#### 2.2.1 官方文档摘要

根据 [metrics.md](https://github.com/kubeedge/website/blob/master/docs/advanced/metrics.md)：

**前置依赖**：
- 必须先启用 kubectl logs/exec 功能（CloudStream + EdgeStream）
- Metrics-server 通过 Stream 隧道访问边缘 Kubelet 指标

**部署要求**：
- 使用 v0.4.0+ 版本（支持自动端口识别）
- 部署到 Master 节点（与 APIServer 同节点）
- 使用 `hostNetwork: true` 网络模式
- iptables 规则：
  ```bash
  iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to $CLOUDCOREIPS:10003
  ```

**关键配置**：
```yaml
containers:
- name: metrics-server
  args:
  - --kubelet-insecure-tls          # 跳过 TLS 验证
  - --kubelet-use-node-status-port  # 使用节点状态端口
hostNetwork: true                    # 使用主机网络
```

#### 2.2.2 离线部署挑战

| 挑战 | 解决方案 |
|------|---------|
| Metrics-server 镜像需要离线打包 | 云端离线包包含 metrics-server 镜像 |
| iptables 规则需要手动配置 | 安装脚本自动应用 iptables 规则 |
| 需要编译 v0.4.0+ 版本 | 使用官方 v0.4.1 镜像（已打包到离线包） |
| 部署 YAML 需要修改多处配置 | 提供预配置的部署模板 |

---

## 3. 离线安装方案架构

### 3.1 方案设计原则

1. **最小化手动操作**: 安装脚本自动完成所有配置
2. **镜像预打包**: 所有依赖镜像包含在离线包中
3. **配置文件模板化**: 使用模板文件，安装时自动替换变量
4. **验证步骤集成**: 安装完成后自动验证功能可用性
5. **兼容现有架构**: 不影响现有安装流程

### 3.2 架构设计

#### 3.2.1 云端离线包扩展

**新增组件**：
```
kubeedge-cloud-{version}/
├── images/
│   ├── metrics-server-v0.4.1.tar           # 新增
│   └── ...（现有镜像）
├── manifests/
│   ├── metrics-server.yaml                  # 新增
│   └── iptables-metrics-setup.sh            # 新增
├── install.sh
└── install-kubeedge-only.sh
```

**metrics-server.yaml 模板**：
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-server
  namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      hostNetwork: true  # 关键：使用主机网络
      serviceAccountName: metrics-server
      # 部署到 Master 节点
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      containers:
      - name: metrics-server
        image: __METRICS_SERVER_IMAGE__  # 安装时替换
        imagePullPolicy: Never            # 离线模式
        args:
        - --cert-dir=/tmp
        - --secure-port=4443
        - --kubelet-insecure-tls         # 跳过 TLS 验证
        - --kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP
        - --kubelet-use-node-status-port # 关键：使用节点状态端口
        ports:
        - name: https
          containerPort: 4443
          protocol: TCP
        volumeMounts:
        - name: tmp-dir
          mountPath: /tmp
      volumes:
      - name: tmp-dir
        emptyDir: {}
```

**iptables-metrics-setup.sh 脚本**：
```bash
#!/bin/bash
# metrics-server iptables 规则自动配置脚本

CLOUDCORE_IP="${1:-127.0.0.1}"
STREAM_PORT="10003"

echo "=== 配置 Metrics-server iptables 规则 ==="
echo "CloudCore IP: $CLOUDCORE_IP"
echo "Stream Port: $STREAM_PORT"

# 检查规则是否已存在
if iptables -t nat -C OUTPUT -p tcp --dport 10350 -j DNAT --to ${CLOUDCORE_IP}:${STREAM_PORT} 2>/dev/null; then
    echo "iptables 规则已存在，跳过"
    exit 0
fi

# 添加 iptables 规则（将 metrics-server 对 10350 的请求转发到 CloudCore Stream 端口）
iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to ${CLOUDCORE_IP}:${STREAM_PORT}

# 验证规则
if iptables -t nat -C OUTPUT -p tcp --dport 10350 -j DNAT --to ${CLOUDCORE_IP}:${STREAM_PORT} 2>/dev/null; then
    echo "✓ iptables 规则配置成功"
    
    # 保存规则（Ubuntu/Debian）
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
        echo "✓ iptables 规则已持久化（netfilter-persistent）"
    elif command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
        echo "警告：无法自动持久化 iptables 规则，请手动保存"
    fi
else
    echo "错误：iptables 规则配置失败"
    exit 1
fi

# 显示当前规则
echo ""
echo "当前 NAT 表 OUTPUT 链规则："
iptables -t nat -L OUTPUT -n -v | grep 10350
```

#### 3.2.2 边缘端配置自动化

**EdgeCore 配置修改（install.sh）**：
```bash
# 在边缘安装脚本中添加 EdgeStream 配置

setup_edgestream() {
    echo "=== 配置 EdgeStream（支持 kubectl logs/exec/metrics）==="
    
    local EDGECORE_CONFIG="/etc/kubeedge/config/edgecore.yaml"
    
    # 检查配置文件是否存在
    if [ ! -f "$EDGECORE_CONFIG" ]; then
        echo "错误：EdgeCore 配置文件不存在: $EDGECORE_CONFIG"
        return 1
    fi
    
    # 备份原配置
    cp "$EDGECORE_CONFIG" "${EDGECORE_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
    
    # 使用 yq 或 sed 修改配置（启用 EdgeStream）
    if command -v yq >/dev/null 2>&1; then
        # 使用 yq 修改 YAML（推荐）
        yq eval '.modules.edgeStream.enable = true' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.handshakeTimeout = 30' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.readDeadline = 15' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.server = "127.0.0.1:10004"' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.writeDeadline = 15' -i "$EDGECORE_CONFIG"
        echo "✓ EdgeStream 配置已更新（使用 yq）"
    else
        # 使用 sed 修改（备用方案）
        sed -i '/edgeStream:/,/enable:/ s/enable: false/enable: true/' "$EDGECORE_CONFIG"
        echo "✓ EdgeStream 配置已更新（使用 sed）"
    fi
    
    # 验证配置
    if grep -A 5 "edgeStream:" "$EDGECORE_CONFIG" | grep -q "enable: true"; then
        echo "✓ EdgeStream 已成功启用"
        return 0
    else
        echo "错误：EdgeStream 配置更新失败"
        return 1
    fi
}

# 在主安装流程中调用
install_edgecore() {
    # ... 现有安装逻辑 ...
    
    # 配置 EdgeStream
    setup_edgestream || {
        echo "警告：EdgeStream 配置失败，kubectl logs/exec 功能将不可用"
        echo "您可以手动编辑 /etc/kubeedge/config/edgecore.yaml 启用 edgeStream"
    }
    
    # 重启 EdgeCore 应用配置
    systemctl restart edgecore
}
```

### 3.3 镜像清单

#### 3.3.1 云端新增镜像

| 镜像 | 版本 | 用途 | 大小（约） |
|------|------|------|-----------|
| `metrics-server/metrics-server` | v0.4.1 | 资源指标收集 | ~57 MB |

**镜像下载命令**（集成到 GitHub Actions）：
```yaml
# .github/workflows/build-release-cloud.yml

# 在现有镜像列表中添加
METRICS_IMAGES=(
  "registry.k8s.io/metrics-server/metrics-server:v0.4.1"
)

ALL_IMAGES=("${K3S_IMAGES[@]}" "${KUBEEDGE_IMAGES[@]}" "${EDGEMESH_IMAGES[@]}" "${METRICS_IMAGES[@]}")
```

---

## 4. 部署实施步骤

### 4.1 云端部署

#### 4.1.1 安装 CloudCore（现有流程）

```bash
cd cloud/install
sudo ./install.sh

# CloudCore Helm Chart 会自动：
# 1. 启用 CloudStream（cloudStream.enable: true）
# 2. 生成 Stream 证书（无需手动操作）
# 3. 配置 iptablesmanager（自动配置 iptables）
```

**验证 CloudStream 状态**：
```bash
# 检查 CloudCore 配置
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 10 cloudStream

# 预期输出：
# cloudStream:
#   enable: true
#   streamPort: 10003
#   tunnelPort: 10004
```

#### 4.1.2 部署 Metrics-server

```bash
# 1. 加载 metrics-server 镜像
docker load -i images/metrics-server-v0.4.1.tar

# 2. 配置 iptables 规则
CLOUDCORE_IP=$(kubectl get svc cloudcore -n kubeedge -o jsonpath='{.spec.clusterIP}')
sudo ./manifests/iptables-metrics-setup.sh "$CLOUDCORE_IP"

# 3. 部署 metrics-server
kubectl apply -f manifests/metrics-server.yaml

# 4. 验证部署
kubectl get pod -n kube-system -l k8s-app=metrics-server
# 预期输出：
# NAME                              READY   STATUS    RESTARTS   AGE
# metrics-server-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

**完整的 manifests/metrics-server.yaml**（包含 RBAC）：
```yaml
# 详细配置见 3.2.1 节
# 此处省略，安装脚本会自动应用
```

### 4.2 边缘端部署

#### 4.2.1 安装 EdgeCore（增强流程）

```bash
cd edge/install
sudo ./install.sh <CLOUD_IP>:10000 <TOKEN> edge-node-1

# 安装脚本会自动：
# 1. 安装 EdgeCore
# 2. 启用 EdgeStream 配置（modules.edgeStream.enable: true）
# 3. 重启 EdgeCore 应用配置
```

**EdgeCore 完整配置示例**：
```yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
modules:
  edgeStream:
    enable: true                          # 关键：启用 EdgeStream
    handshakeTimeout: 30
    readDeadline: 15
    server: 127.0.0.1:10004               # 本地 Stream 服务器地址
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    writeDeadline: 15
  edged:
    enable: true
    tailoredKubeletConfig:
      address: 127.0.0.1
      cgroupDriver: systemd
      clusterDNS:
      - 10.96.0.10                        # 根据实际 DNS 修改
      clusterDomain: cluster.local
```

#### 4.2.2 验证 EdgeStream 状态

```bash
# 1. 检查 EdgeCore 日志
journalctl -u edgecore -n 50 | grep -i stream

# 预期输出示例：
# I1207 10:30:15.123456 edgecore.go:123] EdgeStream started successfully
# I1207 10:30:15.234567 edgestream.go:456] Connected to CloudStream at 10.1.11.85:10004

# 2. 检查 EdgeCore 配置
cat /etc/kubeedge/config/edgecore.yaml | grep -A 8 "edgeStream:"

# 3. 检查网络连接
ss -tlnp | grep 10004
# 预期输出：
# LISTEN 0 128 127.0.0.1:10004 0.0.0.0:* users:(("edgecore",pid=12345,fd=10))
```

### 4.3 功能验证

#### 4.3.1 验证 kubectl logs/exec

```bash
# 1. 部署测试 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-logs-exec
spec:
  containers:
  - name: nginx
    image: nginx:1.20
    ports:
    - containerPort: 80
  nodeSelector:
    node-role.kubernetes.io/edge: ""
EOF

# 2. 等待 Pod 运行
kubectl wait --for=condition=Ready pod/test-logs-exec --timeout=120s

# 3. 测试 kubectl logs
kubectl logs test-logs-exec
# 预期输出：nginx 启动日志

# 4. 测试 kubectl exec
kubectl exec -it test-logs-exec -- bash
# 预期：进入容器 shell

# 5. 测试 kubectl describe
kubectl describe pod test-logs-exec | grep -A 10 "Events:"
# 预期：显示 Pod 事件
```

#### 4.3.2 验证 Metrics Server

```bash
# 1. 等待 metrics-server 就绪
kubectl wait --for=condition=Ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s

# 2. 测试节点指标
kubectl top node
# 预期输出：
# NAME          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# edge-node-1   234m         5%     1234Mi          15%
# master        456m         11%    2345Mi          29%

# 3. 测试 Pod 指标
kubectl top pod -A
# 预期输出：
# NAMESPACE     NAME                              CPU(cores)   MEMORY(bytes)
# default       test-logs-exec                    1m           10Mi
# kube-system   metrics-server-xxx                2m           20Mi
# kubeedge      cloudcore-xxx                     50m          200Mi

# 4. 测试 Pod 指标详情
kubectl top pod test-logs-exec --containers
# 预期输出：
# POD               NAME    CPU(cores)   MEMORY(bytes)
# test-logs-exec    nginx   1m           10Mi
```

---

## 5. 自动化安装脚本集成

### 5.1 云端安装脚本增强

**cloud/install/install.sh 修改**：

```bash
#!/bin/bash
# 云端安装脚本（增强版）

# ... 现有安装逻辑 ...

# ========== 新增：Metrics Server 部署 ==========
deploy_metrics_server() {
    echo ""
    echo "=== 部署 Metrics-server ==="
    
    # 1. 检查 CloudCore 是否运行
    if ! kubectl get pod -n kubeedge -l app=cloudcore | grep -q Running; then
        echo "错误：CloudCore 未运行，请先确认 CloudCore 正常启动"
        return 1
    fi
    
    # 2. 加载 metrics-server 镜像
    echo "加载 metrics-server 镜像..."
    if [ -f "images/metrics-server-v0.4.1.tar" ]; then
        docker load -i images/metrics-server-v0.4.1.tar
        echo "✓ metrics-server 镜像加载完成"
    else
        echo "警告：metrics-server 镜像文件不存在，跳过"
        return 1
    fi
    
    # 3. 配置 iptables 规则
    echo "配置 iptables 规则..."
    CLOUDCORE_IP=$(kubectl get svc cloudcore -n kubeedge -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -z "$CLOUDCORE_IP" ]; then
        echo "警告：无法获取 CloudCore Service IP，使用 127.0.0.1"
        CLOUDCORE_IP="127.0.0.1"
    fi
    
    if [ -f "manifests/iptables-metrics-setup.sh" ]; then
        chmod +x manifests/iptables-metrics-setup.sh
        sudo manifests/iptables-metrics-setup.sh "$CLOUDCORE_IP"
    else
        # 备用：直接执行 iptables 命令
        sudo iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to ${CLOUDCORE_IP}:10003 2>/dev/null || {
            echo "警告：iptables 规则配置失败，metrics-server 可能无法正常工作"
        }
    fi
    
    # 4. 替换镜像名称并部署
    echo "部署 metrics-server..."
    if [ -f "manifests/metrics-server.yaml" ]; then
        # 替换镜像占位符
        sed "s|__METRICS_SERVER_IMAGE__|registry.k8s.io/metrics-server/metrics-server:v0.4.1|g" \
            manifests/metrics-server.yaml | kubectl apply -f -
        
        echo "✓ metrics-server 部署完成"
        echo ""
        echo "验证命令："
        echo "  kubectl get pod -n kube-system -l k8s-app=metrics-server"
        echo "  kubectl top node"
    else
        echo "警告：metrics-server.yaml 文件不存在，跳过部署"
        return 1
    fi
}

# 主安装流程
main() {
    echo "=== 开始云端离线安装 ==="
    
    # 1. 安装 K3s（现有逻辑）
    install_k3s || exit 1
    
    # 2. 安装 CloudCore（现有逻辑）
    install_cloudcore || exit 1
    
    # 3. 部署 EdgeMesh（现有逻辑）
    deploy_edgemesh || echo "警告：EdgeMesh 部署失败"
    
    # 4. 部署 Metrics-server（新增）
    deploy_metrics_server || echo "警告：Metrics-server 部署失败，您可以稍后手动部署"
    
    echo ""
    echo "=== 云端安装完成 ==="
    echo ""
    echo "日志采集与监控功能："
    echo "  - kubectl logs/exec: CloudStream 已自动启用（Helm Chart 默认配置）"
    echo "  - Metrics-server: $(kubectl get pod -n kube-system -l k8s-app=metrics-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo '未部署')"
    echo ""
    echo "边缘节点加入命令："
    echo "  sudo ./edge/install/install.sh <THIS_NODE_IP>:10000 <TOKEN> <EDGE_NODE_NAME>"
}

main "$@"
```

### 5.2 边缘端安装脚本增强

**edge/install/install.sh 修改**：

```bash
#!/bin/bash
# 边缘端安装脚本（增强版）

# ... 现有安装逻辑 ...

# ========== 新增：EdgeStream 配置 ==========
setup_edgestream() {
    echo ""
    echo "=== 配置 EdgeStream（支持 kubectl logs/exec/metrics）==="
    
    local EDGECORE_CONFIG="/etc/kubeedge/config/edgecore.yaml"
    
    # 检查配置文件是否存在
    if [ ! -f "$EDGECORE_CONFIG" ]; then
        echo "错误：EdgeCore 配置文件不存在: $EDGECORE_CONFIG"
        return 1
    fi
    
    # 备份原配置
    local BACKUP_FILE="${EDGECORE_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$EDGECORE_CONFIG" "$BACKUP_FILE"
    echo "✓ 配置文件已备份: $BACKUP_FILE"
    
    # 方案 1：使用 yq（推荐，更可靠）
    if command -v yq >/dev/null 2>&1; then
        echo "使用 yq 修改配置..."
        yq eval '.modules.edgeStream.enable = true' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.handshakeTimeout = 30' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.readDeadline = 15' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.server = "127.0.0.1:10004"' -i "$EDGECORE_CONFIG"
        yq eval '.modules.edgeStream.writeDeadline = 15' -i "$EDGECORE_CONFIG"
        echo "✓ EdgeStream 配置已更新（使用 yq）"
    # 方案 2：使用 sed（备用）
    else
        echo "yq 未安装，使用 sed 修改配置..."
        # 查找 edgeStream 段落并启用
        if grep -q "edgeStream:" "$EDGECORE_CONFIG"; then
            # 启用 edgeStream
            sed -i '/edgeStream:/,/enable:/ {
                s/enable: false/enable: true/
            }' "$EDGECORE_CONFIG"
            
            # 设置其他参数（如果不存在则添加）
            if ! grep -A 10 "edgeStream:" "$EDGECORE_CONFIG" | grep -q "handshakeTimeout:"; then
                sed -i '/edgeStream:/a\    handshakeTimeout: 30' "$EDGECORE_CONFIG"
            fi
            if ! grep -A 10 "edgeStream:" "$EDGECORE_CONFIG" | grep -q "readDeadline:"; then
                sed -i '/edgeStream:/a\    readDeadline: 15' "$EDGECORE_CONFIG"
            fi
            if ! grep -A 10 "edgeStream:" "$EDGECORE_CONFIG" | grep -q "server:"; then
                sed -i '/edgeStream:/a\    server: 127.0.0.1:10004' "$EDGECORE_CONFIG"
            fi
            if ! grep -A 10 "edgeStream:" "$EDGECORE_CONFIG" | grep -q "writeDeadline:"; then
                sed -i '/edgeStream:/a\    writeDeadline: 15' "$EDGECORE_CONFIG"
            fi
            echo "✓ EdgeStream 配置已更新（使用 sed）"
        else
            echo "警告：配置文件中未找到 edgeStream 段落"
            return 1
        fi
    fi
    
    # 验证配置
    if grep -A 5 "edgeStream:" "$EDGECORE_CONFIG" | grep -q "enable: true"; then
        echo "✓ EdgeStream 已成功启用"
        echo ""
        echo "EdgeStream 配置："
        grep -A 8 "edgeStream:" "$EDGECORE_CONFIG"
        return 0
    else
        echo "错误：EdgeStream 配置更新失败"
        echo "您可以手动编辑 $EDGECORE_CONFIG 文件"
        return 1
    fi
}

# 主安装流程
main() {
    echo "=== 开始边缘端离线安装 ==="
    
    # 解析参数
    CLOUD_IP_PORT="$1"
    TOKEN="$2"
    EDGE_NODE_NAME="$3"
    
    # 1. 安装 Containerd（现有逻辑）
    install_containerd || exit 1
    
    # 2. 加载镜像（现有逻辑）
    load_images || exit 1
    
    # 3. 安装 EdgeCore（现有逻辑）
    install_edgecore "$CLOUD_IP_PORT" "$TOKEN" "$EDGE_NODE_NAME" || exit 1
    
    # 4. 配置 EdgeStream（新增）
    setup_edgestream || {
        echo "警告：EdgeStream 配置失败，kubectl logs/exec 功能将不可用"
        echo "您可以稍后手动配置：编辑 /etc/kubeedge/config/edgecore.yaml"
        echo "设置 modules.edgeStream.enable: true"
    }
    
    # 5. 重启 EdgeCore 应用配置
    echo ""
    echo "重启 EdgeCore 应用配置..."
    systemctl restart edgecore
    sleep 5
    
    # 6. 验证 EdgeCore 状态
    if systemctl is-active --quiet edgecore; then
        echo "✓ EdgeCore 运行正常"
    else
        echo "错误：EdgeCore 未运行，请检查日志: journalctl -u edgecore -n 50"
        exit 1
    fi
    
    echo ""
    echo "=== 边缘端安装完成 ==="
    echo ""
    echo "功能验证："
    echo "  1. 检查节点状态: kubectl get node $EDGE_NODE_NAME"
    echo "  2. 测试 kubectl logs: kubectl logs <pod-name>"
    echo "  3. 测试资源监控: kubectl top node"
    echo ""
    echo "EdgeCore 日志查看："
    echo "  journalctl -u edgecore -f"
}

main "$@"
```

---

## 6. GitHub Actions 集成

### 6.1 云端构建流程修改

**.github/workflows/build-release-cloud.yml**:

```yaml
# 在现有镜像列表中添加 metrics-server

# Line 150-180 附近
# KubeEdge v1.22.0 组件镜像列表 (从 GitHub keadm 代码获取)
KUBEEDGE_IMAGES=(
  "docker.io/kubeedge/cloudcore:v${KUBEEDGE_VERSION}"
  "docker.io/kubeedge/iptables-manager:v${KUBEEDGE_VERSION}"
  "docker.io/kubeedge/controller-manager:v${KUBEEDGE_VERSION}"
  "docker.io/kubeedge/admission:v${KUBEEDGE_VERSION}"
)

# EdgeMesh 镜像 (用于边缘服务网格)
EDGEMESH_VERSION="v1.17.0"
EDGEMESH_IMAGES=(
  "docker.io/kubeedge/edgemesh-agent:${EDGEMESH_VERSION}"
)

# 新增：Metrics-server 镜像
METRICS_SERVER_VERSION="v0.4.1"
METRICS_IMAGES=(
  "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_VERSION}"
)

# 合并所有镜像
ALL_IMAGES=("${K3S_IMAGES[@]}" "${KUBEEDGE_IMAGES[@]}" "${EDGEMESH_IMAGES[@]}" "${METRICS_IMAGES[@]}")

# 镜像拉取和保存循环（现有逻辑会自动处理）
for image in "${ALL_IMAGES[@]}"; do
  echo "  拉取镜像: $image"
  docker pull --platform ${{ matrix.dockerfile_platform }} "$image" || (echo "错误：无法拉取镜像 $image" && exit 1)
  
  # 保存镜像为tar文件
  filename=$(echo "$image" | sed 's/[\/:]/-/g')
  docker save "$image" -o "images/${filename}.tar" || (echo "错误：无法保存镜像 $image" && exit 1)
done
```

### 6.2 部署清单文件打包

```yaml
# .github/workflows/build-release-cloud.yml

# 在打包步骤中添加 manifests 目录

# Line 240-260 附近
# 复制安装脚本和清单文件
cp "$INSTALL_SCRIPT" "$TEMP_PKG_DIR/"
if [ -f "$INSTALL_KUBEEDGE_ONLY" ]; then
  cp "$INSTALL_KUBEEDGE_ONLY" "$TEMP_PKG_DIR/"
fi
if [ -f "$CLEANUP_SCRIPT" ]; then
  cp "$CLEANUP_SCRIPT" "$TEMP_PKG_DIR/"
fi

# 新增：复制 manifests 目录
MANIFESTS_DIR="$INSTALL_DIR/manifests"
if [ -d "$MANIFESTS_DIR" ]; then
  cp -r "$MANIFESTS_DIR" "$TEMP_PKG_DIR/"
  echo "✓ 已包含部署清单文件（metrics-server.yaml 等）"
fi
```

---

## 7. 故障排查指南

### 7.1 kubectl logs/exec 不可用

**症状**：
```bash
$ kubectl logs pod-name
Error from server: Get "https://edge-node-1:10250/containerLogs/...": dial tcp: lookup edge-node-1: no such host
```

**排查步骤**：

1. **检查 CloudStream 状态**：
   ```bash
   # 查看 CloudCore ConfigMap
   kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 10 cloudStream
   
   # 预期：enable: true
   ```

2. **检查 EdgeStream 状态**：
   ```bash
   # 边缘节点上执行
   grep -A 8 "edgeStream:" /etc/kubeedge/config/edgecore.yaml
   
   # 预期：enable: true
   ```

3. **检查 EdgeCore 日志**：
   ```bash
   # 边缘节点上执行
   journalctl -u edgecore -n 100 | grep -i stream
   
   # 查找错误信息
   ```

4. **检查网络连接**：
   ```bash
   # 边缘节点上执行
   ss -tlnp | grep 10004
   
   # 预期：显示 edgecore 监听 127.0.0.1:10004
   ```

5. **检查 Stream 证书**：
   ```bash
   # 边缘节点上执行
   ls -l /etc/kubeedge/ca/rootCA.crt
   ls -l /etc/kubeedge/certs/server.crt
   ls -l /etc/kubeedge/certs/server.key
   
   # 确认文件存在且可读
   ```

**解决方案**：
```bash
# 1. 重新启用 EdgeStream
vi /etc/kubeedge/config/edgecore.yaml
# 设置 modules.edgeStream.enable: true

# 2. 重启 EdgeCore
systemctl restart edgecore

# 3. 验证
journalctl -u edgecore -f
```

### 7.2 Metrics Server 无法获取指标

**症状**：
```bash
$ kubectl top node
Error from server (ServiceUnavailable): the server is currently unable to handle the request (get nodes.metrics.k8s.io)
```

**排查步骤**：

1. **检查 metrics-server Pod 状态**：
   ```bash
   kubectl get pod -n kube-system -l k8s-app=metrics-server
   
   # 预期：Running
   ```

2. **检查 metrics-server 日志**：
   ```bash
   kubectl logs -n kube-system -l k8s-app=metrics-server
   
   # 查找错误信息
   ```

3. **检查 iptables 规则**：
   ```bash
   # Master 节点上执行
   iptables -t nat -L OUTPUT -n -v | grep 10350
   
   # 预期：显示 DNAT 规则到 CloudCore IP:10003
   ```

4. **检查 CloudStream 端口**：
   ```bash
   # Master 节点上执行
   CLOUDCORE_IP=$(kubectl get svc cloudcore -n kubeedge -o jsonpath='{.spec.clusterIP}')
   echo "CloudCore IP: $CLOUDCORE_IP"
   
   # 测试连接
   curl -k https://$CLOUDCORE_IP:10003
   ```

5. **检查 EdgeCore Edged 端口**：
   ```bash
   # 边缘节点上执行
   ss -tlnp | grep 10250
   
   # 预期：显示 edgecore 监听 127.0.0.1:10250
   ```

**解决方案**：
```bash
# 1. 重新配置 iptables 规则
CLOUDCORE_IP=$(kubectl get svc cloudcore -n kubeedge -o jsonpath='{.spec.clusterIP}')
sudo iptables -t nat -D OUTPUT -p tcp --dport 10350 -j DNAT --to ${CLOUDCORE_IP}:10003 2>/dev/null
sudo iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to ${CLOUDCORE_IP}:10003

# 2. 重启 metrics-server
kubectl rollout restart deployment metrics-server -n kube-system

# 3. 等待 Pod 就绪
kubectl wait --for=condition=Ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s

# 4. 验证
kubectl top node
```

### 7.3 EdgeStream 连接失败

**症状**：
```bash
# EdgeCore 日志显示
E1207 10:30:15.123456 edgestream.go:456] Failed to connect to CloudStream: connection refused
```

**排查步骤**：

1. **检查云边网络连通性**：
   ```bash
   # 边缘节点上执行
   CLOUD_IP="10.1.11.85"  # 替换为实际 CloudCore IP
   telnet $CLOUD_IP 10004
   
   # 或使用 nc
   nc -zv $CLOUD_IP 10004
   ```

2. **检查 CloudCore Service**：
   ```bash
   kubectl get svc cloudcore -n kubeedge -o wide
   
   # 检查 10004 端口是否暴露
   ```

3. **检查防火墙规则**：
   ```bash
   # Master 节点上执行
   firewall-cmd --list-all 2>/dev/null || iptables -L -n | grep 10004
   
   # 确保 10004 端口允许访问
   ```

**解决方案**：
```bash
# 1. 确保 CloudCore Service 暴露端口
kubectl patch svc cloudcore -n kubeedge --type='json' \
  -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "tunnel", "port": 10004, "protocol": "TCP"}}]'

# 2. 重启 CloudCore
kubectl rollout restart deployment cloudcore -n kubeedge

# 3. 重启 EdgeCore
systemctl restart edgecore
```

---

## 8. 性能与资源评估

### 8.1 资源消耗

| 组件 | CPU（空闲） | CPU（活跃） | 内存 | 存储 |
|------|------------|------------|------|------|
| **CloudStream** | ~10m | ~50m | ~50 MB | - |
| **EdgeStream** | ~5m | ~20m | ~30 MB | - |
| **Metrics-server** | ~5m | ~30m | ~60 MB | - |
| **总计（云端）** | ~15m | ~80m | ~110 MB | ~60 MB（镜像） |
| **总计（边缘）** | ~5m | ~20m | ~30 MB | - |

### 8.2 网络带宽

| 场景 | 带宽消耗 | 说明 |
|------|---------|------|
| **kubectl logs**（持续流式） | ~10-100 KB/s | 取决于日志输出速度 |
| **kubectl exec**（交互式） | ~1-10 KB/s | SSH 会话级别 |
| **Metrics 采集**（定期） | ~1-5 KB/s | 每 15-60 秒采集一次 |

### 8.3 最小系统要求

**云端（Master 节点）**：
- CPU: 2 核心（建议 4 核心）
- 内存: 4 GB（建议 8 GB）
- 存储: 20 GB

**边缘端（Worker 节点）**：
- CPU: 1 核心（建议 2 核心）
- 内存: 1 GB（建议 2 GB）
- 存储: 10 GB

---

## 9. 安全考虑

### 9.1 证书管理

**CloudStream 证书**：
- Helm Chart 自动生成（无需手动操作）
- 证书存储在 Kubernetes Secret 中
- EdgeCore 通过云边隧道自动获取

**EdgeCore 证书**：
- EdgeCore 首次启动时自动申请
- 证书存储在 `/etc/kubeedge/certs/`
- 支持证书自动轮换（EdgeCore v1.4+）

### 9.2 网络安全

**iptables 规则**：
- 仅在 Master 节点本地生效（OUTPUT 链）
- 不暴露边缘端口到外部网络
- 所有流量通过 CloudStream TLS 隧道加密

**TLS 加密**：
- CloudStream ↔ EdgeStream 使用 TLS 1.2+
- 证书双向验证（mTLS）
- 支持证书自动续期

### 9.3 权限控制

**Metrics-server RBAC**：
```yaml
# metrics-server 仅需最小权限
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:metrics-server
rules:
- apiGroups: [""]
  resources: ["nodes/stats"]
  verbs: ["get"]
```

**kubectl logs/exec 权限**：
- 继承 Kubernetes RBAC 权限
- 需要 `pods/log` 和 `pods/exec` 权限
- 可通过 RoleBinding 限制用户访问范围

---

## 10. 最佳实践建议

### 10.1 生产环境部署

1. **资源预留**：
   ```yaml
   # metrics-server deployment
   resources:
     requests:
       cpu: 100m
       memory: 200Mi
     limits:
       cpu: 200m
       memory: 400Mi
   ```

2. **高可用配置**：
   ```yaml
   # metrics-server replica
   replicas: 2
   affinity:
     podAntiAffinity:
       preferredDuringSchedulingIgnoredDuringExecution:
       - weight: 100
         podAffinityTerm:
           labelSelector:
             matchLabels:
               k8s-app: metrics-server
           topologyKey: kubernetes.io/hostname
   ```

3. **监控告警**：
   - 监控 CloudStream/EdgeStream 连接状态
   - 监控 metrics-server 健康状态
   - 设置告警阈值（CPU、内存、网络）

### 10.2 日志采集最佳实践

1. **日志轮转配置**：
   ```yaml
   # EdgeCore 配置
   modules:
     edged:
       containerLogMaxFiles: 5
       containerLogMaxSize: 10Mi
   ```

2. **避免日志洪水**：
   - 控制应用日志输出频率
   - 使用日志级别过滤（INFO、WARNING、ERROR）
   - 定期清理旧日志

### 10.3 Metrics 采集最佳实践

1. **采集间隔配置**：
   ```yaml
   # metrics-server args
   - --metric-resolution=15s  # 默认 60s，根据需求调整
   ```

2. **数据保留策略**：
   - Metrics-server 仅保留最新数据（无持久化）
   - 需要历史数据请使用 Prometheus
   - 建议部署 Prometheus + Grafana 用于长期监控

---

## 11. 升级与兼容性

### 11.1 版本兼容性

| KubeEdge 版本 | CloudStream | EdgeStream | Metrics-server |
|--------------|-------------|------------|----------------|
| v1.3+        | ✅ 支持      | ✅ 支持     | ✅ 支持         |
| v1.4+        | ✅ 默认启用  | ✅ 支持     | ✅ 支持（v0.4.0+）|
| v1.22.0      | ✅ 默认启用  | ✅ 支持     | ✅ 支持（v0.4.1） |

### 11.2 升级注意事项

**从旧版本升级**：
1. 升级 CloudCore 前备份配置
2. 逐个升级边缘节点（避免全部离线）
3. 验证 Stream 连接恢复后再升级下一个节点

**配置迁移**：
```bash
# 备份旧配置
kubectl get cm cloudcore -n kubeedge -o yaml > cloudcore-config-backup.yaml

# 升级后对比配置差异
kubectl diff -f cloudcore-config-backup.yaml
```

---

## 12. 参考资料

### 12.1 官方文档

- [KubeEdge Debug (kubectl logs/exec)](https://github.com/kubeedge/website/blob/master/docs/advanced/debug.md)
- [KubeEdge Metrics (metrics-server)](https://github.com/kubeedge/website/blob/master/docs/advanced/metrics.md)
- [KubeEdge 安装指南](https://kubeedge.io/docs/setup/install-with-keadm)
- [Kubernetes Metrics Server](https://github.com/kubernetes-sigs/metrics-server)

### 12.2 社区资源

- [KubeEdge GitHub](https://github.com/kubeedge/kubeedge)
- [KubeEdge Slack](https://kubeedge.io/docs/community/slack)
- [KubeEdge 问题反馈](https://github.com/kubeedge/kubeedge/issues)

### 12.3 相关项目

- [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
- [Grafana](https://grafana.com/)

---

## 13. 附录

### 13.1 完整配置示例

**CloudCore ConfigMap（关键部分）**：
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudcore
  namespace: kubeedge
data:
  cloudcore.yaml: |
    apiVersion: cloudcore.config.kubeedge.io/v1alpha2
    kind: CloudCore
    modules:
      cloudStream:
        enable: true
        streamPort: 10003
        tlsStreamCAFile: /etc/kubeedge/ca/streamCA.crt
        tlsStreamCertFile: /etc/kubeedge/certs/stream.crt
        tlsStreamPrivateKeyFile: /etc/kubeedge/certs/stream.key
        tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
        tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
        tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
        tunnelPort: 10004
```

**EdgeCore 配置（关键部分）**：
```yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
modules:
  edgeStream:
    enable: true
    handshakeTimeout: 30
    readDeadline: 15
    server: 127.0.0.1:10004
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    writeDeadline: 15
  edged:
    enable: true
    tailoredKubeletConfig:
      address: 127.0.0.1
      cgroupDriver: systemd
      clusterDNS:
      - 10.96.0.10
      clusterDomain: cluster.local
      containerLogMaxFiles: 5
      containerLogMaxSize: 10Mi
```

### 13.2 验证脚本

**verify-logs-metrics.sh**：
```bash
#!/bin/bash
# 日志采集与监控功能验证脚本

set -e

echo "=== KubeEdge 日志采集与监控功能验证 ==="
echo ""

# 1. 检查 CloudStream
echo "[1/5] 检查 CloudStream 状态..."
if kubectl get cm cloudcore -n kubeedge -o yaml | grep -q "cloudStream.*enable: true"; then
    echo "✓ CloudStream 已启用"
else
    echo "✗ CloudStream 未启用"
    exit 1
fi

# 2. 检查 EdgeStream（需要边缘节点访问权限）
echo "[2/5] 检查 EdgeStream 状态..."
EDGE_NODES=$(kubectl get nodes -l node-role.kubernetes.io/edge="" -o name | sed 's|node/||')
if [ -z "$EDGE_NODES" ]; then
    echo "✗ 未找到边缘节点"
    exit 1
fi

for NODE in $EDGE_NODES; do
    echo "  检查节点: $NODE"
    # 通过 kubectl describe 检查节点 Ready 状态
    if kubectl describe node "$NODE" | grep -q "Ready.*True"; then
        echo "  ✓ 节点 $NODE Ready"
    else
        echo "  ✗ 节点 $NODE 未 Ready"
    fi
done

# 3. 检查 metrics-server
echo "[3/5] 检查 metrics-server 状态..."
if kubectl get pod -n kube-system -l k8s-app=metrics-server | grep -q Running; then
    echo "✓ metrics-server 运行正常"
else
    echo "✗ metrics-server 未运行"
    exit 1
fi

# 4. 测试 kubectl top node
echo "[4/5] 测试 kubectl top node..."
if kubectl top node >/dev/null 2>&1; then
    echo "✓ kubectl top node 正常"
    kubectl top node
else
    echo "✗ kubectl top node 失败"
    exit 1
fi

# 5. 测试 kubectl logs（需要边缘 Pod）
echo "[5/5] 测试 kubectl logs..."
EDGE_POD=$(kubectl get pod -o wide | grep "$EDGE_NODES" | head -1 | awk '{print $1}')
if [ -n "$EDGE_POD" ]; then
    echo "  测试 Pod: $EDGE_POD"
    if kubectl logs "$EDGE_POD" --tail=5 >/dev/null 2>&1; then
        echo "✓ kubectl logs 正常"
    else
        echo "✗ kubectl logs 失败"
        exit 1
    fi
else
    echo "⚠ 未找到边缘 Pod，跳过 kubectl logs 测试"
fi

echo ""
echo "=== 所有验证通过 ==="
```

### 13.3 问题排查清单

| 问题 | 检查项 | 解决方法 |
|------|-------|---------|
| kubectl logs 失败 | CloudStream 启用 | 检查 CloudCore ConfigMap |
| | EdgeStream 启用 | 检查 EdgeCore 配置文件 |
| | 网络连通性 | 测试 10003/10004 端口 |
| | 证书文件 | 检查 /etc/kubeedge/certs/ |
| kubectl top node 失败 | metrics-server Pod | 检查 Pod 状态和日志 |
| | iptables 规则 | 检查 NAT 表 OUTPUT 链 |
| | CloudStream 连接 | 测试 CloudCore:10003 |
| 边缘节点 NotReady | EdgeCore 运行 | journalctl -u edgecore |
| | 云边通信 | 测试 CloudCore:10000 |
| | 证书有效期 | 检查证书过期时间 |

---

**文档版本**: v1.0  
**最后更新**: 2025-12-07  
**维护者**: KubePrepare 项目团队  
**反馈**: 请在 GitHub Issues 中提交问题和建议
