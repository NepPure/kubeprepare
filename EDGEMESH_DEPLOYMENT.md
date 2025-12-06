# EdgeMesh 离线部署完整指南

## 概述

EdgeMesh 是 KubeEdge 的边缘服务网格组件，为边缘节点提供服务发现、流量代理、跨边缘网络通信等能力。

**核心原则**:
- ✅ **完全离线**: 整个安装部署过程无需外网访问，只需 cloud 和 edge 之间网络互通
- ✅ **最小化依赖**: 仅安装必需的组件和镜像
- ✅ **简化配置**: EdgeCore 配置最小化，避免不必要的复杂性
- ✅ **官方兼容**: 严格遵循 EdgeMesh 官方安装流程和配置要求

**重要说明**: 
- 边缘节点使用 **host 网络模式**，不需要 CNI 插件
- EdgeMesh 提供边缘服务网格和服务发现能力
- EdgeMesh 已从 EdgeCore 解耦，需要独立部署
- **本文档已整合官方最佳实践和完整的离线部署流程**

## EdgeMesh 架构理解

### 组件说明

EdgeMesh 包含以下核心组件:

- **edgemesh-agent**: 以 DaemonSet 方式运行在所有节点(云+边缘)
  - **Proxier**: 配置 iptables 规则，拦截请求
  - **DNS**: 内置 DNS 解析器，解析服务域名为 ClusterIP
  - **LoadBalancer**: 负载均衡器，支持多种策略
  - **Controller**: 通过 metaServer 或 K8s apiserver 获取元数据
  - **Tunnel**: 提供云边通信隧道(v1.12.0+ 合并了 edgemesh-server 功能)

- **edgemesh-gateway** (可选): Ingress 网关，提供外部访问入口

### 架构图

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
│  │  - dynamicController│  │  │    - clusterDNS          │   │
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

## 必需组件清单

### 镜像清单

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
kubeedge/edgemesh-agent:v1.17.0
eclipse-mosquitto:2.0  # 可选，用于 IoT 设备管理
```

### Istio CRDs (必需)

EdgeMesh 依赖以下 Istio CRDs：
```
destinationrules.networking.istio.io
gateways.networking.istio.io
virtualservices.networking.istio.io
```

**这些 CRDs 必须在部署 EdgeMesh 前安装！**

## 前置条件

### 1. CloudCore 配置要求

**必须启用 dynamicController**（支持 metaServer 功能）:

```yaml
# /etc/kubeedge/config/cloudcore.yaml 或 ConfigMap
apiVersion: cloudcore.config.kubeedge.io/v1alpha2
kind: CloudCore
modules:
  dynamicController:
    enable: true    # ⚠️ 必须为 true
```

✅ 我们的安装脚本已自动配置此项

### 2. EdgeCore 配置要求（最小化配置）

EdgeCore 必须启用以下模块:

```yaml
# /etc/kubeedge/config/edgecore.yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
modules:
  # 1. 必须启用 metaServer - EdgeMesh 通过它访问 K8s API
  metaManager:
    metaServer:
      enable: true                    # ⚠️ 必须为 true
      server: 127.0.0.1:10550         # 默认地址

  # 2. 必须启用 edgeStream - 支持 kubectl logs/exec 和云边隧道
  edgeStream:
    enable: true                      # ⚠️ 必须为 true
    server: <CLOUD_IP>:10003          # CloudCore 的 stream 端口
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key

  # 3. 配置 clusterDNS 指向 EdgeMesh DNS
  edged:
    tailoredKubeletConfig:
      clusterDNS:
        - 169.254.96.16               # ⚠️ EdgeMesh DNS 地址 (固定值)
      clusterDomain: cluster.local
