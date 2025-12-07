# KubeEdge v1.22.0 CNI 与 EdgeMesh 共存最佳实践

## 概述

本文档详细说明 KubeEdge v1.22.0 环境中 CNI 插件与 EdgeMesh 服务网格的共存配置方案，确保边缘节点 Ready 状态的同时保持服务网格能力。

## 核心问题

### 历史背景

在 KubeEdge 早期版本（< v1.18.0）中，边缘节点推荐使用 **host 网络模式**：
- 不需要 CNI 插件
- EdgeMesh 提供跨云边服务发现和通信
- 节点状态由 EdgeCore 直接上报

### v1.22.0 变化

KubeEdge v1.22.0 引入了更严格的节点就绪检查：
- **必须配置 CNI** 否则节点报告 `NotReady`
- kubelet 检查 `/etc/cni/net.d/` 和 `/opt/cni/bin/` 目录
- 即使不运行 Pod，CNI 配置也是节点 Ready 的前置条件

## 解决方案架构

### 双网络模式

```
┌─────────────────────────────────────────────────────────────┐
│                     边缘节点网络架构                          │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────────┐        ┌──────────────────┐           │
│  │   CNI Bridge    │        │  EdgeMesh Agent   │           │
│  │   (cni0)        │        │  (edgemesh0)      │           │
│  └─────────────────┘        └──────────────────┘           │
│         │                            │                       │
│         │ Pod 网络                   │ 服务网格              │
│         │ 10.244.X.0/24              │ 169.254.96.16         │
│         │                            │                       │
│  ┌──────▼────────────────────────────▼──────────┐           │
│  │          主机网络 (host network)             │           │
│  │          eth0: <边缘节点IP>                   │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### 职责分离

| 组件 | 职责 | 配置 |
|------|------|------|
| **CNI (bridge)** | Pod 容器网络隔离 | `/etc/cni/net.d/10-kubeedge-bridge.conflist` |
| **EdgeMesh** | 跨云边服务发现与通信 | 自动创建 `edgemesh0` 网桥 |
| **Host Network** | 边缘节点主网络 | 云边 WebSocket/QUIC 连接 |

## CNI 配置

### 1. CNI 插件安装

**版本**: CNI Plugins v1.5.1 (2024年最新稳定版)

**安装路径**:
```bash
/opt/cni/bin/
├── bridge          # 网桥插件
├── loopback        # 回环插件
├── host-local      # IP 地址管理
├── portmap         # 端口映射
├── bandwidth       # 带宽限制
└── ...             # 其他插件
```

**下载来源**:
```bash
CNI_VERSION="v1.5.1"
wget https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz
```

### 2. CNI 配置文件

**路径**: `/etc/cni/net.d/10-kubeedge-bridge.conflist`

**内容**:
```json
{
  "cniVersion": "1.0.0",
  "name": "kubeedge-cni",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isDefaultGateway": true,
      "forceAddress": false,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "subnet": "10.244.X.0/24",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
```

**关键配置说明**:

| 字段 | 值 | 说明 |
|------|-----|------|
| `cniVersion` | `1.0.0` | CNI 规范版本，v1.5.1 插件支持 |
| `bridge` | `cni0` | 网桥名称，与 EdgeMesh 的 `edgemesh0` 隔离 |
| `isDefaultGateway` | `true` | 设置为 Pod 默认网关 |
| `ipMasq` | `true` | 启用 SNAT，Pod 可访问外网 |
| `hairpinMode` | `true` | 支持 Pod 访问自身 Service（重要！） |
| `ipam.type` | `host-local` | 本地 IP 地址分配 |
| `ipam.subnet` | `10.244.X.0/24` | 节点专属子网（避免冲突） |

### 3. 多边缘节点网络隔离

**问题**: 多个边缘节点使用相同 Pod CIDR 会导致 IP 冲突

**解决方案**: 基于节点名称 hash 自动分配唯一子网

```bash
# 节点名称 hash 计算
NODE_HASH=$(echo -n "$NODE_NAME" | md5sum | cut -c1-2)
SUBNET_OCTET=$((16#$NODE_HASH % 254 + 1))
POD_CIDR="10.244.${SUBNET_OCTET}.0/24"
```

**示例**:
```
edge-1  → MD5=3a2f... → Octet=58  → 10.244.58.0/24
edge-2  → MD5=7f9c... → Octet=127 → 10.244.127.0/24
edge-3  → MD5=b2e1... → Octet=178 → 10.244.178.0/24
```

**优点**:
- ✅ 自动化分配，无需手动配置
- ✅ 确定性结果，同名节点始终相同子网
- ✅ 254 个可用子网，支持大规模部署
- ✅ 避免边缘节点间 Pod IP 冲突

## EdgeMesh 配置

### 1. EdgeMesh 网络隔离

EdgeMesh 使用独立的网络组件，与 CNI 不冲突：

```bash
# EdgeMesh 自动创建的网桥
ip link show edgemesh0
# edgemesh0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
# inet 169.254.96.16/32 scope global edgemesh0
```

### 2. EdgeCore 配置要求

**必须启用 metaServer**（EdgeMesh 依赖）:

```yaml
# /etc/kubeedge/config/edgecore.yaml
modules:
  metaManager:
    metaServer:
      enable: true
      server: 127.0.0.1:10550
```

**DNS 配置指向 EdgeMesh**:

```yaml
modules:
  edged:
    clusterDNS:
      - 169.254.96.16  # EdgeMesh DNS 地址（固定值）
    clusterDomain: cluster.local
```

### 3. EdgeMesh 与 CNI 的协同

| 场景 | 使用网络 | 说明 |
|------|---------|------|
| Pod 内部通信 | CNI (cni0) | 同节点 Pod 通过 bridge 通信 |
| Pod 访问 Service | EdgeMesh (edgemesh0) | 服务发现和负载均衡 |
| 跨节点 Service 调用 | EdgeMesh Tunnel | 云边/边边服务通信 |
| Pod 访问外网 | CNI + iptables | SNAT 伪装 |

## 部署流程

### 1. 云端部署

```bash
# 安装 K3s + CloudCore
cd /data/kubeedge-cloud-xxx
sudo ./install.sh <EXTERNAL_IP> [NODE_NAME]

# 获取 edge token
cat /etc/kubeedge/tokens/edge-token.txt
```

### 2. 边缘节点部署

```bash
# 自动安装 CNI + EdgeCore
cd /data/kubeedge-edge-xxx
sudo ./install.sh <CLOUD_IP>:10000 <EDGE_TOKEN> <EDGE_NODE_NAME>
```

**自动化步骤**:
1. ✅ 安装 containerd + runc
2. ✅ 安装 CNI 插件到 `/opt/cni/bin/`
3. ✅ 生成节点专属 CNI 配置
4. ✅ 预加载 `installation-package:v1.22.0` 镜像
5. ✅ 执行 `keadm join` 获取证书和配置
6. ✅ 启用 metaServer（EdgeMesh 依赖）
7. ✅ 配置 clusterDNS 指向 EdgeMesh
8. ✅ 启动 EdgeCore 服务

### 3. 部署 EdgeMesh

```bash
# 在云端执行
kubectl apply -f edgemesh-daemonset.yaml

# 或使用 Helm
helm install edgemesh /path/to/edgemesh-chart.tgz \
  --namespace kubeedge \
  --set agent.psk=<PSK> \
  --set agent.relayNodes[0].nodeName=<MASTER_NODE> \
  --set agent.relayNodes[0].advertiseAddress="{<EXTERNAL_IP>}"
```

## 验证与测试

### 1. 节点状态验证

```bash
# 检查节点 Ready 状态
kubectl get nodes
# NAME     STATUS   ROLES    AGE   VERSION
# edge-1   Ready    agent    5m    v1.28.0-kubeedge-v1.22.0

# 检查节点详细信息
kubectl describe node edge-1 | grep -A 5 Conditions
```

### 2. CNI 验证

```bash
# SSH 到边缘节点
ssh root@<edge-node-ip>

# 检查 CNI 二进制
ls -lh /opt/cni/bin/
# -rwxr-xr-x 1 root root  4.2M bridge
# -rwxr-xr-x 1 root root  10M  host-local
# -rwxr-xr-x 1 root root  3.5M loopback

# 检查 CNI 配置
cat /etc/cni/net.d/10-kubeedge-bridge.conflist

# 检查 cni0 网桥（Pod 运行后才会创建）
ip link show cni0
# cni0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
# inet 10.244.58.1/24 brd 10.244.58.255 scope global cni0
```

### 3. EdgeMesh 验证

```bash
# 检查 EdgeMesh Agent 运行状态
kubectl get pods -n kubeedge -l app=edgemesh-agent
# NAME                   READY   STATUS    RESTARTS   AGE
# edgemesh-agent-xxxxx   1/1     Running   0          5m

# 检查 edgemesh0 网桥
ip link show edgemesh0
# inet 169.254.96.16/32 scope global edgemesh0

# 检查 EdgeMesh DNS
nslookup kubernetes.default.svc.cluster.local 169.254.96.16
```

### 4. Pod 网络测试

```bash
# 部署测试 Pod
kubectl run test-pod --image=nginx --overrides='
{
  "spec": {
    "nodeName": "edge-1",
    "containers": [{
      "name": "nginx",
      "image": "nginx"
    }]
  }
}'

# 检查 Pod IP（应在 10.244.X.0/24 范围内）
kubectl get pod test-pod -o wide
# NAME       READY   STATUS    RESTARTS   AGE   IP             NODE
# test-pod   1/1     Running   0          30s   10.244.58.10   edge-1

# 从 Pod 内测试网络
kubectl exec test-pod -- ip addr show eth0
# eth0: inet 10.244.58.10/24 brd 10.244.58.255 scope global eth0

# 测试 DNS 解析（通过 EdgeMesh）
kubectl exec test-pod -- nslookup kubernetes.default
# Server:    169.254.96.16
# Address:   169.254.96.16:53
```

### 5. 跨云边服务测试

```bash
# 云端部署服务
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80

# 边缘 Pod 访问云端服务（通过 EdgeMesh）
kubectl run edge-test --image=busybox -it --rm --restart=Never \
  --overrides='{"spec":{"nodeName":"edge-1"}}' \
  -- wget -O- http://nginx.default.svc.cluster.local
```

## 故障排查

### 问题 1: 节点 NotReady

**症状**:
```bash
kubectl get nodes
# NAME     STATUS     ROLES    AGE
# edge-1   NotReady   agent    2m
```

**检查步骤**:
```bash
# 1. 检查 CNI 插件是否安装
ssh root@edge-1 'ls /opt/cni/bin/'

# 2. 检查 CNI 配置是否存在
ssh root@edge-1 'ls /etc/cni/net.d/'

# 3. 检查 EdgeCore 日志
ssh root@edge-1 'journalctl -u edgecore -n 50'

# 4. 检查 kubelet 状态报告
kubectl describe node edge-1 | grep -A 10 "Runtime Version"
```

**解决方案**:
```bash
# 重新安装 CNI
cd /data/kubeedge-edge-xxx
sudo ./install.sh <CLOUD_IP>:10000 <TOKEN> <NODE_NAME>
```

### 问题 2: Pod 无法调度到边缘节点

**症状**:
```bash
kubectl get pods -o wide
# NAME   READY   STATUS    RESTARTS   AGE   NODE
# test   0/1     Pending   0          30s   <none>
```

**检查步骤**:
```bash
# 查看调度失败原因
kubectl describe pod test | grep -A 5 Events

# 检查节点污点
kubectl describe node edge-1 | grep Taints
```

**解决方案**:
```bash
# 显式指定节点
kubectl run test --image=nginx --overrides='{"spec":{"nodeName":"edge-1"}}'

# 或添加节点选择器
kubectl label node edge-1 node-type=edge
kubectl run test --image=nginx --overrides='{"spec":{"nodeSelector":{"node-type":"edge"}}}'
```

### 问题 3: EdgeMesh DNS 不工作

**症状**:
```bash
kubectl exec test-pod -- nslookup kubernetes
# Server:    10.43.0.10
# ** server can't find kubernetes: NXDOMAIN
```

**检查步骤**:
```bash
# 1. 检查 EdgeCore clusterDNS 配置
ssh root@edge-1 'grep -A 3 clusterDNS /etc/kubeedge/config/edgecore.yaml'

# 2. 检查 EdgeMesh Agent 状态
kubectl get pods -n kubeedge -l app=edgemesh-agent

# 3. 检查 edgemesh0 网桥
ssh root@edge-1 'ip addr show edgemesh0'
```

**解决方案**:
```bash
# 确保 EdgeCore 配置正确
# /etc/kubeedge/config/edgecore.yaml
modules:
  edged:
    clusterDNS:
      - 169.254.96.16  # 必须指向 EdgeMesh

# 重启 EdgeCore
systemctl restart edgecore

# 重新部署 Pod
kubectl delete pod test-pod
kubectl run test-pod --image=nginx --overrides='{"spec":{"nodeName":"edge-1"}}'
```

### 问题 4: Pod IP 冲突

**症状**:
```bash
# 两个边缘节点上的 Pod 使用相同 IP
kubectl get pods -o wide
# NAME    READY   STATUS    IP            NODE
# pod-1   1/1     Running   10.244.1.10   edge-1
# pod-2   1/1     Running   10.244.1.10   edge-2  # 冲突！
```

**原因**: 两个节点使用了相同的 CNI 配置子网

**检查步骤**:
```bash
# 检查各节点的 Pod CIDR
ssh root@edge-1 'grep subnet /etc/cni/net.d/10-kubeedge-bridge.conflist'
ssh root@edge-2 'grep subnet /etc/cni/net.d/10-kubeedge-bridge.conflist'
```

**解决方案**:
本安装脚本已自动基于节点名 hash 分配唯一子网，如果仍有冲突：
```bash
# 手动修改 CNI 配置
ssh root@edge-2 'vi /etc/cni/net.d/10-kubeedge-bridge.conflist'
# 修改 subnet 为不同网段，如 10.244.100.0/24

# 重启 EdgeCore
ssh root@edge-2 'systemctl restart edgecore'

# 删除并重建 Pod
kubectl delete pod pod-2
```

## 高级配置

### 1. 自定义 Pod CIDR 范围

如果默认的 `10.244.X.0/24` 与现有网络冲突：

```bash
# 修改 install.sh 中的子网计算逻辑
POD_CIDR="172.16.${SUBNET_OCTET}.0/24"  # 使用 172.16.0.0/16 范围
```

### 2. 启用 EdgeMesh CNI 模式（跨云边容器网络）

如果需要云端和边缘 Pod 直接通信（不通过 Service）：

```bash
# 1. 安装 SpiderPool IPAM
helm install spiderpool spiderpool/spiderpool \
  --namespace kube-system \
  --set clusterDefaultPool.ipv4Subnet=10.244.0.0/16

# 2. 启用 EdgeMesh CNI
helm install edgemesh /path/to/chart.tgz \
  --set agent.meshCIDRConfig.cloudCIDR="{10.244.0.0/18}" \
  --set agent.meshCIDRConfig.edgeCIDR="{10.244.64.0/18}"
```

### 3. 带宽限制与 QoS

在 CNI 配置中添加带宽插件：

```json
{
  "cniVersion": "1.0.0",
  "name": "kubeedge-cni",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      ...
    },
    {
      "type": "bandwidth",
      "ingressRate": 10485760,   // 10 Mbps 下载限制
      "ingressBurst": 1048576,   // 1 MB 突发
      "egressRate": 5242880,     // 5 Mbps 上传限制
      "egressBurst": 524288      // 512 KB 突发
    },
    {
      "type": "portmap",
      ...
    }
  ]
}
```

## 最佳实践总结

### ✅ 推荐配置

1. **CNI 插件**:
   - 使用 CNI Plugins v1.5.1（最新稳定版）
   - 安装所有标准插件（bridge、loopback、host-local、portmap）
   - 基于节点名 hash 自动分配子网

2. **EdgeMesh 部署**:
   - 启用 metaServer（必需）
   - 配置 clusterDNS 指向 169.254.96.16
   - 使用 DaemonSet 方式部署 Agent

3. **网络隔离**:
   - CNI 使用 `cni0` 网桥
   - EdgeMesh 使用 `edgemesh0` 网桥
   - 两者互不干扰，各司其职

4. **监控验证**:
   - 定期检查节点 Ready 状态
   - 验证 Pod 网络连通性
   - 测试跨云边服务调用

### ❌ 避免的配置

1. **不要省略 CNI**:
   - 即使使用 EdgeMesh，v1.22.0 仍需要 CNI 配置
   - 没有 CNI 会导致节点 NotReady

2. **不要使用相同 Pod CIDR**:
   - 多个边缘节点必须使用不同子网
   - 使用本脚本的自动 hash 分配功能

3. **不要禁用 metaServer**:
   - EdgeMesh 依赖 metaServer 访问 K8s API
   - 禁用会导致服务发现失败

4. **不要手动修改 edgemesh0**:
   - EdgeMesh 自动管理该网桥
   - 手动修改可能导致服务网格异常

## 参考资料

- [KubeEdge 官方文档](https://kubeedge.io/docs/)
- [CNI 规范](https://github.com/containernetworking/cni/blob/main/SPEC.md)
- [EdgeMesh 部署指南](https://edgemesh.netlify.app/)
- [CNI Plugins 发布页](https://github.com/containernetworking/plugins/releases)

## 版本信息

- KubeEdge: v1.22.0
- CNI Plugins: v1.5.1
- EdgeMesh: v1.17.0
- Containerd: v1.7.29

---

**最后更新**: 2024-12-07  
**维护者**: KubeEdge 离线部署项目组
