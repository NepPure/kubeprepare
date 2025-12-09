# K3s + KubeEdge 环境下 kubectl logs/exec 离线部署最佳实践

**版本信息**
- K3s: v1.31+
- KubeEdge: v1.22.0
- EdgeMesh: v1.17.0
- 部署模式: 完全离线环境

---

## 一、架构设计原理

### 1.1 官方标准架构

根据 KubeEdge 官方文档，kubectl logs/exec 功能基于以下架构：

```
┌─────────────────────────────────────────────────────────┐
│                   Cloud Node (K3s)                      │
│                                                         │
│  ┌──────────────┐                                      │
│  │  K3s Server  │                                      │
│  │  API Server  │  kubectl logs pod-x                  │
│  │  :6443       │ ← ──────────────────                │
│  └──────┬───────┘                                      │
│         │                                               │
│         │ HTTPS Request                                │
│         │ GET https://<EdgeNodeIP>:10351/...          │
│         ↓                                               │
│  ┌──────────────────────────────────┐                 │
│  │   iptables-manager (DaemonSet)   │                 │
│  │   Auto-created by keadm init     │                 │
│  │   ─────────────────────────────  │                 │
│  │   NAT Rule (OUTPUT chain):       │                 │
│  │   <EdgeIP>:10351 → CloudCore:10003                │
│  └──────────────┬───────────────────┘                 │
│                 │                                       │
│                 ↓                                       │
│  ┌─────────────────────────────────┐                  │
│  │  CloudCore Pod (hostNetwork)    │                  │
│  │  ─────────────────────────────  │                  │
│  │  cloudStream:                   │                  │
│  │    streamPort: 10003  ←─────────┘ (HTTPS)         │
│  │    tunnelPort: 10004  ←───────┐   (WebSocket)     │
│  └─────────────────────────────────┘                  │
│                                    │                   │
└────────────────────────────────────┼───────────────────┘
                                     │
                    WebSocket Tunnel │ (Port 10004)
                                     │
┌────────────────────────────────────┼───────────────────┐
│                                    ↓                   │
│  ┌─────────────────────────────────────┐              │
│  │  EdgeCore (systemd service)         │              │
│  │  ───────────────────────────────────│              │
│  │  edgeStream:                        │              │
│  │    enable: true                     │              │
│  │    server: <CloudIP>:10004 ────────┘              │
│  │                                     │              │
│  │  edged (built-in kubelet):          │              │
│  │    - NOT listening on external ports│              │
│  │    - Internal communication only    │              │
│  └─────────────┬───────────────────────┘              │
│                │                                       │
│                ↓                                       │
│  ┌──────────────────────────┐                         │
│  │  containerd CRI          │                         │
│  │  /run/containerd/*.sock  │                         │
│  └──────────────────────────┘                         │
│                                                        │
│                Edge Node                               │
└────────────────────────────────────────────────────────┘
```

### 1.2 核心组件说明

| 组件 | 职责 | 端口 | 说明 |
|------|------|------|------|
| **K3s API Server** | 接收 kubectl 命令 | 6443 | 单进程，包含完整 K8s 控制平面 |
| **iptables-manager** | 自动管理 NAT 规则 | - | DaemonSet，keadm 自动部署 |
| **CloudCore cloudStream** | 接收 API Server 请求 | 10003 (streamPort) | HTTPS，转发到边缘 |
| **CloudCore cloudHub** | 云边 WebSocket 隧道 | 10004 (tunnelPort) | EdgeCore 连接此端口 |
| **EdgeCore edgeStream** | 连接到 CloudCore | - | 客户端，不监听端口 |
| **EdgeCore edged** | 内置 kubelet | 10550 (metaServer) | 仅 127.0.0.1 监听 |

### 1.3 关键设计原则

1. **EdgeCore 不对外监听端口**
   - EdgeCore 的 edged 模块不在任何外部端口监听
   - 所有通信通过 edgeStream 的 WebSocket tunnel 进行
   - 这是官方推荐的架构，避免边缘节点暴露端口