```

✅ 这些配置已在我们的安装脚本中自动完成

**不需要配置 CNI**:
```yaml
# ❌ 不需要以下配置:
# networkPluginName: cni
# cniConfDir: /etc/cni/net.d
# cniBinDir: /opt/cni/bin
```

**原因**: 边缘节点使用 host 网络模式，EdgeMesh 提供服务网格能力，无需 CNI 插件

### 3. 169.254.96.16 的来源

这是 EdgeMesh 的 `bridgeDeviceIP` 默认值 (定义在 EdgeMesh 源码 `pkg/apis/config/defaults/default.go`):

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

Pod 内的 DNS 配置:
```
# Pod 的 /etc/resolv.conf
nameserver 169.254.96.16
search default.svc.cluster.local svc.cluster.local cluster.local
```

### 4. Helm 3 安装（可选）

如果需要手动部署 EdgeMesh，需要在云端节点上安装 Helm 3:
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

自动部署时会使用离线包中的 Helm chart，无需安装 Helm。

## 离线部署流程

### 安装顺序说明

**Cloud 端安装顺序**:
1. K3s 安装
2. K3s 镜像导入
3. Kubernetes API 就绪等待
4. KubeEdge namespace 创建
5. **[关键] Istio CRDs 安装** ← 必须在 EdgeMesh 之前
6. KubeEdge CloudCore 安装
7. **[关键] CloudCore dynamicController 启用** ← 必须启用
8. Edge Token 生成
9. EdgeMesh 安装 (可选)

**Edge 端安装顺序**:
1. containerd/runc 安装
2. **EdgeMesh Agent 镜像预导入** ← DaemonSet 会使用
3. Mosquitto MQTT 镜像导入 (可选)
4. EdgeCore 安装和配置
5. EdgeCore 启动并加入集群

### 方式一: 自动部署 (推荐 - 完全离线)

在 cloud 节点安装过程中，安装脚本会自动检测 EdgeMesh Helm Chart 并提示是否安装:

```bash
cd /data/kubeedge-cloud-xxx
sudo ./install.sh

# 当提示时，选择 y 安装 EdgeMesh
=== 7. 安装 EdgeMesh (可选) ===
检测到 EdgeMesh Helm Chart，是否安装 EdgeMesh? (y/n)
y
```

安装脚本会自动:
- ✅ **安装 Istio CRDs** (步骤 5.5) - EdgeMesh 依赖
- ✅ **启用 CloudCore dynamicController** (步骤 6.5) - metaServer 功能
- ✅ 使用离线包中的 EdgeMesh 镜像 (无需外网)
- ✅ 使用离线包中的 Helm Chart (无需外网)
- ✅ 自动生成 PSK 密码
- ✅ 自动配置中继节点
- ✅ 保存 PSK 到 `edgemesh-psk.txt` 文件

**完全离线**: EdgeMesh 镜像、Helm Chart 和 Istio CRDs 已预先打包在 cloud 离线安装包中，整个部署过程无需任何外网连接。

**Edge 端自动流程**:
1. 安装脚本自动导入 EdgeMesh Agent 镜像到 containerd
2. 边缘节点加入集群后，EdgeMesh DaemonSet 自动调度 Pod
3. Pod 从本地 containerd 拉取镜像，无需外网访问
4. EdgeMesh Agent 自动启动，创建 edgemesh0 网桥和 DNS 服务

### 方式二: 手动部署 (高级用户)

#### 1. 安装 Istio CRDs（必需）

**⚠️ 这是 EdgeMesh 官方手动安装的第二步骤，必须执行！**

```bash
# 使用离线包中的 CRDs
cd /data/kubeedge-cloud-xxx
kubectl apply -f crds/istio/

# 验证安装
kubectl get crd | grep istio
# 应该看到:
# destinationrules.networking.istio.io
# gateways.networking.istio.io
# virtualservices.networking.istio.io
```

#### 2. 启用 CloudCore dynamicController（必需）

**⚠️ 必须启用，否则 metaServer 功能不完整！**

```bash
# 检查当前状态
kubectl -n kubeedge get cm cloudcore -o yaml | grep -A 2 dynamicController

# 如果 enable: false，则修补配置
kubectl -n kubeedge patch cm cloudcore --type=json -p='[{
  "op": "replace",
  "path": "/data/cloudcore.yaml",
  "value": "modules:\n  dynamicController:\n    enable: true\n"
}]'

