# EdgeMesh 离线部署最佳实践

## 概述

本文档基于 EdgeMesh 官方文档 (https://github.com/kubeedge/edgemesh) 重构离线部署方案,确保**完全离线化**环境下的最佳实践。

## 核心原则

1. **完全离线**: 整个安装部署过程无需外网访问,只需 cloud 和 edge 之间网络互通
2. **最小化依赖**: 仅安装必需的组件和镜像
3. **简化配置**: EdgeCore 配置最小化,避免不必要的复杂性
4. **官方兼容**: 严格遵循 EdgeMesh 官方安装流程和配置要求

## 一、架构理解

### 1.1 EdgeMesh 组件

根据 EdgeMesh 官方文档,EdgeMesh 包含以下核心组件:

- **edgemesh-agent**: 以 DaemonSet 方式运行在所有节点(云+边缘)
  - **Proxier**: 配置 iptables 规则,拦截请求
  - **DNS**: 内置 DNS 解析器,解析服务域名为 ClusterIP
  - **LoadBalancer**: 负载均衡器,支持多种策略
  - **Controller**: 通过 metaServer 或 K8s apiserver 获取元数据
  - **Tunnel**: 提供云边通信隧道(v1.12.0+ 合并了 edgemesh-server 功能)

- **edgemesh-gateway** (可选): Ingress 网关,提供外部访问入口

### 1.2 EdgeMesh 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                      KubeEdge Cluster                        │
├───────────────────────────┬─────────────────────────────────┤
│      Cloud Node           │         Edge Node               │
│                           │                                 │
│  ┌─────────────────────┐  │  ┌──────────────────────────┐   │
│  │  K3s Control Plane  │  │  │    EdgeCore              │   │
│  │  - apiserver        │  │  │    - metaServer (10550)  │   │
│  │  - CloudCore        │  │  │    - edgeStream          │   │
│  └─────────────────────┘  │  └──────────────────────────┘   │
│           │               │             │                    │
│  ┌────────┴────────┐      │  ┌─────────┴──────────┐        │
│  │ edgemesh-agent  │<─────┼──│  edgemesh-agent    │        │
│  │ (DaemonSet)     │Tunnel│  │  (DaemonSet)       │        │
│  │                 │      │  │                    │        │
│  │ - DNS (169...16)│      │  │  - DNS (169...16)  │        │
│  │ - Proxy         │      │  │  - Proxy           │        │
│  │ - Tunnel        │      │  │  - Tunnel          │        │
│  └─────────────────┘      │  └────────────────────┘        │
└───────────────────────────┴─────────────────────────────────┘
```

## 二、必需组件清单

### 2.1 镜像清单

基于官方 Helm Chart 和部署文件分析:

**Cloud 端 (13个镜像)**:
```
# K3s (8个)
rancher/mirrored-pause:3.6
rancher/mirrored-coredns-coredns:1.11.3
rancher/klipper-helm:v0.9.2-build20241105
rancher/klipper-lb:v0.4.9
rancher/local-path-provisioner:v0.0.30
rancher/mirrored-library-busybox:1.36.1
rancher/mirrored-library-traefik:2.11.2
rancher/mirrored-metrics-server:v0.7.2

# KubeEdge (4个)
kubeedge/cloudcore:v1.22.0
kubeedge/iptables-manager:v1.22.0
kubeedge/controller-manager:v1.22.0
kubeedge/cloudcore-synccontroller:v1.22.0

# EdgeMesh (1个)
kubeedge/edgemesh-agent:v1.17.0
```

**Edge 端 (2个镜像)**:
```
# EdgeMesh
kubeedge/edgemesh-agent:v1.17.0

# MQTT (可选)
eclipse-mosquitto:1.6.15
```

### 2.2 Helm Chart 清单

**Cloud 端**:
```
# EdgeMesh Helm Chart
edgemesh.tgz  # 包含 edgemesh-agent 的完整部署配置
```

### 2.3 CRDs 清单

EdgeMesh 依赖 Istio CRDs (必需):
```
destinationrules.networking.istio.io
gateways.networking.istio.io
virtualservices.networking.istio.io
```

## 三、EdgeCore 最小化配置

### 3.1 必需配置项

根据官方文档 (https://edgemesh.netlify.app/guide/edge-kube-api.html),EdgeCore 必须启用:

```yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
modules:
  # 1. 必须启用 metaServer - EdgeMesh 通过它访问 K8s API
  metaManager:
    metaServer:
      enable: true                    # 必须为 true
      server: 127.0.0.1:10550         # 默认地址

  # 2. 必须启用 edgeStream - 支持 kubectl logs/exec 和云边隧道
  edgeStream:
    enable: true                      # 必须为 true
    server: <CLOUD_IP>:10003          # CloudCore 的 stream 端口
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key

  # 3. 配置 clusterDNS 指向 EdgeMesh DNS
  edged:
    tailoredKubeletConfig:
      clusterDNS:
        - 169.254.96.16               # EdgeMesh DNS 地址 (固定值)
      clusterDomain: cluster.local    # Kubernetes 标准域名
```

### 3.2 不需要的配置

**EdgeCore 不需要配置 CNI**:
```yaml
# ❌ 不需要以下配置 (已从配置中移除):
# networkPluginName: cni
# cniConfDir: /etc/cni/net.d
# cniBinDir: /opt/cni/bin
```

**原因**:
- 边缘节点使用 host 网络模式,更轻量
- EdgeMesh 提供服务网格能力,无需 CNI 插件
- 简化配置,避免网段冲突

### 3.3 关键配置说明

#### 169.254.96.16 的来源

这是 EdgeMesh 的 `bridgeDeviceIP` 默认值 (定义在 `pkg/apis/config/defaults/default.go`):

```go
const (
    BridgeDeviceName = "edgemesh0"
    BridgeDeviceIP   = "169.254.96.16"  // 固定值
)
```

EdgeMesh Agent 启动时会:
1. 创建 `edgemesh0` 网桥设备
2. 绑定 IP `169.254.96.16` 到该设备
3. 启动 DNS 服务监听该 IP:53 端口

**Pod 内的 DNS 配置**:
```
# Pod 的 /etc/resolv.conf
nameserver 169.254.96.16                      # EdgeMesh DNS
search default.svc.cluster.local svc.cluster.local cluster.local
```

## 四、CloudCore 必需配置

根据官方文档,CloudCore 必须启用 dynamicController:

```yaml
apiVersion: cloudcore.config.kubeedge.io/v1alpha2
kind: CloudCore
modules:
  dynamicController:
    enable: true    # 必须为 true,支持 metaServer 功能
```

或使用 keadm 安装时:
```bash
keadm init --advertise-address="$CLOUD_IP" \
  --kubeedge-version=v1.22.0 \
  --set cloudCore.modules.dynamicController.enable=true
```

## 五、离线部署流程

### 5.1 构建阶段

#### Cloud 端构建 (.github/workflows/build-release-cloud.yml)

```yaml
- name: Download EdgeMesh Images
  run: |
    EDGEMESH_VERSION="v1.17.0"
    EDGEMESH_IMAGE="docker.io/kubeedge/edgemesh-agent:${EDGEMESH_VERSION}"
    
    docker pull --platform linux/amd64 "$EDGEMESH_IMAGE"
    docker save "$EDGEMESH_IMAGE" -o "images/docker.io-kubeedge-edgemesh-agent-${EDGEMESH_VERSION}.tar"

- name: Download EdgeMesh Helm Chart
  run: |
    mkdir -p helm-charts
    wget -O helm-charts/edgemesh.tgz \
      "https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/helm/edgemesh.tgz"

- name: Download Istio CRDs
  run: |
    mkdir -p crds/istio
    for crd in destinationrules gateways virtualservices; do
      wget -O "crds/istio/${crd}.yaml" \
        "https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/crds/istio/${crd}.yaml"
    done
```

#### Edge 端构建 (.github/workflows/build-release-edge.yml)

```yaml
- name: Download EdgeMesh Agent Image
  run: |
    EDGEMESH_VERSION="v1.17.0"
    EDGEMESH_IMAGE="docker.io/kubeedge/edgemesh-agent:${EDGEMESH_VERSION}"
    
    docker pull --platform ${{ matrix.dockerfile_platform }} "$EDGEMESH_IMAGE"
    docker save "$EDGEMESH_IMAGE" -o \
      "images/docker.io-kubeedge-edgemesh-agent-${EDGEMESH_VERSION}.tar"
```

### 5.2 Cloud 端安装流程

#### 步骤 1: 安装 K3s + KubeEdge

```bash
#!/bin/bash
# cloud/install/install.sh

# ... (K3s + KubeEdge 安装) ...

echo "[5/7] 启用 CloudCore dynamicController..."
kubectl patch cm cloudcore -n kubeedge --type='json' \
  -p='[{"op": "add", "path": "/data/cloudcore.yaml", "value": "modules:\n  dynamicController:\n    enable: true"}]'

kubectl rollout restart deployment cloudcore -n kubeedge
kubectl rollout status deployment cloudcore -n kubeedge --timeout=120s
```

#### 步骤 2: 安装 Istio CRDs

```bash
echo "[6/7] 安装 Istio CRDs..."
CRD_DIR="$SCRIPT_DIR/crds/istio"
if [ -d "$CRD_DIR" ]; then
  kubectl apply -f "$CRD_DIR/"
  echo "  ✓ Istio CRDs 已安装"
else
  echo "  ✗ 未找到 Istio CRDs 目录"
  exit 1
fi
```

#### 步骤 3: 部署 EdgeMesh (可选但推荐)

```bash
echo "[7/7] 检测 EdgeMesh Helm Chart..."
HELM_CHART_DIR="$SCRIPT_DIR/helm-charts"
EDGEMESH_CHART="$HELM_CHART_DIR/edgemesh.tgz"

if [ -f "$EDGEMESH_CHART" ]; then
  echo "是否安装 EdgeMesh? (y/n): "
  read -r INSTALL_EDGEMESH
  
  if [[ "$INSTALL_EDGEMESH" == "y" ]]; then
    # 生成 PSK 密钥
    EDGEMESH_PSK=$(openssl rand -base64 32)
    
    # 获取 Master 节点名称
    MASTER_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    
    # 使用本地 Helm Chart 安装
    helm install edgemesh "$EDGEMESH_CHART" \
      --namespace kubeedge \
      --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
      --set agent.psk="$EDGEMESH_PSK" \
      --set agent.relayNodes[0].nodeName="$MASTER_NODE" \
      --set agent.relayNodes[0].advertiseAddress="{$CLOUD_IP}"
    
    # 保存 PSK 供边缘节点使用 (可选)
    echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
    echo "  ✓ EdgeMesh 已安装,PSK 已保存到 edgemesh-psk.txt"
  fi
fi
```

**关键点**:
1. 使用本地 Helm Chart 文件路径: `$HELM_CHART_DIR/edgemesh.tgz`
2. 不使用远程 URL
3. PSK 生成后保存,供边缘节点参考 (边缘节点无需配置)

### 5.3 Edge 端安装流程

#### 步骤 1: 导入 EdgeMesh 镜像

```bash
#!/bin/bash
# edge/install/install.sh

echo "[4.5/6] 导入 EdgeMesh Agent 镜像..."
IMAGES_DIR="$SCRIPT_DIR/images"
EDGEMESH_IMAGE_TAR=$(find "$IMAGES_DIR" -name "*edgemesh-agent*.tar" -type f 2>/dev/null | head -1)

if [ -n "$EDGEMESH_IMAGE_TAR" ] && [ -f "$EDGEMESH_IMAGE_TAR" ]; then
  echo "  发现 EdgeMesh Agent 镜像: $(basename $EDGEMESH_IMAGE_TAR)"
  
  # 导入到 containerd (k8s.io namespace)
  if ctr -n k8s.io images import "$EDGEMESH_IMAGE_TAR" >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ EdgeMesh Agent 镜像已导入"
    
    # 验证导入
    ctr -n k8s.io images ls | grep edgemesh >> "$INSTALL_LOG" 2>&1 || true
  else
    echo "  ✗ EdgeMesh Agent 镜像导入失败"
  fi
else
  echo "  ⚠ 未找到 EdgeMesh Agent 镜像文件"
fi
```

**关键点**:
1. 在 EdgeCore 启动前导入镜像
2. 使用 `k8s.io` namespace (Kubernetes 标准命名空间)
3. 边缘节点加入集群后,EdgeMesh DaemonSet 会自动调度 Pod 到该节点
4. Pod 创建时从本地 containerd 拉取镜像,无需访问外网

#### 步骤 2: 配置 EdgeCore

```bash
echo "[5/6] 配置 EdgeCore..."

# 生成 EdgeCore 配置
cat > /tmp/edgecore.yaml <<EOF
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
database:
  dataSource: /var/lib/kubeedge/edgecore.db
modules:
  metaManager:
    metaServer:
      enable: true
      server: 127.0.0.1:10550
  edgeStream:
    enable: true
    server: ${CLOUD_IP}:10003
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
  edged:
    tailoredKubeletConfig:
      clusterDNS:
        - 169.254.96.16
      clusterDomain: cluster.local
      containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
      # 不配置 CNI
EOF

cp /tmp/edgecore.yaml /etc/kubeedge/config/edgecore.yaml
```

#### 步骤 3: 加入集群

```bash
echo "[6/6] 加入 KubeEdge 集群..."
keadm join \
  --cloudcore-ipport="${CLOUD_IP}:10000" \
  --edgenode-name="$EDGE_NODE_NAME" \
  --token="$TOKEN" \
  --kubeedge-version=v1.22.0 \
  --with-mqtt=false \
  --runtimetype=remote \
  --remote-runtime-endpoint=unix:///run/containerd/containerd.sock
```

**自动化流程**:
1. 边缘节点加入集群
2. CloudCore 通知 K8s apiserver 新节点加入
3. EdgeMesh DaemonSet 自动调度 Pod 到新节点
4. kubelet 从本地 containerd 拉取 `kubeedge/edgemesh-agent:v1.17.0`
5. EdgeMesh Agent 启动,创建 edgemesh0 网桥和 DNS 服务
6. 边缘 Pod 自动使用 EdgeMesh DNS (169.254.96.16)

## 六、验证方法

### 6.1 验证 EdgeMesh Agent 运行状态

```bash
# 云端节点
kubectl get pods -n kubeedge -l k8s-app=kubeedge,kubeedge=edgemesh-agent -o wide

# 应该看到所有节点(云+边)都有 edgemesh-agent Pod 运行
NAME                   READY   STATUS    RESTARTS   AGE   IP              NODE
edgemesh-agent-xxxxx   1/1     Running   0          2m    192.168.0.100   cloud-master
edgemesh-agent-yyyyy   1/1     Running   0          1m    192.168.5.10    edge-node-1
```

### 6.2 验证 Edge Kube-API Endpoint

```bash
# 边缘节点
curl http://127.0.0.1:10550/api/v1/services

# 应该返回 Service 列表 (JSON 格式)
```

### 6.3 验证 EdgeMesh DNS

```bash
# 在边缘节点创建测试 Pod
kubectl run test-dns --image=busybox:1.28 --restart=Never --rm -it \
  --overrides='{"spec":{"nodeName":"edge-node-1"}}' -- sh

# 在 Pod 内检查 DNS
/ # cat /etc/resolv.conf
nameserver 169.254.96.16
search default.svc.cluster.local svc.cluster.local cluster.local

/ # nslookup kubernetes
Server:    169.254.96.16
Address 1: 169.254.96.16

Name:      kubernetes
Address 1: 10.43.0.1 kubernetes.default.svc.cluster.local
```

### 6.4 验证 edgemesh0 网桥

```bash
# 边缘节点
ip addr show edgemesh0

# 应该显示:
# edgemesh0: <BROADCAST,MULTICAST,UP,LOWER_UP>
#     inet 169.254.96.16/32 ...
```

### 6.5 验证跨节点服务访问

```bash
# 在云端部署测试服务
kubectl create deployment nginx --image=nginx:alpine --replicas=2
kubectl expose deployment nginx --port=80

# 在边缘 Pod 内访问
kubectl run test-client --image=busybox:1.28 --restart=Never --rm -it \
  --overrides='{"spec":{"nodeName":"edge-node-1"}}' -- sh

/ # wget -O- http://nginx.default.svc.cluster.local
# 应该成功返回 nginx 页面
```

## 七、故障排查

### 7.1 EdgeMesh Agent Pod 未调度到边缘节点

**症状**:
```bash
kubectl get pods -n kubeedge -o wide | grep edge-node-1
# 没有 edgemesh-agent Pod
```

**排查步骤**:
1. 检查 DaemonSet 状态
```bash
kubectl describe daemonset edgemesh-agent -n kubeedge
```

2. 检查节点标签和污点
```bash
kubectl describe node edge-node-1 | grep -A 5 Taints
```

3. 检查镜像是否导入
```bash
# 在边缘节点
ctr -n k8s.io images ls | grep edgemesh
```

### 7.2 EdgeMesh Agent 启动失败

**症状**:
```bash
kubectl logs -n kubeedge edgemesh-agent-xxxxx
# Error: failed to create edgemesh device edgemesh0
```

**原因**:
- EdgeCore 的 `clusterDNS` 未配置为 `169.254.96.16`
- 或者 metaServer 未启用

**解决方法**:
```bash
# 边缘节点
vim /etc/kubeedge/config/edgecore.yaml
# 确保:
# modules.metaManager.metaServer.enable: true
# modules.edged.tailoredKubeletConfig.clusterDNS[0]: 169.254.96.16

systemctl restart edgecore
```

### 7.3 DNS 解析失败

**症状**:
```bash
# 在边缘 Pod 内
/ # nslookup kubernetes.default.svc.cluster.local
Server:    169.254.96.16
Address 1: 169.254.96.16

nslookup: can't resolve 'kubernetes.default.svc.cluster.local'
```

**排查步骤**:
1. 检查 metaServer 是否正常
```bash
# 边缘节点
curl http://127.0.0.1:10550/api/v1/services
```

2. 检查 EdgeMesh Agent 日志
```bash
kubectl logs -n kubeedge edgemesh-agent-xxxxx | grep -i dns
```

3. 检查 edgemesh0 网桥
```bash
# 边缘节点
ip addr show edgemesh0
netstat -tulnp | grep 169.254.96.16
```

### 7.4 跨节点服务访问失败

**症状**:
```bash
# 边缘 Pod 无法访问云端服务
/ # wget -O- http://nginx.default.svc.cluster.local
wget: can't connect to remote host (10.43.xx.xx): No route to host
```

**排查步骤**:
1. 检查 EdgeMesh Tunnel 状态
```bash
kubectl logs -n kubeedge edgemesh-agent-xxxxx | grep -i tunnel
# 应该看到: Tunnel connection established
```

2. 检查中继节点配置
```bash
kubectl get cm edgemesh-agent-cfg -n kubeedge -o yaml | grep -A 10 relayNodes
```

3. 检查云边连接
```bash
# 云端节点
kubectl logs -n kubeedge cloudcore-xxx | grep -i edge-node-1
# 应该看到: edge-node-1 connected
```

## 八、与原方案的差异

### 8.1 镜像数量对比

| 方案 | Cloud 镜像数 | Edge 镜像数 | 说明 |
|------|-------------|------------|------|
| **新方案** | 13个 | 2个 | ✅ 仅 EdgeMesh Agent + MQTT |
| 原方案 | 13个 | 2个 | 相同 |

### 8.2 配置复杂度对比

| 配置项 | 新方案 | 原方案 | 说明 |
|--------|--------|--------|------|
| **EdgeCore CNI** | 不配置 | 配置但不使用 | ✅ 简化配置 |
| **metaServer** | 必需 | 必需 | 相同 |
| **edgeStream** | 必需 | 必需 | 相同 |
| **clusterDNS** | 169.254.96.16 | 169.254.96.16 | 相同 |

### 8.3 部署方式对比

| 步骤 | 新方案 | 原方案 | 说明 |
|------|--------|--------|------|
| **Istio CRDs** | ✅ 必需安装 | ❌ 未提及 | 🔴 关键差异 |
| **EdgeMesh Helm** | ✅ 使用本地 Chart | ✅ 使用本地 Chart | 相同 |
| **Edge 镜像导入** | ✅ 自动导入 | ✅ 自动导入 | 相同 |
| **CloudCore dynamicController** | ✅ 必需启用 | ❌ 未配置 | 🔴 关键差异 |

### 8.4 关键改进点

#### 1. 明确 Istio CRDs 依赖 (🔴 重大遗漏修复)

**原方案问题**: 未安装 Istio CRDs,导致 EdgeMesh 无法正常工作

**新方案**:
- 在 cloud build 阶段下载 CRDs
- 在 cloud install 阶段安装 CRDs
- 这是 EdgeMesh 手动安装的**第二步骤**(官方文档明确要求)

```bash
# 必须执行
kubectl apply -f build/crds/istio/
```

#### 2. CloudCore dynamicController 配置 (🔴 重大遗漏修复)

**原方案问题**: 未启用 `dynamicController`,导致 metaServer 功能不完整

**新方案**:
```yaml
# CloudCore 配置
modules:
  dynamicController:
    enable: true  # 必须启用
```

**验证方法**:
```bash
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 2 dynamicController
```

#### 3. CNI 配置简化

**原方案**: EdgeCore 配置中包含 CNI 相关字段但实际不使用

**新方案**: 完全移除 CNI 配置,避免混淆
- 不配置 `networkPluginName`
- 不配置 `cniConfDir`
- 不配置 `cniBinDir`

**理由**: 边缘节点使用 host 网络模式,EdgeMesh 提供服务网格能力

#### 4. 文档结构优化

**新方案结构**:
1. 架构理解 → 2. 必需组件清单 → 3. 最小化配置 → 4. 部署流程 → 5. 验证方法 → 6. 故障排查

**优势**:
- 先理解后实践
- 明确必需vs可选
- 配置最小化原则
- 完整验证链条

## 九、参考资料

### 官方文档

1. EdgeMesh 快速上手: https://edgemesh.netlify.app/guide/
2. EdgeMesh 边缘 Kube-API 端点: https://edgemesh.netlify.app/guide/edge-kube-api.html
3. EdgeMesh Helm 配置: https://edgemesh.netlify.app/reference/config-items.html
4. EdgeMesh GitHub: https://github.com/kubeedge/edgemesh

### 配置文件示例

1. EdgeMesh Helm Chart: `build/helm/edgemesh/README.md`
2. EdgeMesh Agent 手动安装: `build/agent/resources/`
3. Istio CRDs: `build/crds/istio/`

### 架构理解

1. EdgeMesh 架构图: `docs/.vuepress/public/images/arch.png`
2. EdgeMesh v1.12.0+ 合并 edgemesh-server 功能

## 十、总结

### 核心要点

1. **Istio CRDs 是必需的**: 必须在部署 EdgeMesh 前安装
2. **CloudCore dynamicController 必须启用**: 支持 metaServer 功能
3. **EdgeCore 最小化配置**: 仅启用 metaServer + edgeStream + clusterDNS
4. **不需要 CNI**: 边缘节点使用 host 网络模式
5. **完全离线**: EdgeMesh 镜像和 Helm Chart 预先打包,无需外网

### 部署检查清单

**Cloud 端**:
- [ ] K3s 安装完成
- [ ] KubeEdge CloudCore 安装完成
- [ ] CloudCore `dynamicController.enable=true`
- [ ] Istio CRDs 已安装 (3个)
- [ ] EdgeMesh Helm Chart 已安装
- [ ] EdgeMesh Agent DaemonSet 运行在 Master 节点

**Edge 端**:
- [ ] containerd 安装完成
- [ ] EdgeMesh Agent 镜像已导入
- [ ] EdgeCore 配置正确 (metaServer + edgeStream + clusterDNS)
- [ ] EdgeCore 成功加入集群
- [ ] EdgeMesh Agent Pod 自动调度并运行
- [ ] edgemesh0 网桥已创建 (169.254.96.16)
- [ ] DNS 解析正常

### 与原方案的主要改进

1. ✅ **补充 Istio CRDs 安装步骤** - 原方案遗漏
2. ✅ **补充 CloudCore dynamicController 配置** - 原方案遗漏
3. ✅ **简化 EdgeCore 配置** - 移除不必要的 CNI 配置
4. ✅ **明确必需vs可选组件** - 避免过度配置
5. ✅ **完善验证和故障排查** - 提供完整验证链条

此方案严格遵循 EdgeMesh 官方文档,确保离线环境下的可靠部署。