2. **iptables 自动管理**
   - `keadm init` 自动部署 iptables-manager DaemonSet
   - 自动读取 tunnelport ConfigMap，创建 NAT 规则
   - 无需手动配置 iptables

3. **证书自动管理**
   - CloudCore 使用 keadm 生成的证书
   - EdgeCore 通过 HTTPS (10002) 自动下载证书
   - streamCA 和 tunnelCA 独立管理

---

## 二、离线部署配置方案

### 2.1 云端配置（K3s + CloudCore）

#### Step 1: CloudCore ConfigMap 配置

**关键配置项**（keadm init 自动生成，可通过 kubectl patch 修改）：

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
      cloudHub:
        advertiseAddress:
        - "<EXTERNAL_IP>"           # 云端公网/可达 IP
        https:
          enable: true
          port: 10002               # 证书下载端口
        websocket:
          enable: true
          port: 10000               # EdgeCore 连接端口
        nodeLimit: 1000
      
      cloudStream:
        enable: true                # ✅ 必须启用
        streamPort: 10003           # ✅ API Server 请求端口
        tunnelPort: 10004           # ✅ EdgeCore WebSocket 端口
        tlsStreamCAFile: /etc/kubeedge/ca/streamCA.crt
        tlsStreamCertFile: /etc/kubeedge/certs/stream.crt
        tlsStreamPrivateKeyFile: /etc/kubeedge/certs/stream.key
        tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
        tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
        tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
      
      dynamicController:
        enable: true                # ✅ 必须启用（管理 node.kubeletEndpoint.Port）
```

**重要说明**：
- `cloudStream.enable: true` - **必需**，否则 logs/exec 不工作
- `dynamicController.enable: true` - **必需**，负责设置 node 对象的端口为 10351
- `tunnelPort: 10004` - EdgeCore 连接的 WebSocket 端口
- `streamPort: 10003` - API Server 请求转发的 HTTPS 端口

#### Step 2: 验证 CloudCore 配置

```bash
# 1. 检查 CloudCore Pod 状态
kubectl get pod -n kubeedge -l kubeedge=cloudcore
# 应该是 Running 状态

# 2. 检查 cloudStream 配置
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 10 "cloudStream:"
# 确认 enable: true, streamPort: 10003, tunnelPort: 10004