# 重启 CloudCore 使配置生效
kubectl -n kubeedge delete pod -l kubeedge=cloudcore

# 等待 CloudCore 就绪
kubectl -n kubeedge get pod -w
```

#### 3. 准备 PSK 密码

生成 PSK 密码用于 EdgeMesh 组件间通信加密:
```bash
openssl rand -base64 32
# 示例输出: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

保存此密码，后续部署时需要使用。

#### 4. 确定中继节点

EdgeMesh 高可用模式需要配置中继节点。选择一个或多个云端节点作为中继节点:
```bash
# 查看节点列表
kubectl get nodes

# 获取云端节点的公网IP或内网IP
kubectl get node <node-name> -o wide
```

#### 5. 部署 EdgeMesh Agent (使用离线 Chart)

EdgeMesh Agent 以 DaemonSet 形式运行在所有节点(云+边缘)上。

**使用离线 Helm Chart (推荐):**
```bash
# 使用 cloud 安装包中的离线 Helm Chart
cd /data/kubeedge-cloud-xxx
helm install edgemesh ./helm-charts/edgemesh.tgz \
  --namespace kubeedge \
  --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
  --set agent.psk=<your-psk-string> \
  --set agent.relayNodes[0].nodeName=k8s-master \
  --set agent.relayNodes[0].advertiseAddress="{152.136.201.36}"
```

**单中继节点配置 (使用在线 Chart - 需要外网):**
```bash
helm install edgemesh --namespace kubeedge \
  --set agent.psk=<your-psk-string> \
  --set agent.relayNodes[0].nodeName=k8s-master \
  --set agent.relayNodes[0].advertiseAddress="{152.136.201.36}" \
  https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/helm/edgemesh.tgz
```

**多中继节点配置 (高可用 - 使用离线 Chart):**
```bash
cd /data/kubeedge-cloud-xxx
helm install edgemesh ./helm-charts/edgemesh.tgz \
  --namespace kubeedge \
  --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
  --set agent.psk=<your-psk-string> \
  --set agent.relayNodes[0].nodeName=k8s-master \
  --set agent.relayNodes[0].advertiseAddress="{152.136.201.36}" \
  --set agent.relayNodes[1].nodeName=k8s-node1 \
  --set agent.relayNodes[1].advertiseAddress="{152.136.201.37,10.0.0.2}" \
  https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/helm/edgemesh.tgz
```

参数说明:
- `agent.psk`: 加密通信密码 (必须)
- `agent.relayNodes[i].nodeName`: 中继节点名称 (必须与 K8s 节点名一致)
- `agent.relayNodes[i].advertiseAddress`: 中继节点地址列表 (公网IP或内网IP)

#### 4. 验证部署

检查 EdgeMesh Agent 运行状态:
```bash
# 查看 Helm 部署
helm ls -n kubeedge

# 查看 Pod 状态
kubectl get pods -n kubeedge -l k8s-app=kubeedge,kubeedge=edgemesh-agent -o wide

# 应该看到所有节点上都有 edgemesh-agent Pod 运行
# NAME                       READY   STATUS    RESTARTS   AGE   NODE
# edgemesh-agent-xxxx        1/1     Running   0          1m    cloud-test
# edgemesh-agent-yyyy        1/1     Running   0          1m    edge-test
```

查看日志:
```bash
kubectl logs -n kubeedge -l kubeedge=edgemesh-agent --tail=50
```

### 方式二: 手动部署

#### 1. 克隆 EdgeMesh 仓库

```bash
git clone https://github.com/kubeedge/edgemesh.git
cd edgemesh
```

#### 2. 安装 CRDs

```bash
kubectl apply -f build/crds/istio/
```

#### 3. 配置并部署 EdgeMesh Agent

编辑 `build/agent/resources/04-configmap.yaml`:
```yaml
# 配置中继节点
relayNodes:
  - nodeName: k8s-master
    advertiseAddress:
      - 152.136.201.36

# 生成并配置 PSK 密码
psk: <your-psk-string>
```

部署:
```bash
kubectl apply -f build/agent/resources/
```

## 部署验证

### 1. 验证 Istio CRDs 安装

