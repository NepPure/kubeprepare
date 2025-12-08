# kubectl logs/exec 最佳实践文档

**基于 KubeEdge 官方文档和源码分析**

## 环境信息

- **Cloud节点**: 152.136.201.36 (公网) / 10.2.0.12 (内网)
- **Edge节点**: 154.8.209.41 (公网) / 10.2.4.15 (内网)
- **K3s**: v1.31.12
- **KubeEdge**: v1.22.0
- **EdgeMesh**: v1.17.0

---

## 一、官方架构设计

根据 [KubeEdge 官方文档](https://kubeedge.io/zh/docs/advanced/debug/#在边缘节点上使用-kubectl-logs-exec-命令) 和源码 `docs/proposals/sig-node/exec-logs.md`，kubectl logs/exec 的正确架构如下：

### 1.1 核心组件

#### CloudCore (云端)
- **cloudStream 模块**：监听来自 API Server 的请求
  - `streamPort`: 10003 (HTTPS，接收 API Server 的 logs/exec/attach 请求)
  - `tunnelPort`: 10004 (WebSocket，与 EdgeCore 建立 tunnel 连接)
  
#### EdgeCore (边缘)
- **edgeStream 模块**：通过 WebSocket 连接到 CloudCore
  - `server`: CloudCore 的 `IP:10004`
  - 负责将 API Server 的请求转发到本地 kubelet/CRI
  
#### edged (EdgeCore 的 kubelet)
- **不需要监听外部端口**！
- 只需要配置 `tailoredKubeletConfig`
- 通过 edgeStream 模块内部通信

#### iptables-manager (云端 DaemonSet)
- 自动管理 iptables 规则
- 将发往边缘节点 `EdgeNodeIP:10351` 的流量 DNAT 到 CloudCore 的 `streamPort:10003`

---

## 二、正确的网络拓扑和数据流

### 2.1 组件部署拓扑

```
┌─────────────────────────────────────────────────────────────┐
│                     Cloud Node (10.2.0.12)                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐                                          │
│  │  API Server  │ (K3s 单进程，host network)               │
│  │  :6443       │                                          │
│  └──────┬───────┘                                          │
│         │                                                   │
│         │ kubectl logs/exec 请求                           │
│         │ GET https://10.2.4.15:10351/containerLogs/...   │
│         ↓                                                   │
│  ┌──────────────────────────────────────────┐             │
│  │         iptables NAT OUTPUT 链           │             │
│  │  DNAT: 10.2.4.15:10351 → 10.2.0.12:10003 │             │
│  └──────────────┬───────────────────────────┘             │
│                 │                                          │
│                 ↓                                          │
│  ┌─────────────────────────┐                              │
│  │  CloudCore (Pod)        │  hostNetwork: true           │
│  │  - cloudStream module   │                              │
│  │    * streamPort: 10003  │ ← 接收 API Server 请求      │
│  │    * tunnelPort: 10004  │ ← EdgeCore 连接此端口       │
│  └─────────────┬───────────┘                              │
│                │                                          │
│                │ WebSocket Tunnel                         │
└────────────────┼──────────────────────────────────────────┘
                 │
                 │ 跨网络 (公网/VPN)
                 │
┌────────────────┼──────────────────────────────────────────┐
│                ↓                                          │
│  ┌─────────────────────────┐                              │
│  │  EdgeCore (systemd)     │                              │
│  │  - edgeStream module    │                              │
│  │    * enable: true       │                              │
│  │    * server: 152.136.201.36:10004                      │
│  │  - edged module         │                              │
│  │    * 不监听外部端口     │                              │
│  │    * 通过 edgeStream 内部通信                          │
│  └─────────────┬───────────┘                              │
│                │                                          │
│                ↓                                          │
│  ┌─────────────────────────┐                              │
│  │   containerd CRI        │                              │
│  │   /run/containerd/containerd.sock                      │
│  └─────────────────────────┘                              │
│                                                           │
│               Edge Node (10.2.4.15)                        │
└───────────────────────────────────────────────────────────┘
```

### 2.2 kubectl logs 时序图

```
User                API Server (10.2.0.12:6443)     iptables      CloudCore (10.2.0.12:10003/10004)     EdgeCore (10.2.4.15)        containerd
 │                           │                         │                      │                              │                          │
 │ kubectl logs pod-x        │                         │                      │                              │                          │
 ├──────────────────────────>│                         │                      │                              │                          │
 │                           │                         │                      │                              │                          │
 │                           │ GET https://10.2.4.15:10351/containerLogs/...  │                              │                          │
 │                           ├────────────────────────>│                      │                              │                          │
 │                           │                         │                      │                              │                          │
 │                           │                         │ DNAT                 │                              │                          │
 │                           │                         │ 10.2.4.15:10351 →    │                              │                          │
 │                           │                         │ 10.2.0.12:10003      │                              │                          │
 │                           │                         ├─────────────────────>│                              │                          │
 │                           │                         │                      │                              │                          │
 │                           │                         │                      │ 1. 解析请求                  │                          │
 │                           │                         │                      │ 2. 查找 edge peer (tunnel)   │                          │
 │                           │                         │                      │                              │                          │
 │                           │                         │                      │ Message: containerLogs       │                          │
 │                           │                         │                      │ (通过 WebSocket tunnel)      │                          │
 │                           │                         │                      ├─────────────────────────────>│                          │
 │                           │                         │                      │                              │                          │
 │                           │                         │                      │                              │ edgeStream 接收请求      │
 │                           │                         │                      │                              │ 调用本地 kubelet API     │
 │                           │                         │                      │                              ├─────────────────────────>│
 │                           │                         │                      │                              │                          │
 │                           │                         │                      │                              │                          │ 读取日志文件
 │                           │                         │                      │                              │                          │ /var/log/pods/...
 │                           │                         │                      │                              │<─────────────────────────┤
 │                           │                         │                      │                              │                          │
 │                           │                         │                      │         日志数据              │                          │
 │                           │                         │                      │<─────────────────────────────┤                          │
 │                           │                         │                      │                              │                          │
 │                           │                         │       日志数据        │                              │                          │
 │                           │<────────────────────────┴──────────────────────┤                              │                          │
 │                           │                         │                      │                              │                          │
 │     日志输出              │                         │                      │                              │                          │
 │<──────────────────────────┤                         │                      │                              │                          │
 │                           │                         │                      │                              │                          │
```

### 2.3 关键点说明

1. **EdgeCore 不监听外部端口**
   - EdgeCore 的 edged 模块不需要在 10351 或任何外部端口监听
   - 所有通信通过 edgeStream 模块的 WebSocket tunnel 进行

2. **iptables 规则的作用**
   - 将 API Server 发往 `EdgeNodeIP:10351` 的请求 DNAT 到 CloudCore 的 `streamPort`
   - 规则必须在 API Server 所在节点的 OUTPUT 链生效

3. **Node 对象的端口设置**
   - `node.status.daemonEndpoints.kubeletEndpoint.Port` 应该设置为 10351
   - 这是 CloudCore 的 `dynamicController.tunnelPort` 值
   - 不是 EdgeCore 实际监听的端口！

---

## 三、必需的配置

### 3.1 CloudCore 配置

```yaml
# /etc/kubeedge/config/cloudcore.yaml
modules:
  cloudStream:
    enable: true
    streamPort: 10003          # 接收 API Server 的 HTTPS 请求
    tlsStreamCAFile: /etc/kubeedge/ca/streamCA.crt
    tlsStreamCertFile: /etc/kubeedge/certs/stream.crt
    tlsStreamPrivateKeyFile: /etc/kubeedge/certs/stream.key
  
  cloudHub:
    advertiseAddress:          # CloudCore 的公网 IP
    - "152.136.201.36"
    websocket:
      enable: true
      port: 10000
    
  dynamicController:
    enable: true               # 必须启用!
    
commonConfig:
  tunnelPort: 10004           # EdgeCore 连接的 WebSocket 端口
```

**关键参数说明**：
- `streamPort: 10003`: CloudCore 监听 API Server 请求的端口
- `tunnelPort: 10004`: EdgeCore 建立 WebSocket 连接的端口
- `dynamicController.enable: true`: **必须启用**，负责设置 node 对象的 `kubeletEndpoint.Port`

### 3.2 EdgeCore 配置

```yaml
# /etc/kubeedge/config/edgecore.yaml
modules:
  edgeStream:
    enable: true
    handshakeTimeout: 30
    readDeadline: 15
    writeDeadline: 15
    server: "152.136.201.36:10004"    # CloudCore 的 tunnelPort
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
  
  edged:
    enable: true
    hostnameOverride: edge-1
    networkPluginName: cni
    clusterDNS:
    - 169.254.96.16               # EdgeMesh DNS
    tailoredKubeletConfig:
      # 注意：这些参数用于内部配置，EdgeCore 不会在这些端口监听外部连接
      address: 127.0.0.1          # 本地地址即可
      port: 10351                 # 与 dynamicController.tunnelPort 一致
      readOnlyPort: 10350         # 只读端口 (可选)
      cgroupDriver: cgroupfs
      containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
  
  metaManager:
    metaServer:
      enable: true
      server: 127.0.0.1:10550     # EdgeMesh 需要
```

**关键点**：
- `edgeStream.server`: 必须指向 CloudCore 的 `IP:tunnelPort`
- `edged.tailoredKubeletConfig.address`: 设置为 `127.0.0.1` 即可，**不需要监听外部端口**
- `edged.tailoredKubeletConfig.port`: 设置为 10351，与 CloudCore 的 `tunnelPort` 一致

### 3.3 iptables-manager 配置

#### 方式一：使用 Helm 自动部署 (推荐)

```bash
helm install cloudcore kubeedge/cloudcore \
  --set iptablesManager.enable=true \
  --set iptablesManager.mode=external \
  --namespace kubeedge
```

#### 方式二：手动部署 iptables-manager DaemonSet

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloud-iptables-manager
  namespace: kubeedge
spec:
  selector:
    matchLabels:
      k8s-app: iptables-manager
  template:
    metadata:
      labels:
        k8s-app: iptables-manager
    spec:
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/master: ""  # 只在 master 节点运行
      tolerations:
      - operator: Exists
      containers:
      - name: iptables-manager
        image: kubeedge/iptables-manager:v1.22.0
        imagePullPolicy: IfNotPresent
        command:
        - /usr/local/bin/iptablesmanager
        args:
        - --forward-port=10003          # CloudCore 的 streamPort
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
```

**iptables-manager 的职责**：
1. 监听 CloudCore Pod 的创建/删除
2. 读取 `kubeedge/tunnelport` ConfigMap 获取边缘节点信息
3. 自动在 OUTPUT 和 PREROUTING 链创建 DNAT 规则：
   ```
   iptables -t nat -A OUTPUT -d <EdgeNodeIP> -p tcp --dport 10351 -j DNAT --to <CloudCoreIP>:10003
   iptables -t nat -A PREROUTING -d <EdgeNodeIP> -p tcp --dport 10351 -j DNAT --to <CloudCoreIP>:10003
   ```

---

## 四、tunnelport ConfigMap

iptables-manager 依赖此 ConfigMap 来管理边缘节点信息：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tunnelport
  namespace: kubeedge
  annotations:
    tunnelportrecord.kubeedge.io: '{"ipTunnelPort":{"10.2.4.15":10351},"port":{"10351":true}}'
```

**说明**：
- `ipTunnelPort`: 记录边缘节点 IP 和对应的 tunnelPort
- `port`: 记录所有使用的端口

**注意**：此 ConfigMap 由 CloudCore 的 dynamicController 自动管理，通常不需要手动创建。

---

## 五、验证步骤

### 5.1 验证 CloudCore 配置

```bash
# 1. 检查 cloudStream 是否启用
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 5 "cloudStream:"

# 2. 检查 CloudCore 监听端口
kubectl get pod -n kubeedge -l kubeedge=cloudcore -o wide
kubectl exec -n kubeedge <cloudcore-pod> -- netstat -tlnp | grep -E "10003|10004"

# 应该看到：
# tcp6  0  0 :::10003  :::*  LISTEN  <pid>/cloudcore
# tcp6  0  0 :::10004  :::*  LISTEN  <pid>/cloudcore

# 3. 检查 tunnelport ConfigMap
kubectl get cm tunnelport -n kubeedge -o yaml
```

### 5.2 验证 EdgeCore 配置

```bash
# 1. 检查 edgeStream 配置
ssh edge-node "grep -A 10 'edgeStream:' /etc/kubeedge/config/edgecore.yaml"

# 2. 检查 EdgeCore 进程（不应该监听外部端口）
ssh edge-node "ss -tlnp | grep edgecore"
# 应该只看到：
# tcp  LISTEN  127.0.0.1:10550  (metaServer)
# 不应该有 10351 或其他外部端口

# 3. 检查 EdgeCore 日志
ssh edge-node "journalctl -u edgecore -n 50 | grep -i 'edgestream\|tunnel'"
```

### 5.3 验证 iptables 规则

```bash
# 在 Cloud 节点执行
iptables -t nat -L OUTPUT -n -v | grep 10351
iptables -t nat -L PREROUTING -n -v | grep 10351
iptables -t nat -L TUNNEL-PORT -n -v

# 应该看到类似：
# Chain OUTPUT
#  pkts  target    destination
#    0   DNAT      10.2.4.15  tcp dpt:10351 to:10.2.0.12:10003

# Chain TUNNEL-PORT
#  pkts  target    destination
#    0   DNAT      10.2.4.15  tcp dpt:10351 to:10.2.0.12:10003
```

### 5.4 验证 Node 对象

```bash
kubectl get node edge-1 -o jsonpath='{.status.daemonEndpoints.kubeletEndpoint.Port}'
# 应该输出: 10351
```

### 5.5 端到端测试

```bash
# 1. 测试 kubectl logs
kubectl logs <edge-pod-name> -n kubeedge --tail=10

# 2. 测试 kubectl exec
kubectl exec -it <edge-pod-name> -n kubeedge -- sh

# 3. 测试 kubectl attach
kubectl run test-pod --image=nginx --restart=Never -n kubeedge
kubectl attach test-pod -n kubeedge -it
```

---

## 六、常见问题诊断

### 6.1 502 Bad Gateway 错误

**现象**：
```
Error from server: Get "https://10.2.4.15:10351/containerLogs/...": 
proxy error from 0.0.0.0:6443 while dialing 10.2.4.15:10351, code 502: 502 Bad Gateway
```

**可能原因和解决方法**：

1. **iptables 规则未生效** (pkts = 0)
   ```bash
   # 检查规则计数器
   iptables -t nat -L TUNNEL-PORT -n -v
   
   # 如果 pkts = 0，检查：
   # a. iptables-manager 是否运行
   kubectl get pod -n kubeedge -l k8s-app=iptables-manager
   
   # b. tunnelport ConfigMap 是否正确
   kubectl get cm tunnelport -n kubeedge -o yaml
   
   # c. 手动测试 iptables（临时）
   iptables -t nat -D OUTPUT -d 10.2.4.15 -p tcp --dport 10351 -j DNAT --to 10.2.0.12:10003
   iptables -t nat -A OUTPUT -d 10.2.4.15 -p tcp --dport 10351 -j DNAT --to 10.2.0.12:10003
   ```

2. **CloudCore 的 cloudStream 未启用**
   ```bash
   kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 3 "cloudStream:"
   # enable 应该为 true
   ```

3. **EdgeCore 的 edgeStream 未启用或配置错误**
   ```bash
   ssh edge-node "grep -A 10 'edgeStream:' /etc/kubeedge/config/edgecore.yaml"
   # enable 应该为 true
   # server 应该指向 CloudCore 的 IP:10004
   ```

4. **CloudCore 和 EdgeCore 之间的 tunnel 连接断开**
   ```bash
   # 查看 CloudCore 日志
   kubectl logs -n kubeedge <cloudcore-pod> | grep -i "tunnel\|edge-1"
   
   # 查看 EdgeCore 日志
   ssh edge-node "journalctl -u edgecore -n 100 | grep -i 'tunnel\|cloudcore'"
   ```

### 6.2 find edge peer done 错误

**现象**：CloudCore 日志显示 `find edge peer done, so stop this connection`

**原因**：CloudCore 找到了 EdgeCore 的 tunnel 连接，但在转发请求时连接被意外关闭

**解决方法**：
1. 检查 EdgeCore 的 edgeStream 配置
2. 检查 EdgeCore 日志是否有 "stop signal" 相关错误
3. 重启 EdgeCore：`systemctl restart edgecore`

### 6.3 EdgeCore 监听了 10351 但无法连接

**错误做法**：让 EdgeCore 在 `0.0.0.0:10351` 监听外部连接

**正确做法**：EdgeCore **不应该**监听外部端口，所有通信通过 edgeStream 的 WebSocket tunnel

如果发现 EdgeCore 监听了 10351：
```bash
# 修改配置
ssh edge-node "sed -i '/tailoredKubeletConfig:/,/address:/ s/address: 0.0.0.0/address: 127.0.0.1/' /etc/kubeedge/config/edgecore.yaml"

# 重启 EdgeCore
ssh edge-node "systemctl restart edgecore"
```

---

## 七、与当前环境的差异对比

### 7.1 当前问题分析

根据之前的诊断，当前环境存在以下问题：

| 检查项 | 期望值 | 当前值 | 状态 |
|--------|--------|--------|------|
| CloudCore hostNetwork | true | true | ✅ |
| CloudCore streamPort | 监听 10003 | 监听 `:::10003` | ✅ |
| CloudCore tunnelPort | 监听 10004 | 监听 `:::10004` | ✅ |
| EdgeCore edgeStream.enable | true | true | ✅ |
| EdgeCore edgeStream.server | 152.136.201.36:10004 | 152.136.201.36:10004 | ✅ |
| EdgeCore 监听外部端口 | 不监听 | 监听 `:::10351` | ❌ |
| iptables TUNNEL-PORT 规则 | 正确 DNAT | 存在但有错误的第二条规则 | ⚠️ |
| tunnelport ConfigMap | `{"ipTunnelPort":{"10.2.4.15":10351}}` | 正确 | ✅ |
| iptables 规则被触发 | pkts > 0 | pkts = 0 | ❌ |

### 7.2 根本原因

经过深入分析，问题的根本原因是：

1. **EdgeCore 错误地监听了外部端口 `:::10351`**
   - 这导致跨子网访问问题（云端 10.2.0.0/24 无法访问边缘 10.2.4.0/24）
   - EdgeCore 应该只监听 `127.0.0.1`，不监听外部端口

2. **iptables 规则没有被触发**
   - 因为 API Server 尝试直接连接 10.2.4.15:10351 时被网络层拒绝（跨子网限制）
   - 连接在 TCP 握手阶段就失败，没有到达 iptables 处理阶段

3. **iptables 规则存在冗余和错误**
   - OUTPUT 链有重复规则
   - TUNNEL-PORT 链有错误的 fallback 规则

---

## 八、修复步骤

### 8.1 修复 EdgeCore 配置

```bash
# 1. 修改 EdgeCore 配置，将监听地址改为 127.0.0.1
ssh root@154.8.209.41 "sed -i '/tailoredKubeletConfig:/,/address:/ s/address: 0.0.0.0/address: 127.0.0.1/' /etc/kubeedge/config/edgecore.yaml"

# 2. 验证修改
ssh root@154.8.209.41 "grep -A 5 'tailoredKubeletConfig:' /etc/kubeedge/config/edgecore.yaml | grep address"

# 3. 重启 EdgeCore
ssh root@154.8.209.41 "systemctl restart edgecore"

# 4. 验证不再监听外部端口
ssh root@154.8.209.41 "ss -tlnp | grep edgecore"
# 应该只看到 127.0.0.1:10550，没有 :::10351
```

### 8.2 清理和重建 iptables 规则

```bash
# 在 Cloud 节点执行

# 1. 清理所有 TUNNEL-PORT 规则
iptables -t nat -F TUNNEL-PORT

# 2. 删除 OUTPUT 链中的重复规则
iptables -t nat -D OUTPUT -d 10.2.4.15 -p tcp --dport 10351 -j DNAT --to-destination 10.2.0.12:10003 2>/dev/null || true
iptables -t nat -D OUTPUT -d 10.2.4.15 -p tcp --dport 10351 -j DNAT --to-destination 10.43.113.225:10003 2>/dev/null || true

# 3. 重启 iptables-manager，让它重新创建规则
kubectl delete pod -n kubeedge -l k8s-app=iptables-manager

# 4. 等待 iptables-manager 重新创建规则（约 10 秒）
sleep 10

# 5. 验证规则
iptables -t nat -L TUNNEL-PORT -n -v
```

### 8.3 测试修复结果

```bash
# 1. 直接测试 CloudCore 的 streamPort（应该成功）
curl -k https://10.2.0.12:10003/containerLogs/kubeedge/edge-eclipse-mosquitto-vhr85/edge-eclipse-mosquitto 2>&1 | head -10

# 2. 测试 kubectl logs（应该成功）
kubectl logs edge-eclipse-mosquitto-vhr85 -n kubeedge --tail=10

# 3. 测试 kubectl exec（应该成功）
kubectl exec edge-eclipse-mosquitto-vhr85 -n kubeedge -- id
```

---

## 九、更新安装脚本

需要更新边缘节点安装脚本，确保 EdgeCore 配置正确：

### edge/install/install.sh 修改

在 `edgeStream` 配置之后，添加确保 `tailoredKubeletConfig.address` 设置为 `127.0.0.1` 的逻辑：

```bash
# 4. Enable EdgeStream for kubectl logs/exec support
echo "  配置 EdgeStream（用于 kubectl logs/exec 支持）..." | tee -a "$INSTALL_LOG"
if grep -q "edgeStream:" /etc/kubeedge/config/edgecore.yaml; then
  # ... 现有的 edgeStream 配置代码 ...
  
  # 5. 确保 tailoredKubeletConfig.address 设置为 127.0.0.1（EdgeCore 不应该监听外部端口）
  if grep -A 20 "tailoredKubeletConfig:" /etc/kubeedge/config/edgecore.yaml | grep -q "address:"; then
    sed -i '/tailoredKubeletConfig:/,/address:/ s/address: .*/address: 127.0.0.1/' /etc/kubeedge/config/edgecore.yaml
    echo "  ✓ tailoredKubeletConfig.address 设置为 127.0.0.1" | tee -a "$INSTALL_LOG"
  fi
fi
```

---

## 十、总结

### 核心要点

1. **EdgeCore 不监听外部端口**：所有通信通过 edgeStream 的 WebSocket tunnel
2. **iptables DNAT 规则**：由 iptables-manager 自动管理，将 `EdgeNodeIP:10351` 重定向到 CloudCore 的 streamPort
3. **dynamicController 必须启用**：负责设置 node 对象的 `kubeletEndpoint.Port`
4. **CloudCore 使用 hostNetwork**：直接在 host 的网络命名空间中监听

### 关键配置总结

| 组件 | 配置项 | 值 | 说明 |
|------|--------|-----|------|
| CloudCore | cloudStream.enable | true | 启用 cloudStream 模块 |
| CloudCore | cloudStream.streamPort | 10003 | API Server 请求端口 |
| CloudCore | commonConfig.tunnelPort | 10004 | EdgeCore 连接端口 |
| CloudCore | dynamicController.enable | true | 设置 node kubeletEndpoint.Port |
| EdgeCore | edgeStream.enable | true | 启用 edgeStream 模块 |
| EdgeCore | edgeStream.server | CloudIP:10004 | 连接到 CloudCore tunnel |
| EdgeCore | edged.tailoredKubeletConfig.address | **127.0.0.1** | 不监听外部端口 |
| EdgeCore | edged.tailoredKubeletConfig.port | 10351 | 内部配置，与 tunnelPort 一致 |
| iptables-manager | enable | true | 自动管理 iptables 规则 |
| iptables-manager | forward-port | 10003 | CloudCore streamPort |

### 验证清单

- [ ] CloudCore cloudStream 已启用
- [ ] CloudCore 监听 10003 和 10004 端口
- [ ] EdgeCore edgeStream 已启用并连接到 CloudCore
- [ ] EdgeCore **不监听**外部端口（只有 127.0.0.1:10550）
- [ ] iptables-manager Pod 运行正常
- [ ] tunnelport ConfigMap 包含正确的边缘节点信息
- [ ] iptables TUNNEL-PORT 规则存在且正确
- [ ] node 对象的 kubeletEndpoint.Port 为 10351
- [ ] `kubectl logs` 命令可以正常工作
- [ ] `kubectl exec` 命令可以正常工作