# 3. 检查 CloudCore 监听端口
CLOUDCORE_POD=$(kubectl get pod -n kubeedge -l kubeedge=cloudcore -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kubeedge $CLOUDCORE_POD -- netstat -tlnp | grep -E "10003|10004"
# 应该看到:
# tcp6  0  0 :::10003  :::*  LISTEN  (cloudcore)
# tcp6  0  0 :::10004  :::*  LISTEN  (cloudcore)

# 4. 检查 iptables-manager 是否运行
kubectl get pod -n kubeedge -l k8s-app=iptables-manager
# 应该有 Pod 在 Running 状态
```

#### Step 3: 验证 iptables 规则（在云端节点执行）

```bash
# 1. 检查 tunnelport ConfigMap（dynamicController 自动创建）
kubectl get cm tunnelport -n kubeedge -o yaml

# 应该看到类似：
# annotations:
#   tunnelportrecord.kubeedge.io: '{"ipTunnelPort":{"<EdgeIP>":10351},"port":{"10351":true}}'

# 2. 检查 iptables NAT 规则
sudo iptables -t nat -L OUTPUT -n -v | grep 10351
sudo iptables -t nat -L TUNNEL-PORT -n -v

# 应该看到类似（iptables-manager 自动创建）：
# Chain TUNNEL-PORT
# pkts bytes target     prot opt in     out     source               destination
#    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            <EdgeIP>  tcp dpt:10351 to:<CloudCoreIP>:10003
```

### 2.2 边缘端配置（EdgeCore）

#### Step 1: EdgeCore 配置模板

**最小化配置**（keadm join 自动生成，install.sh 自动补充）：

```yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
database:
  aliasName: default
  dataSource: /var/lib/kubeedge/edgecore.db
  driverName: sqlite3
modules:
  edgeHub:
    enable: true
    heartbeat: 15
    httpServer: https://<CLOUD_IP>:10002    # 证书下载
    projectID: e632aba927ea4ac2b575ec1603d56f10
    quic:
      enable: false
    tlsCaFile: /etc/kubeedge/ca/rootCA.crt
    tlsCertFile: /etc/kubeedge/certs/server.crt
    tlsPrivateKeyFile: /etc/kubeedge/certs/server.key
    token: ""                               # keadm join 自动填充
    websocket:
      enable: true
      server: <CLOUD_IP>:10000             # CloudHub 端口
  
  # ✅ 关键配置 1: edgeStream（支持 kubectl logs/exec）
  edgeStream:
    enable: true                            # ✅ 必须启用
    handshakeTimeout: 30
    readDeadline: 15
    writeDeadline: 15
    server: <CLOUD_IP>:10004               # ✅ 连接 CloudCore tunnelPort
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
  
  # ✅ 关键配置 2: metaServer（EdgeMesh 必需）
  metaManager:
    metaServer:
      enable: true                          # ✅ EdgeMesh 必需
      server: 127.0.0.1:10550              # 仅本地监听
  
  # ✅ 关键配置 3: edged（内置 kubelet）
  edged:
    enable: true
    hostnameOverride: <NODE_NAME>
    cgroupDriver: cgroupfs
    cgroupRoot: ""
    cgroupsPerQOS: true
    clusterDNS:
    - 169.254.96.16                        # ✅ EdgeMesh DNS
    clusterDomain: cluster.local
    containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
    enableMetrics: true
    hostnameOverride: <NODE_NAME>
    imageGCHighThreshold: 80
    imageGCLowThreshold: 40
    imagePullProgressDeadline: 60
    maxPerPodContainerCount: 1
    networkPluginMTU: 1500
    nodeStatusUpdateFrequency: 10
    podSandboxImage: kubeedge/pause:3.6
    registerNode: true
    registerSchedulable: true
    remoteImageEndpoint: unix:///run/containerd/containerd.sock
    remoteRuntimeEndpoint: unix:///run/containerd/containerd.sock
    runtimeRequestTimeout: 2
    runtimeType: remote
    volumeStatsAggPeriod: 60000000000
    
    # ⚠️ 重要：tailoredKubeletConfig 仅用于内部配置
    # EdgeCore 不会在这些端口对外监听！
    tailoredKubeletConfig:
      address: 127.0.0.1                   # ⚠️ 仅本地，不对外
      cgroupDriver: cgroupfs
      cgroupRoot: ""
      clusterDNS:
      - 169.254.96.16
      clusterDomain: cluster.local
      containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
      evictionHard:
        imagefs.available: 15%
        memory.available: 100Mi
        nodefs.available: 10%
        nodefs.inodesFree: 5%
      featureGates:
        RotateKubeletServerCertificate: false
      imageGCHighThresholdPercent: 80
      imageGCLowThresholdPercent: 40
      maxPods: 110
      nodeStatusUpdateFrequency: 10s
      podSandboxImage: kubeedge/pause:3.6
      port: 10350                          # 内部配置，不监听外部
      readOnlyPort: 10255                  # 已废弃
      registerSchedulable: true
      rotateCertificates: false
      serializeImagePulls: false
```

**关键配置说明**：

1. **edgeStream 模块**
   - `enable: true` - **必须启用**，否则 logs/exec 不工作
   - `server: <CLOUD_IP>:10004` - 连接到 CloudCore 的 tunnelPort
   - EdgeCore 作为 WebSocket 客户端，不监听任何端口

2. **metaServer 模块**
   - `enable: true` - EdgeMesh 必需
   - `server: 127.0.0.1:10550` - 仅本地监听

3. **edged 模块**
   - `clusterDNS: 169.254.96.16` - 使用 EdgeMesh DNS
   - `tailoredKubeletConfig.address: 127.0.0.1` - **仅本地监听**
   - EdgeCore 不会在 10350/10351 对外监听！

#### Step 2: 验证 EdgeCore 配置

```bash
# 在边缘节点执行

# 1. 检查 edgeStream 配置
grep -A 15 "edgeStream:" /etc/kubeedge/config/edgecore.yaml

# 应该看到:
#   enable: true
#   server: <CLOUD_IP>:10004

# 2. 检查 EdgeCore 进程监听端口
ss -tlnp | grep edgecore

# ✅ 正确输出（只有本地监听）:
# tcp  LISTEN  0  128  127.0.0.1:10550  0.0.0.0:*  users:(("edgecore",pid=1234))

# ❌ 错误输出（监听了外部端口，需要修复）:
# tcp  LISTEN  0  128  :::10351  :::*  users:(("edgecore",pid=1234))

# 3. 检查 EdgeCore 日志
journalctl -u edgecore -n 50 | grep -i "edgestream\|tunnel"

# 应该看到类似:
# "EdgeStream started successfully"
# "Connected to CloudStream at <CLOUD_IP>:10004"
```

---

## 三、离线安装脚本增强

### 3.1 云端安装脚本修改（cloud/install/install.sh）

**关键步骤**：确保 CloudCore 启用 cloudStream 和 dynamicController

```bash
# 在 CloudCore 部署后，patch ConfigMap
echo "[6.5/7] Enabling CloudCore additional features..." | tee -a "$INSTALL_LOG"

# 使用 kubectl patch 启用 cloudStream 和 dynamicController
cat > /tmp/cloudcore-patch.yaml << 'EOF'
data:
  cloudcore.yaml: |
    modules:
      cloudHub:
        advertiseAddress:
        - EXTERNAL_IP_PLACEHOLDER
        https:
          enable: true
          port: 10002
        websocket:
          enable: true
          port: 10000
      cloudStream:
        enable: true                    # ✅ 启用
        streamPort: 10003
        tunnelPort: 10004
      dynamicController:
        enable: true                    # ✅ 启用
EOF

sed -i "s/EXTERNAL_IP_PLACEHOLDER/$EXTERNAL_IP/g" /tmp/cloudcore-patch.yaml
kubectl -n kubeedge patch cm cloudcore --patch-file /tmp/cloudcore-patch.yaml

# 重启 CloudCore 应用配置
kubectl rollout restart deployment cloudcore -n kubeedge
```

### 3.2 边缘安装脚本修改（edge/install/install.sh）

**关键步骤**：确保 edgeStream 启用且配置正确

```bash
# 在 keadm join 之后，自动配置 edgeStream
echo "[7/7] Configuring EdgeCore for logs/exec support..." | tee -a "$INSTALL_LOG"

CLOUD_IP="${CLOUD_ADDRESS%%:*}"

# 1. 启用 edgeStream
if grep -q "edgeStream:" /etc/kubeedge/config/edgecore.yaml; then
  # 修改现有配置
  sed -i '/edgeStream:/,/enable:/ s/enable: false/enable: true/' /etc/kubeedge/config/edgecore.yaml
  
  # 确保 server 配置存在
  if ! grep -A 10 "edgeStream:" /etc/kubeedge/config/edgecore.yaml | grep -q "server:"; then
    sed -i "/edgeStream:/a\    server: ${CLOUD_IP}:10004" /etc/kubeedge/config/edgecore.yaml
  fi
else
  # 添加完整 edgeStream 配置块
  cat >> /etc/kubeedge/config/edgecore.yaml << EOF
  edgeStream:
    enable: true
    handshakeTimeout: 30
    readDeadline: 15
    writeDeadline: 15
    server: ${CLOUD_IP}:10004
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
EOF
fi

# 2. 确保 tailoredKubeletConfig.address 为 127.0.0.1（不对外监听）
if grep -A 50 "tailoredKubeletConfig:" /etc/kubeedge/config/edgecore.yaml | grep -q "address:"; then
  sed -i '/tailoredKubeletConfig:/,/address:/ s/address: .*/address: 127.0.0.1/' /etc/kubeedge/config/edgecore.yaml
  echo "  ✓ tailoredKubeletConfig.address 设置为 127.0.0.1（仅本地监听）" | tee -a "$INSTALL_LOG"
fi

# 3. 重启 EdgeCore 应用配置
systemctl restart edgecore

echo "✓ EdgeCore logs/exec support configured" | tee -a "$INSTALL_LOG"
```

---

## 四、验证和测试

### 4.1 云端验证清单

```bash
# ✅ Step 1: CloudCore 状态
kubectl get pod -n kubeedge -l kubeedge=cloudcore
# 期望: Running

# ✅ Step 2: cloudStream 配置
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 5 "cloudStream:"
# 期望: enable: true, streamPort: 10003, tunnelPort: 10004

# ✅ Step 3: dynamicController 配置
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 3 "dynamicController:"
# 期望: enable: true

# ✅ Step 4: CloudCore 监听端口
CLOUDCORE_POD=$(kubectl get pod -n kubeedge -l kubeedge=cloudcore -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kubeedge $CLOUDCORE_POD -- netstat -tlnp | grep -E "10003|10004"
# 期望:
# tcp6  0  0 :::10003  :::*  LISTEN
# tcp6  0  0 :::10004  :::*  LISTEN

# ✅ Step 5: iptables-manager 状态
kubectl get pod -n kubeedge -l k8s-app=iptables-manager
# 期望: 至少 1 个 Pod Running

# ✅ Step 6: tunnelport ConfigMap
kubectl get cm tunnelport -n kubeedge -o yaml
# 期望: 包含边缘节点 IP 和端口映射

# ✅ Step 7: iptables 规则
sudo iptables -t nat -L TUNNEL-PORT -n -v
# 期望: 有 DNAT 规则指向 CloudCore:10003
```

### 4.2 边缘验证清单

```bash
# 在边缘节点执行

# ✅ Step 1: EdgeCore 状态
systemctl status edgecore
# 期望: active (running)

# ✅ Step 2: edgeStream 配置
grep -A 10 "edgeStream:" /etc/kubeedge/config/edgecore.yaml
# 期望: enable: true, server: <CLOUD_IP>:10004

# ✅ Step 3: EdgeCore 监听端口（仅本地）
ss -tlnp | grep edgecore
# 期望: 只有 127.0.0.1:10550
# 不应该有: :::10351 或 0.0.0.0:10351

# ✅ Step 4: EdgeCore 日志
journalctl -u edgecore -n 50 | grep -i "edgestream\|tunnel"
# 期望: "EdgeStream started successfully" 或类似信息

# ✅ Step 5: 证书文件
ls -l /etc/kubeedge/ca/rootCA.crt /etc/kubeedge/certs/server.{crt,key}
# 期望: 所有文件存在
```

### 4.3 端到端测试

```bash
# 在云端节点执行

# ✅ Test 1: 检查边缘节点状态
kubectl get node
# 期望: 边缘节点状态 Ready

# ✅ Test 2: 检查 node kubeletEndpoint.Port
kubectl get node <edge-node> -o jsonpath='{.status.daemonEndpoints.kubeletEndpoint.Port}'
# 期望: 10351（由 dynamicController 自动设置）

# ✅ Test 3: 部署测试 Pod
kubectl run test-nginx --image=nginx:1.21 --overrides='
{
  "spec": {
    "nodeSelector": {
      "kubernetes.io/hostname": "<edge-node>"
    }
  }
}'

# 等待 Pod 运行
kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s

# ✅ Test 4: kubectl logs
kubectl logs test-nginx --tail=10
# 期望: 看到 nginx 日志

# ✅ Test 5: kubectl exec
kubectl exec test-nginx -- nginx -v
# 期望: 输出 nginx 版本

# ✅ Test 6: kubectl attach
kubectl attach test-nginx -it
# 期望: 能够 attach 到容器

# 清理测试 Pod
kubectl delete pod test-nginx
```

---

## 五、故障排查指南

### 5.1 kubectl logs 返回 502 错误

**现象**：
```
Error from server: Get "https://<EdgeIP>:10351/containerLogs/...": 
proxy error from 0.0.0.0:6443 while dialing <EdgeIP>:10351, code 502: 502 Bad Gateway
```

**诊断步骤**：

```bash
# 1. 检查 CloudCore cloudStream 是否启用
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 5 "cloudStream:"
# 必须: enable: true

# 2. 检查 CloudCore 是否监听 10003 端口
CLOUDCORE_POD=$(kubectl get pod -n kubeedge -l kubeedge=cloudcore -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kubeedge $CLOUDCORE_POD -- netstat -tlnp | grep 10003
# 必须看到: tcp6  0  0 :::10003  :::*  LISTEN

# 3. 检查 iptables 规则
sudo iptables -t nat -L TUNNEL-PORT -n -v | grep 10351
# 必须有 DNAT 规则

# 4. 检查 iptables 规则是否被触发（pkts > 0）
sudo iptables -t nat -L TUNNEL-PORT -n -v
# 如果 pkts = 0，说明流量没有到达 iptables

# 5. 检查 tunnelport ConfigMap
kubectl get cm tunnelport -n kubeedge -o yaml
# 必须包含边缘节点 IP
```

**解决方法**：

```bash
# 方法 1: 重启 CloudCore（应用配置）
kubectl rollout restart deployment cloudcore -n kubeedge

# 方法 2: 重启 iptables-manager（重建规则）
kubectl delete pod -n kubeedge -l k8s-app=iptables-manager

# 方法 3: 手动检查 CloudCore 日志
kubectl logs -n kubeedge -l kubeedge=cloudcore --tail=100 | grep -i "stream\|error"
```

### 5.2 EdgeCore edgeStream 连接失败

**现象**：EdgeCore 日志显示 "connection refused" 或 "timeout"

**诊断步骤**：

```bash
# 在边缘节点执行

# 1. 检查 EdgeCore 日志
journalctl -u edgecore -n 100 | grep -i "edgestream\|tunnel\|error"

# 2. 测试 CloudCore tunnelPort 可达性
telnet <CLOUD_IP> 10004
# 或
nc -zv <CLOUD_IP> 10004

# 3. 检查证书文件
ls -l /etc/kubeedge/ca/rootCA.crt /etc/kubeedge/certs/server.{crt,key}

# 4. 检查 edgeStream 配置
grep -A 10 "edgeStream:" /etc/kubeedge/config/edgecore.yaml
```

**解决方法**：

```bash
# 方法 1: 确保 edgeStream 配置正确
# 修改 /etc/kubeedge/config/edgecore.yaml
# edgeStream.enable: true
# edgeStream.server: <CLOUD_IP>:10004

# 方法 2: 重新下载证书（如果证书问题）
systemctl stop edgecore
rm -rf /etc/kubeedge/ca /etc/kubeedge/certs
# 重新运行 keadm join 或 install.sh

# 方法 3: 检查防火墙
# 云端: 开放 10004 端口
sudo firewall-cmd --permanent --add-port=10004/tcp
sudo firewall-cmd --reload
```

### 5.3 EdgeCore 错误监听外部端口

**现象**：EdgeCore 在 `:::10351` 或 `0.0.0.0:10351` 监听

**诊断**：

```bash
# 在边缘节点执行
ss -tlnp | grep edgecore | grep -E "10350|10351"

# ❌ 错误输出:
# tcp  LISTEN  0  128  :::10351  :::*
```

**解决方法**：

```bash
# 修改 EdgeCore 配置
sudo sed -i '/tailoredKubeletConfig:/,/address:/ s/address: .*/address: 127.0.0.1/' /etc/kubeedge/config/edgecore.yaml

# 重启 EdgeCore
sudo systemctl restart edgecore

# 验证
ss -tlnp | grep edgecore
# ✅ 应该只看到: 127.0.0.1:10550
```

---

## 六、配置总结

### 6.1 关键配置对照表

| 组件 | 配置项 | 值 | 说明 |
|------|--------|-----|------|
| **CloudCore** | `cloudStream.enable` | `true` | ✅ 必须启用 |
| **CloudCore** | `cloudStream.streamPort` | `10003` | API Server 请求端口 |
| **CloudCore** | `cloudStream.tunnelPort` | `10004` | EdgeCore WebSocket 端口 |
| **CloudCore** | `dynamicController.enable` | `true` | ✅ 必须启用（设置 node port） |
| **CloudCore** | `hostNetwork` | `true` | 使用宿主机网络 |
| **EdgeCore** | `edgeStream.enable` | `true` | ✅ 必须启用 |
| **EdgeCore** | `edgeStream.server` | `<CloudIP>:10004` | 连接 CloudCore tunnel |
| **EdgeCore** | `metaServer.enable` | `true` | EdgeMesh 必需 |
| **EdgeCore** | `edged.clusterDNS` | `169.254.96.16` | EdgeMesh DNS |
| **EdgeCore** | `tailoredKubeletConfig.address` | `127.0.0.1` | ⚠️ 仅本地监听 |
| **iptables-manager** | 自动部署 | DaemonSet | keadm init 自动创建 |
| **iptables** | NAT 规则 | `<EdgeIP>:10351→CloudCore:10003` | 自动创建 |

### 6.2 端口用途总结

| 端口 | 组件 | 用途 | 监听地址 |
|------|------|------|----------|
| 6443 | K3s API Server | kubectl 入口 | 0.0.0.0 |
| 10000 | CloudCore cloudHub | EdgeCore 连接（WebSocket） | 0.0.0.0 |
| 10002 | CloudCore cloudHub | 证书下载（HTTPS） | 0.0.0.0 |
| 10003 | CloudCore cloudStream | API Server 请求（HTTPS） | 0.0.0.0 |
| 10004 | CloudCore cloudStream | EdgeCore tunnel（WebSocket） | 0.0.0.0 |
| 10351 | **虚拟端口** | iptables DNAT 目标，EdgeCore 不监听 | - |
| 10550 | EdgeCore metaServer | EdgeMesh API | 127.0.0.1 |

### 6.3 验证清单

- [ ] CloudCore Pod 运行正常
- [ ] CloudCore cloudStream 已启用（enable: true）
- [ ] CloudCore dynamicController 已启用（enable: true）
- [ ] CloudCore 监听 10003 和 10004 端口
- [ ] iptables-manager Pod 运行正常
- [ ] iptables NAT 规则存在
- [ ] tunnelport ConfigMap 包含边缘节点信息
- [ ] EdgeCore 服务运行正常
- [ ] EdgeCore edgeStream 已启用（enable: true）
- [ ] EdgeCore edgeStream.server 配置正确
- [ ] EdgeCore 只监听 127.0.0.1:10550（不监听外部端口）
- [ ] EdgeCore 日志显示 edgeStream 连接成功
- [ ] kubectl logs 命令工作正常
- [ ] kubectl exec 命令工作正常

---

## 七、与官方文档对照

根据 KubeEdge 官方文档和 GitHub examples 仓库的分析：

1. **官方推荐架构**：EdgeCore 不对外监听端口，所有通信通过 edgeStream tunnel
2. **iptables-manager**：由 keadm init 自动部署，无需手动配置
3. **证书管理**：自动生成和下载，无需手动干预
4. **dynamicController**：负责设置 node.status.daemonEndpoints.kubeletEndpoint.Port

**当前项目配置状态**：

✅ **已正确实现**：
- CloudCore 使用 keadm 部署
- EdgeCore 使用 keadm join 注册
- edgeStream 在安装脚本中自动启用
- 证书自动下载

⚠️ **需要验证**：
- EdgeCore 是否监听外部端口（应该只监听 127.0.0.1:10550）
- iptables 规则是否正确生效
- dynamicController 是否已启用

本文档基于官方架构，提供了完整的离线部署最佳实践方案。