```bash
kubectl get crd | grep istio
# 应该看到:
# destinationrules.networking.istio.io
# gateways.networking.istio.io
# virtualservices.networking.istio.io
```

### 2. 验证 CloudCore dynamicController

```bash
# 方法 1: 检查 ConfigMap
kubectl -n kubeedge get cm cloudcore -o yaml | grep -A 2 dynamicController

# 方法 2: 检查配置文件
grep -A 2 "dynamicController:" /etc/kubeedge/config/cloudcore.yaml

# 应该看到:
# dynamicController:
#   enable: true
```

### 3. 验证 EdgeMesh Agent 运行状态

```bash
# 云端节点
kubectl get pods -n kubeedge -l k8s-app=kubeedge,kubeedge=edgemesh-agent -o wide

# 应该看到所有节点(云+边)都有 edgemesh-agent Pod 运行
NAME                   READY   STATUS    RESTARTS   AGE   IP              NODE
edgemesh-agent-xxxxx   1/1     Running   0          2m    192.168.0.100   cloud-master
edgemesh-agent-yyyyy   1/1     Running   0          1m    192.168.5.10    edge-node-1
```

查看日志:
```bash
kubectl logs -n kubeedge -l kubeedge=edgemesh-agent --tail=50
```

### 4. 验证 EdgeMesh Agent 镜像（Edge 节点）

```bash
# 在 edge 节点上
ctr -n k8s.io images ls | grep edgemesh
# 应该看到:
# docker.io/kubeedge/edgemesh-agent:v1.17.0
```

### 5. 验证 Edge Kube-API Endpoint

```bash
# 边缘节点
curl http://127.0.0.1:10550/api/v1/services

# 应该返回 Service 列表 (JSON 格式)
```

### 6. 验证 EdgeMesh DNS

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

### 7. 验证 edgemesh0 网桥

```bash
# 边缘节点
ip addr show edgemesh0

# 应该显示:
# edgemesh0: <BROADCAST,MULTICAST,UP,LOWER_UP>
#     inet 169.254.96.16/32 ...
```

## 功能测试

### 测试边缘服务发现

1. 部署测试应用:
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hostname-edge
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hostname
  template:
    metadata:
      labels:
        app: hostname
    spec:
      containers:
      - name: hostname
        image: registry.cn-hangzhou.aliyuncs.com/kubeedge/hostname:v1.0
        ports:
        - containerPort: 9376
---
apiVersion: v1
kind: Service
metadata:
  name: hostname-svc
spec:
  selector:
    app: hostname
  ports:
  - port: 12345
    targetPort: 9376
EOF
```

2. 测试服务访问:
```bash
# 在边缘节点或云端节点创建测试 Pod
kubectl run test-pod --image=busybox:1.28 --restart=Never -- sleep 3600

# 进入测试 Pod
kubectl exec -it test-pod -- sh

# 测试服务发现
nslookup hostname-svc
# 应该解析到 EdgeMesh DNS (169.254.96.16)

# 测试服务访问
wget -O- http://hostname-svc:12345
# 应该返回 hostname
```

## EdgeMesh Gateway (可选)

如果需要边缘入口网关功能，可以部署 EdgeMesh Gateway:

```bash
helm install edgemesh-gateway --namespace kubeedge \
  --set nodeName=<gateway-node-name> \
  --set psk=<your-psk-string> \
  --set relayNodes[0].nodeName=k8s-master \
  --set relayNodes[0].advertiseAddress="{152.136.201.36}" \
  https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/helm/edgemesh-gateway.tgz
```

## EdgeMesh CNI 功能 (可选)

如果需要跨云边容器网络通信，可以启用 EdgeMesh CNI 功能:

### 1. 安装统一 IPAM 插件 SpiderPool

```bash
helm repo add spiderpool https://spidernet-io.github.io/spiderpool

IPV4_SUBNET="10.244.0.0/16"
IPV4_IPRANGES="10.244.0.0-10.244.255.254"

