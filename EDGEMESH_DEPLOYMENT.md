# EdgeMesh 部署指南

## 概述

EdgeMesh 是 KubeEdge 的边缘服务网格组件，为边缘节点提供服务发现、流量代理、跨边缘网络通信等能力。

**重要说明**: 
- 边缘节点使用 **host 网络模式**，不需要 CNI 插件
- EdgeMesh 提供边缘服务网格和服务发现能力
- EdgeMesh 已从 EdgeCore 解耦，需要独立部署

## 前置条件

### 1. KubeEdge 环境要求

- KubeEdge >= v1.7.0 (推荐 v1.22.0)
- EdgeCore 已启用 metaServer 模块
- EdgeCore 已配置 clusterDNS 为 `169.254.96.16`

这些配置已在我们的安装脚本中自动完成:
```yaml
# /etc/kubeedge/edgecore.yaml
modules:
  metaManager:
    metaServer:
      enable: true  # ✅ 已启用
      server: 127.0.0.1:10550
  edged:
    tailoredKubeletConfig:
      clusterDNS:
        - 169.254.96.16  # ✅ 已配置为 EdgeMesh DNS
```

### 2. Helm 3 安装

在云端节点上安装 Helm 3:
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 部署步骤

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
- ✅ 使用离线包中的 EdgeMesh 镜像 (无需外网)
- ✅ 使用离线包中的 Helm Chart (无需外网)
- ✅ 自动生成 PSK 密码
- ✅ 自动配置中继节点
- ✅ 保存 PSK 到 `edgemesh-psk.txt` 文件

**完全离线**: EdgeMesh 镜像和 Helm Chart 已预先打包在 cloud 离线安装包中，整个部署过程无需任何外网连接。

### 方式二: 手动部署 (高级用户)

#### 1. 准备 PSK 密码

生成 PSK 密码用于 EdgeMesh 组件间通信加密:
```bash
openssl rand -base64 32
# 示例输出: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

保存此密码，后续部署时需要使用。

#### 2. 确定中继节点

EdgeMesh 高可用模式需要配置中继节点。选择一个或多个云端节点作为中继节点:
```bash
# 查看节点列表
kubectl get nodes

# 获取云端节点的公网IP或内网IP
kubectl get node <node-name> -o wide
```

#### 3. 部署 EdgeMesh Agent (使用离线 Chart)

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

### 1. EdgeMesh Agent 无法启动

检查 EdgeCore 配置:
```bash
# 确认 metaServer 已启用
grep -A 5 "metaServer:" /etc/kubeedge/edgecore.yaml

# 确认 clusterDNS 配置正确
grep -A 2 "clusterDNS:" /etc/kubeedge/edgecore.yaml
```

### 2. 服务发现失败

```bash
# 检查 EdgeMesh Agent 日志
kubectl logs -n kubeedge -l kubeedge=edgemesh-agent --tail=100

# 检查 Pod 的 DNS 配置
kubectl exec <pod-name> -- cat /etc/resolv.conf
# 应该包含 nameserver 169.254.96.16
```

### 3. 跨节点通信失败

```bash
# 检查中继节点配置
kubectl get cm edgemesh-agent-cfg -n kubeedge -o yaml

# 确认中继节点可达
ping <relay-node-ip>
telnet <relay-node-ip> 20006  # EdgeMesh relay 端口
```

## 参考文档

- [EdgeMesh 官方文档](https://edgemesh.netlify.app/)
- [EdgeMesh GitHub 仓库](https://github.com/kubeedge/edgemesh)
- [EdgeMesh 配置参考](https://edgemesh.netlify.app/reference/config-items.html)
- [边缘 Kube-API 端点](https://edgemesh.netlify.app/guide/edge-kube-api.html)

## 架构说明

```
┌─────────────────────────────────────────────────────────────┐
│                       云端 (K3s)                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  API Server  │  │  CloudCore   │  │ EdgeMesh     │      │
│  │              │  │              │  │ Agent        │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                  │                  │              │
└─────────┼──────────────────┼──────────────────┼──────────────┘
          │                  │                  │
          │                  │  WebSocket       │  Relay
          │                  │  10000           │  20006
          │                  │                  │
┌─────────┼──────────────────┼──────────────────┼──────────────┐
│         │                  │                  │              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  MetaServer  │◄─┤  EdgeCore    │  │ EdgeMesh     │      │
│  │  :10550      │  │              │  │ Agent        │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                                     │              │
│         │ List/Watch                          │ Service Mesh │
│         │                                     │              │
│  ┌──────────────┐                    ┌──────────────┐      │
│  │  Container   │───────────────────►│  Container   │      │
│  │  (Pod)       │    EdgeMesh Proxy  │  (Pod)       │      │
│  └──────────────┘                    └──────────────┘      │
│                     边缘节点                                 │
└─────────────────────────────────────────────────────────────┘
```

## 最佳实践

1. **生产环境配置多个中继节点**以实现高可用
2. **使用稳定的公网IP**作为中继节点地址
3. **定期备份 PSK 密码**，所有 EdgeMesh 组件必须使用相同的 PSK
4. **监控 EdgeMesh 日志**以及时发现问题
5. **边缘节点使用 host 网络**，不要配置 CNI (除非有特殊需求)
