# EdgeCore 配置最佳实践

## 概述

基于 KubeEdge 和 EdgeMesh 官方文档分析，本文档说明 EdgeCore 的最佳配置实践。

## EdgeMesh 集成配置要求

### 关键配置项

根据 EdgeMesh 官方文档（https://edgemesh.netlify.app/guide/edge-kube-api.html），EdgeCore 需要以下配置以支持 EdgeMesh:

#### 1. MetaServer 模块 ✅

**必须启用** - EdgeMesh 通过 metaServer 与 K8s API 交互

```yaml
modules:
  metaManager:
    metaServer:
      enable: true                    # 必须为 true
      server: 127.0.0.1:10550         # 默认地址
```

**作用**: 
- 为边缘应用提供轻量级 Kubernetes API 访问
- EdgeMesh Agent 通过它获取 Service/Endpoints 信息
- 支持边缘离线场景下的 API 访问

#### 2. EdgeStream 模块 ✅

**必须启用** - EdgeMesh 高可用通信需要

```yaml
modules:
  edgeStream:
    enable: true                      # 必须为 true
    server: <CLOUD_IP>:10003         # CloudCore 的 stream 端口
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    handshakeTimeout: 30
    readDeadline: 15
    writeDeadline: 15
```

**作用**:
- 提供云边 tunnel 通信能力
- 支持 `kubectl logs/exec` 等流式操作
- EdgeMesh 高可用特性依赖此模块

#### 3. ClusterDNS 配置 ✅

**必须配置为 EdgeMesh DNS 地址**

```yaml
modules:
  edged:
    tailoredKubeletConfig:
      clusterDNS:
        - 169.254.96.16               # EdgeMesh DNS 地址 (固定值)
      clusterDomain: cluster.local
```

**重要说明**:
- `169.254.96.16` 是 EdgeMesh 的 `bridgeDeviceIP` 默认值
- EdgeMesh Agent 会在边缘节点创建 `edgemesh0` 网桥设备并绑定此 IP
- 边缘 Pod 的 DNS 请求会被路由到 EdgeMesh DNS 模块
- **不要修改此 IP**，除非同时修改 EdgeMesh 的 `bridgeDeviceIP` 配置

#### 4. 网络插件配置 ✅

**不使用 CNI** - 边缘节点使用 host 网络模式

```yaml
modules:
  edged:
    tailoredKubeletConfig:
      # 不配置以下字段（已从配置中移除）:
      # networkPluginName: cni
      # cniConfDir: /etc/cni/net.d
      # cniBinDir: /opt/cni/bin
```

**原因**:
- 边缘节点资源有限，使用 host 网络更轻量
- EdgeMesh 提供服务网格能力，无需 CNI 插件
- 简化配置，避免网段冲突和管理复杂度

## 配置验证

### 1. 检查 MetaServer 状态

```bash
# 在边缘节点上测试 metaServer
curl http://127.0.0.1:10550/api/v1/services

# 应该返回 Service 列表（JSON 格式）
```

### 2. 检查 EdgeStream 连接

```bash
# 查看 edgecore 日志
sudo journalctl -u edgecore -f | grep -i stream

# 应该看到 stream 连接成功的日志
```

### 3. 检查 DNS 配置

```bash
# 在边缘节点创建测试 Pod
kubectl run test-dns --image=busybox:1.28 --rm -it -- sh

# 在 Pod 内检查 DNS 配置
cat /etc/resolv.conf

# 应该包含:
# nameserver 169.254.96.16
# search default.svc.cluster.local svc.cluster.local cluster.local
```

### 4. 验证网络模式

```bash
# 检查 Pod 网络模式
kubectl get pod -o wide

# Edge Pod 应该使用主机 IP (hostNetwork: true)
```

## 完整配置示例

以下是我们安装脚本生成的完整 EdgeCore 配置（v1alpha2）:

```yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
database:
  aliasName: default
  dataSource: /var/lib/kubeedge/edgecore.db
  driverName: sqlite3
modules:
  dbTest:
    enable: false
  deviceTwin:
    dmiSockPath: /etc/kubeedge/dmi.sock
    enable: true
  edgeHub:
    enable: true
    heartbeat: 15
    httpServer: https://<CLOUD_IP>:10002
    messageBurst: 60
    messageQPS: 30
    projectID: e632aba927ea4ac2b575ec1603d56f10
    quic:
      enable: false
      handshakeTimeout: 30
      readDeadline: 15
      server: <CLOUD_IP>:10001
      writeDeadline: 15
    rotateCertificates: true
    tlsCaFile: /etc/kubeedge/ca/rootCA.crt
    tlsCertFile: /etc/kubeedge/certs/server.crt
    tlsPrivateKeyFile: /etc/kubeedge/certs/server.key
    token: "<TOKEN>"
    websocket:
      enable: true
      handshakeTimeout: 30
      readDeadline: 15
      server: <CLOUD_IP>:10000
      writeDeadline: 15
  edgeStream:
    enable: true                          # ✅ EdgeMesh 必需
    handshakeTimeout: 30
    readDeadline: 15
    server: <CLOUD_IP>:10003
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    writeDeadline: 15
  edged:
    enable: true
    hostnameOverride: <NODE_NAME>
    maxContainerCount: -1
    maxPerPodContainerCount: 1
    minimumGCAge: 0s
    podSandboxImage: kubeedge/pause:3.6
    registerNodeNamespace: default
    registerSchedulable: true
    tailoredKubeletConfig:
      address: 127.0.0.1
      cgroupDriver: systemd
      cgroupsPerQOS: true
      clusterDNS:
        - 169.254.96.16               # ✅ EdgeMesh DNS (固定值)
      clusterDomain: cluster.local
      containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
      # ✅ 不使用 CNI (已移除)
      contentType: application/json
      enableDebuggingHandlers: true
      evictionHard:
        imagefs.available: 15%
        memory.available: 100Mi
        nodefs.available: 10%
        nodefs.inodesFree: 5%
      evictionPressureTransitionPeriod: 5m0s
      failSwapOn: false
      imageGCHighThresholdPercent: 85
      imageGCLowThresholdPercent: 80
      imageServiceEndpoint: unix:///run/containerd/containerd.sock
      maxPods: 110
      podLogsDir: /var/log/pods
      registerNode: true
      rotateCertificates: true
      serializeImagePulls: true
      staticPodPath: /etc/kubeedge/manifests
  eventBus:
    enable: true
    eventBusTLS:
      enable: false
      tlsMqttCAFile: /etc/kubeedge/ca/rootCA.crt
      tlsMqttCertFile: /etc/kubeedge/certs/server.crt
      tlsMqttPrivateKeyFile: /etc/kubeedge/certs/server.key
    mqttMode: 2
    mqttQOS: 0
    mqttRetain: false
    mqttServerExternal: tcp://127.0.0.1:1883
    mqttServerInternal: tcp://127.0.0.1:1884
    mqttSessionQueueSize: 100
  metaManager:
    contextSendGroup: hub
    contextSendModule: websocket
    enable: true
    metaServer:
      enable: true                       # ✅ EdgeMesh 必需
      server: 127.0.0.1:10550
    remoteQueryTimeout: 60
  serviceBus:
    enable: false
  taskManager:
    enable: false
```

## 配置变更说明

### 相比传统配置的改进

| 配置项 | 传统配置 | EdgeMesh 配置 | 原因 |
|--------|----------|---------------|------|
| `metaServer.enable` | `false` | `true` ✅ | EdgeMesh 需要访问 K8s API |
| `edgeStream.enable` | `false` | `true` ✅ | 支持 tunnel 通信和流式操作 |
| `clusterDNS` | `10.43.0.10` (云端DNS) | `169.254.96.16` ✅ | 使用 EdgeMesh DNS |
| `networkPluginName` | `cni` | (移除) ✅ | 不使用 CNI，host 网络模式 |
| `cniConfDir` | `/etc/cni/net.d` | (移除) ✅ | 不需要 CNI 配置 |
| `cniBinDir` | `/opt/cni/bin` | (移除) ✅ | 不需要 CNI 二进制 |

## EdgeMesh 部署方式

**重要**: EdgeMesh 完全通过云端 Helm 部署，边缘节点 **不需要** 预装任何 EdgeMesh 组件。

### 部署流程

1. **边缘节点**: 只需安装 EdgeCore，确保上述配置正确
2. **云端节点**: 通过 Helm 部署 EdgeMesh DaemonSet

```bash
# 在云端执行
helm install edgemesh --namespace kubeedge \
  --set agent.psk=<your-psk> \
  --set agent.relayNodes[0].nodeName=k8s-master \
  --set agent.relayNodes[0].advertiseAddress="{152.136.201.36}" \
  https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/helm/edgemesh.tgz
```

3. **自动下发**: EdgeMesh Agent Pod 自动调度到所有节点（云+边缘）
4. **自动运行**: EdgeMesh Agent 自动连接 metaServer 并提供服务网格功能

### 为什么不需要离线安装 EdgeMesh?

- EdgeMesh Agent 作为 DaemonSet 运行
- 镜像通过 K8s 集群分发，边缘节点可从 CloudCore 拉取
- EdgeCore 的配置已经为 EdgeMesh 准备好环境 (metaServer + edgeStream + DNS)
- 边缘节点只需正确配置 EdgeCore，EdgeMesh 自动工作

## 故障排查

### MetaServer 无法访问

```bash
# 检查 metaServer 监听
sudo netstat -tlnp | grep 10550

# 检查 edgecore 日志
sudo journalctl -u edgecore | grep -i metaserver
```

### EdgeStream 连接失败

```bash
# 检查云端 CloudCore stream 端口
nc -zv <CLOUD_IP> 10003

# 检查证书文件
ls -la /etc/kubeedge/ca/ /etc/kubeedge/certs/
```

### DNS 解析失败

```bash
# 检查 EdgeMesh Agent 状态
kubectl get pods -n kubeedge -l kubeedge=edgemesh-agent

# 检查 edgemesh0 网桥
ip addr show edgemesh0
# 应该显示 169.254.96.16
```

## 参考文档

- [EdgeMesh Edge Kube-API Endpoint](https://edgemesh.netlify.app/guide/edge-kube-api.html)
- [EdgeMesh 快速上手](https://edgemesh.netlify.app/zh/guide/)
- [EdgeMesh 配置参考](https://edgemesh.netlify.app/zh/reference/config-items.html)
- [KubeEdge EdgeCore 配置](https://kubeedge.io/docs/setup/config/)

## 总结

✅ **EdgeCore 配置**: metaServer + edgeStream + clusterDNS  
✅ **网络模式**: Host 网络 (无 CNI)  
✅ **EdgeMesh 安装**: 云端 Helm 部署 (无需边缘离线安装)  
✅ **自动化**: 安装脚本已包含所有必需配置