helm install spiderpool spiderpool/spiderpool --wait --namespace kube-system \
  --set multus.multusCNI.install=false \
  --set spiderpoolAgent.image.registry=ghcr.m.daocloud.io \
  --set spiderpoolController.image.registry=ghcr.m.daocloud.io \
  --set spiderpoolInit.image.registry=ghcr.m.daocloud.io \
  --set ipam.enableStatefulSet=false \
  --set ipam.enableIPv4=true \
  --set ipam.enableIPv6=false \
  --set clusterDefaultPool.installIPv4IPPool=true \
  --set clusterDefaultPool.ipv4Subnet=${IPV4_SUBNET} \
  --set clusterDefaultPool.ipv4IPRanges={${IPV4_IPRANGES}}
```

### 2. 启用 EdgeMesh CNI

```bash
helm install edgemesh --namespace kubeedge \
  --set agent.psk=<your-psk-string> \
  --set agent.relayNodes[0].nodeName=k8s-master \
  --set agent.relayNodes[0].advertiseAddress="{152.136.201.36}" \
  --set agent.meshCIDRConfig.cloudCIDR="{10.244.0.0/18}" \
  --set agent.meshCIDRConfig.edgeCIDR="{10.244.64.0/18}" \
  https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/helm/edgemesh.tgz
```

参数说明:
- `cloudCIDR`: 云端容器网段
- `edgeCIDR`: 边缘容器网段

## 卸载

```bash
# 卸载 EdgeMesh Agent
helm uninstall edgemesh -n kubeedge

# 卸载 EdgeMesh Gateway (如果已部署)
helm uninstall edgemesh-gateway -n kubeedge
```

## 故障排查

### 问题 1: EdgeMesh Pod CrashLoopBackOff

**症状**:
```bash
kubectl get pods -n kubeedge | grep edgemesh
edgemesh-agent-xxxxx   0/1     CrashLoopBackOff   3          2m
```

**可能原因**: Istio CRDs 未安装

**解决方案**:
```bash
# 检查 CRDs
kubectl get crd | grep istio

# 如果缺失，手动安装
cd /data/kubeedge-cloud-xxx
kubectl apply -f crds/istio/destinationrules.yaml
kubectl apply -f crds/istio/gateways.yaml
kubectl apply -f crds/istio/virtualservices.yaml

# 重启 EdgeMesh Pod
kubectl -n kubeedge delete pod -l kubeedge=edgemesh-agent
```

### 问题 2: 边缘节点 metaServer 无法访问

**症状**:
```bash
# 边缘节点
curl http://127.0.0.1:10550/api/v1/services
# Connection refused
```

**可能原因**: CloudCore dynamicController 未启用

**解决方案**:
```bash
# 检查配置
kubectl -n kubeedge get cm cloudcore -o yaml | grep -A 2 dynamicController

# 如果为 false，手动启用
kubectl -n kubeedge edit cm cloudcore
# 修改 dynamicController.enable 为 true

# 重启 CloudCore
kubectl -n kubeedge delete pod -l kubeedge=cloudcore

# 在边缘节点重启 EdgeCore
systemctl restart edgecore
```

### 问题 3: EdgeMesh Agent Pod 未调度到边缘节点

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

**解决方案**: 如果镜像未导入
```bash
# 在 edge 节点上手动导入
cd /data/kubeedge-edge-xxx
ctr -n k8s.io images import images/docker.io-kubeedge-edgemesh-agent-v1.17.0.tar

# 验证
ctr -n k8s.io images ls | grep edgemesh
```

### 问题 4: EdgeMesh Agent 启动失败

**症状**:
```bash
kubectl logs -n kubeedge edgemesh-agent-xxxxx
# Error: failed to create edgemesh device edgemesh0
```

**可能原因**:
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

### 问题 5: DNS 解析失败

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

### 问题 6: 跨节点服务访问失败

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

### 问题 7: EdgeMesh 镜像拉取失败

**症状**:
```bash
kubectl describe pod edgemesh-agent-xxxxx -n kubeedge
# Events: Failed to pull image "kubeedge/edgemesh-agent:v1.17.0"
```

**解决方案**:
```bash
# 在对应节点上检查镜像
ctr -n k8s.io images ls | grep edgemesh

# 如果镜像不存在，手动导入
# Cloud 节点
/usr/local/bin/k3s ctr images import /path/to/images/docker.io-kubeedge-edgemesh-agent-v1.17.0.tar

# Edge 节点
ctr -n k8s.io images import /path/to/images/docker.io-kubeedge-edgemesh-agent-v1.17.0.tar
```

## 离线包结构

### Cloud 端离线包

```
kubeedge-cloud-1.22.0-k3s-1.34.2+k3s1-amd64.tar.gz
├── k3s-amd64
├── cloudcore
├── keadm
├── images/
│   ├── (K3s 镜像 - 8个)
│   ├── (KubeEdge 镜像 - 4个)
│   └── docker.io-kubeedge-edgemesh-agent-v1.17.0.tar
├── helm-charts/
│   └── edgemesh.tgz                    # EdgeMesh Helm Chart
├── crds/                               # [关键新增]
│   └── istio/                          # [关键新增]
│       ├── destinationrules.yaml       # [关键新增]
│       ├── gateways.yaml               # [关键新增]
│       └── virtualservices.yaml        # [关键新增]
├── install.sh
├── install-kubeedge-only.sh
├── cleanup.sh
└── README.txt
```

### Edge 端离线包

```
kubeedge-edge-1.22.0-amd64.tar.gz
├── edgecore
├── keadm
├── bin/
│   ├── containerd
│   ├── containerd-shim-runc-v2
│   └── ctr
├── runc
├── images/
│   ├── docker.io-kubeedge-edgemesh-agent-v1.17.0.tar  # EdgeMesh Agent
│   └── eclipse-mosquitto-2.0.tar                      # MQTT (可选)
├── meta/
│   └── version.txt
├── install.sh
└── cleanup.sh
```

## 部署检查清单

### Cloud 端检查清单

- [ ] K3s 安装完成
- [ ] KubeEdge CloudCore 安装完成
- [ ] **CloudCore `dynamicController.enable=true`** ⚠️
- [ ] **Istio CRDs 已安装 (3个)** ⚠️
- [ ] EdgeMesh Helm Chart 已安装
- [ ] EdgeMesh Agent DaemonSet 运行在 Master 节点
- [ ] Edge Token 已生成

### Edge 端检查清单

- [ ] containerd 安装完成
- [ ] **EdgeMesh Agent 镜像已导入** ⚠️
- [ ] EdgeCore 配置正确 (metaServer + edgeStream + clusterDNS)
- [ ] EdgeCore 成功加入集群
- [ ] EdgeMesh Agent Pod 自动调度并运行
- [ ] **edgemesh0 网桥已创建 (169.254.96.16)** ⚠️
- [ ] DNS 解析正常

## 关键改进说明

本文档整合了官方最佳实践，相比早期方案的主要改进：

### 1. ✅ 补充 Istio CRDs 安装步骤
- **原问题**: 未安装 Istio CRDs，导致 EdgeMesh 无法正常工作
- **新方案**: 
  - 在 cloud build 阶段下载 CRDs
  - 在 cloud install 步骤 5.5 安装 CRDs
  - 这是 EdgeMesh 官方手动安装的**必需步骤**

### 2. ✅ 补充 CloudCore dynamicController 配置
- **原问题**: 未启用 `dynamicController`，导致 metaServer 功能不完整
- **新方案**: 
  - 在 cloud install 步骤 6.5 启用 dynamicController
  - 支持 ConfigMap 补丁和配置文件修改
  - 自动重启 CloudCore 使配置生效

### 3. ✅ 简化 EdgeCore 配置
- **原问题**: EdgeCore 配置中包含 CNI 相关字段但实际不使用
- **新方案**: 完全移除 CNI 配置，避免混淆
  - 不配置 `networkPluginName`
  - 不配置 `cniConfDir`
  - 不配置 `cniBinDir`
- **理由**: 边缘节点使用 host 网络模式，EdgeMesh 提供服务网格能力

### 4. ✅ 明确必需 vs 可选组件
- **EdgeMesh Agent 镜像**: 必需，预导入到 containerd
- **Istio CRDs**: 必需，在 EdgeMesh 安装前安装
- **dynamicController**: 必需，支持 metaServer 功能
- **Mosquitto MQTT**: 可选，用于 IoT 设备管理
- **EdgeMesh Gateway**: 可选，用于外部访问入口

### 5. ✅ 完善验证和故障排查
- 提供完整的部署验证链条
- 7 个常见问题的详细排查步骤
- 每个问题都包含症状、原因、解决方案

## 参考文档

### 官方文档
- [EdgeMesh 官方文档](https://edgemesh.netlify.app/)
- [EdgeMesh GitHub 仓库](https://github.com/kubeedge/edgemesh)
- [EdgeMesh 快速上手](https://edgemesh.netlify.app/guide/)
- [EdgeMesh 配置参考](https://edgemesh.netlify.app/reference/config-items.html)
- [边缘 Kube-API 端点](https://edgemesh.netlify.app/guide/edge-kube-api.html)
- [KubeEdge 官方文档](https://kubeedge.io/docs/)

### 配置文件示例
- EdgeMesh Helm Chart: `build/helm/edgemesh/README.md`
- EdgeMesh Agent 手动安装: `build/agent/resources/`
- Istio CRDs: `build/crds/istio/`

## 兼容性说明

- **KubeEdge**: v1.22.0
- **EdgeMesh**: v1.17.0
- **K3s**: v1.34.2+k3s1
- **Istio CRDs**: 来自 EdgeMesh v1.17.0 官方仓库
- **架构**: amd64, arm64

## 最佳实践

1. **生产环境配置多个中继节点**以实现高可用
2. **使用稳定的公网IP**作为中继节点地址
3. **定期备份 PSK 密码**，所有 EdgeMesh 组件必须使用相同的 PSK
4. **监控 EdgeMesh 日志**以及时发现问题
5. **边缘节点使用 host 网络**，不要配置 CNI (除非有特殊需求)
6. **确保 Istio CRDs 在 EdgeMesh 之前安装**
7. **确保 CloudCore dynamicController 已启用**

## 总结

### 核心要点

1. **Istio CRDs 是必需的**: 必须在部署 EdgeMesh 前安装 (步骤 5.5)
2. **CloudCore dynamicController 必须启用**: 支持 metaServer 功能 (步骤 6.5)
3. **EdgeCore 最小化配置**: 仅启用 metaServer + edgeStream + clusterDNS
4. **不需要 CNI**: 边缘节点使用 host 网络模式
5. **完全离线**: EdgeMesh 镜像、Helm Chart 和 Istio CRDs 预先打包，无需外网
6. **自动化部署**: Cloud 和 Edge 安装脚本自动完成所有配置

### 与原方案的关键差异

| 项目 | 原方案 | 新方案（本文档） | 说明 |
|------|--------|-----------------|------|
| Istio CRDs | ❌ 未提及 | ✅ 必需安装 | 🔴 关键差异 |
| dynamicController | ❌ 未配置 | ✅ 必需启用 | 🔴 关键差异 |
| EdgeCore CNI | ⚠️ 配置但不使用 | ✅ 不配置 | 简化配置 |
| Edge 镜像导入 | ✅ 自动导入 | ✅ 自动导入 | 相同 |
| 验证方法 | ⚠️ 部分 | ✅ 完整 | 7步验证 |
| 故障排查 | ⚠️ 简单 | ✅ 详细 | 7个问题 |

### 部署成功标志

✅ 所有节点上 EdgeMesh Agent Pod 运行正常  
✅ Istio CRDs 已安装 (3个)  
✅ CloudCore dynamicController 已启用  
✅ 边缘节点 metaServer 可访问 (127.0.0.1:10550)  
✅ edgemesh0 网桥已创建 (169.254.96.16)  
✅ Pod 的 DNS 解析到 EdgeMesh DNS  
✅ 跨节点服务访问正常  

此方案严格遵循 EdgeMesh 官方文档，确保离线环境下的可靠部署。
