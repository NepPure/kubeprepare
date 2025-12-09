# K3S + KubeEdge 离线部署 kubectl logs/exec 最佳实践指南

> 基于 KubeEdge 官方文档和 kubeedge/examples 仓库的最佳实践

## 目录

- [一、问题概述](#一问题概述)
- [二、官方架构设计](#二官方架构设计)
- [三、离线部署核心配置](#三离线部署核心配置)
- [四、部署验证](#四部署验证)
- [五、故障排查](#五故障排查)

---

## 一、问题概述

### 1.1 典型错误

在 K3S + KubeEdge 环境中执行 `kubectl logs` 或 `kubectl exec` 时，常见错误：

```bash
# 错误 1：kubelet 端口无法访问
Error from server: Get "https://<edge-node-ip>:10250/containerLogs/...": 
dial tcp <edge-node-ip>:10250: i/o timeout

# 错误 2：连接升级失败
error: unable to upgrade connection: pod does not exist

# 错误 3：超时
Error from server: Get "https://<edge-node-ip>:10250/...": context deadline exceeded
```

### 1.2 根本原因

- **边缘节点网络隔离**：API Server 无法直接访问边缘节点的 kubelet (10250)
- **缺少流式通道**：未建立 CloudCore ↔ EdgeCore 的 Stream 隧道
- **配置不完整**：CloudStream/EdgeStream 未启用或配置错误

---

## 二、官方架构设计

### 2.1 数据流架构

```
┌───────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  kubectl  │────▶│  API Server  │────▶│  CloudCore   │────▶│  EdgeCore    │
│           │     │  (K3S)       │     │  (Cloud)     │     │  (Edge)      │
└───────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                         │                     │                     │
                         │                     │                     │
                    HTTPS 请求           streamPort:10003      本地 CRI
                    (重定向到 CloudCore)  tunnelPort:10004    (containerd)
                         │                     │                     │
                         │                     │                     │
                    iptables NAT         WebSocket Tunnel      容器日志/exec
```

### 2.2 关键组件

| 组件 | 作用 | 端口 | 协议 |
|------|------|------|------|
| **CloudStream** | 接收 API Server 的流式请求 | 10003 | HTTPS |
| **tunnelPort** | CloudCore 与 EdgeCore 的 WebSocket 隧道 | 10004 | WebSocket |
| **EdgeStream** | EdgeCore 的流式客户端，连接到 tunnelPort | - | WebSocket |
| **dynamicController** | 管理边缘节点的流式连接 | - | - |
| **iptables NAT** | 将 API Server 的请求重定向到 CloudCore | - | - |

### 2.3 请求流程

1. **用户执行命令**：
   ```bash
   kubectl logs nginx-pod -n default
   ```

2. **API Server 请求**：
   ```
   GET https://<edge-node-internal-ip>:10250/containerLogs/default/nginx-pod/nginx
   ```

3. **iptables 重定向**（在 API Server 所在节点）：
   ```bash
   # 将边缘节点 IP:10250 重定向到 CloudCore:10003
   iptables -t nat -A OUTPUT -p tcp -d <edge-node-ip> --dport 10250 \
            -j DNAT --to-destination <cloudcore-pod-ip>:10003
   ```

4. **CloudCore 处理**：
   - CloudStream (10003) 接收 HTTPS 请求
   - 通过 tunnelPort (10004) 转发给对应的 EdgeCore

5. **EdgeCore 执行**：
   - EdgeStream 接收请求
   - 调用本地 CRI (containerd) 获取日志
   - 通过 WebSocket 隧道返回结果

6. **结果返回**：
   ```
   EdgeCore → CloudCore (tunnelPort) → CloudCore (streamPort) → API Server → kubectl
   ```

---

## 三、离线部署核心配置

### 3.1 CloudCore 配置（云端）

#### 方式 1：使用 keadm init（推荐）

```bash
# 1. 初始化 CloudCore（自动生成证书和 CRD）
keadm init \
  --advertise-address="YOUR_EXTERNAL_IP" \
  --kubeedge-version="v1.22.0" \
  --kube-config="/root/.kube/config" \
  --set cloudCore.modules.cloudStream.enable=true

# 2. keadm 会自动：
#    - 生成所有必需的证书
#    - 部署 cloudcore Deployment
#    - 部署 iptables-manager DaemonSet（自动配置 NAT 规则）
#    - 安装 CRD
```

#### 方式 2：手动修改 ConfigMap

```bash
# 如果 CloudCore 已部署，修改配置
kubectl edit cm cloudcore -n kubeedge
```

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
        enable: true              # ✅ 必须启用
        streamPort: 10003         # API Server 访问端口
        tunnelPort: 10004         # EdgeCore WebSocket 连接端口
        # 证书路径（keadm 自动生成，无需修改）
        tlsStreamCAFile: /etc/kubeedge/ca/rootCA.crt
        tlsStreamCertFile: /etc/kubeedge/certs/server.crt
        tlsStreamPrivateKeyFile: /etc/kubeedge/certs/server.key
        tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
        tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
        tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
      
      dynamicController:
        enable: true              # ✅ 必须启用
      
      cloudHub:
        advertiseAddress:
          - "YOUR_EXTERNAL_IP"    # EdgeCore 连接的地址
        websocket:
          enable: true
          port: 10000
        https:
          enable: true
          port: 10002
```

#### 应用配置并重启

```bash
# 1. 更新 ConfigMap 后重启 CloudCore
kubectl rollout restart deployment cloudcore -n kubeedge

# 2. 等待 Pod 就绪
kubectl wait --for=condition=ready pod -l kubeedge=cloudcore -n kubeedge --timeout=120s
```

### 3.2 EdgeCore 配置（边缘节点）

#### 标准配置流程

```bash
# 1. 在云端生成 token
TOKEN=$(keadm gettoken --kube-config=/root/.kube/config)

# 2. 在边缘节点执行 join（会自动下载证书）
keadm join \
  --cloudcore-ipport="YOUR_EXTERNAL_IP:10000" \
  --edgenode-name="edge-node-1" \
  --token="$TOKEN" \
  --kubeedge-version="v1.22.0"

# 3. keadm join 会自动：
#    - 从 CloudCore:10002 下载证书
#    - 生成基础配置文件
#    - 启动 edgecore 服务
```

#### 手动修改配置（关键步骤）

```bash
# 编辑 EdgeCore 配置
vim /etc/kubeedge/config/edgecore.yaml
```

```yaml
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
modules:
  # ============================================
  # 核心配置：EdgeStream（kubectl logs/exec）
  # ============================================
  edgeStream:
    enable: true                      # ✅ 必须启用
    handshakeTimeout: 30
    readDeadline: 15
    writeDeadline: 15
    server: "YOUR_EXTERNAL_IP:10004"  # ⚠️ 关键：CloudCore 的 tunnelPort
    # 证书路径（keadm join 自动下载）
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
  
  # ============================================
  # edged 配置（EdgeCore 的 kubelet）
  # ============================================
  edged:
    enable: true
    hostnameOverride: edge-node-1     # 节点名称
    clusterDNS:
      - 169.254.96.16                 # EdgeMesh DNS（如果使用）
    clusterDomain: cluster.local
    cgroupDriver: systemd
    # 容器运行时配置
    containerRuntime: remote
    runtimeType: remote
    remoteImageEndpoint: unix:///run/containerd/containerd.sock
    remoteRuntimeEndpoint: unix:///run/containerd/containerd.sock
    # ⚠️ 不需要配置 tailoredKubeletConfig.address
    # edged 不监听外部端口，通过 edgeStream 内部通信
  
  # ============================================
  # metaServer 配置（EdgeMesh 需要）
  # ============================================
  metaManager:
    metaServer:
      enable: true                    # EdgeMesh 需要
      server: 127.0.0.1:10550
```

#### 重启 EdgeCore

```bash
# 应用配置
systemctl restart edgecore

# 检查状态
systemctl status edgecore
journalctl -u edgecore -f
```

### 3.3 iptables 配置（云端）

#### 自动配置（推荐）

`keadm init` 会自动部署 `iptables-manager` DaemonSet，无需手动操作。

验证：

```bash
# 检查 iptables-manager 是否运行
kubectl get pods -n kubeedge -l k8s-app=kubeedge-iptables-manager

# 检查 NAT 规则
iptables -t nat -L OUTPUT -n | grep 10003
```

#### 手动配置（仅在自动失败时）

```bash
# 在 API Server 所在节点（K3S master）执行
# 获取 CloudCore Pod IP
CLOUDCORE_IP=$(kubectl get pod -n kubeedge -l kubeedge=cloudcore -o jsonpath='{.items[0].status.podIP}')

# 获取边缘节点内网 IP
EDGE_NODE_IP=$(kubectl get node edge-node-1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

# 添加 NAT 规则（将 Edge kubelet 请求重定向到 CloudCore）
iptables -t nat -A OUTPUT -p tcp -d $EDGE_NODE_IP --dport 10250 \
         -j DNAT --to-destination $CLOUDCORE_IP:10003

# 持久化规则
iptables-save > /etc/iptables.rules
```

---

## 四、部署验证

### 4.1 组件状态检查

```bash
# 1. 检查 CloudCore
kubectl get pods -n kubeedge -l kubeedge=cloudcore
kubectl logs -n kubeedge -l kubeedge=cloudcore | grep -i "cloudstream\|tunnel"

# 2. 检查边缘节点状态
kubectl get nodes
# 应该看到边缘节点状态为 Ready

# 3. 检查 EdgeCore（在边缘节点）
systemctl status edgecore
journalctl -u edgecore | grep -i "edgestream\|tunnel"
```

### 4.2 配置验证

```bash
# 云端：检查 CloudStream 配置
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 5 "cloudStream:"

# 预期输出：
#   cloudStream:
#     enable: true
#     streamPort: 10003
#     tunnelPort: 10004

# 边缘节点：检查 EdgeStream 配置
ssh edge-node "grep -A 10 'edgeStream:' /etc/kubeedge/config/edgecore.yaml"

# 预期输出：
#   edgeStream:
#     enable: true
#     server: YOUR_IP:10004
```

### 4.3 网络连通性测试

```bash
# 1. 从边缘节点测试 tunnelPort
ssh edge-node "telnet YOUR_EXTERNAL_IP 10004"
# 应该能连接

# 2. 检查 iptables 规则
iptables -t nat -L OUTPUT -n | grep 10003
# 应该看到 DNAT 规则
```

### 4.4 功能测试

```bash
# 1. 部署测试 Pod
kubectl run nginx --image=nginx --overrides='{"spec":{"nodeName":"edge-node-1"}}'

# 2. 等待 Pod 运行
kubectl wait --for=condition=ready pod/nginx --timeout=60s

# 3. 测试 kubectl logs
kubectl logs nginx
# 应该能看到 nginx 日志

# 4. 测试 kubectl exec
kubectl exec -it nginx -- ls /
# 应该能执行命令

# 5. 清理
kubectl delete pod nginx
```

---

## 五、故障排查

### 5.1 常见问题诊断

#### 问题 1：kubectl logs 超时

```bash
Error from server: Get "https://10.2.4.15:10250/...": dial tcp i/o timeout
```

**排查步骤**：

1. **检查 CloudStream 是否启用**：
   ```bash
   kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 3 "cloudStream:"
   # 确认 enable: true
   ```

2. **检查 dynamicController**：
   ```bash
   kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 2 "dynamicController:"
   # 确认 enable: true
   ```

3. **检查 iptables 规则**：
   ```bash
   CLOUDCORE_IP=$(kubectl get pod -n kubeedge -l kubeedge=cloudcore -o jsonpath='{.items[0].status.podIP}')
   iptables -t nat -L OUTPUT -n | grep "$CLOUDCORE_IP:10003"
   # 应该能看到 DNAT 规则
   ```

#### 问题 2：EdgeCore 无法连接 CloudCore

```bash
# EdgeCore 日志错误
journalctl -u edgecore | tail -20
# Error: dial tcp YOUR_IP:10004: connection refused
```

**排查步骤**：

1. **检查 EdgeStream 配置**：
   ```bash
   grep -A 5 "edgeStream:" /etc/kubeedge/config/edgecore.yaml
   # 确认 server 地址正确
   ```

2. **测试网络连通性**：
   ```bash
   telnet YOUR_EXTERNAL_IP 10004
   # 应该能连接
   ```

3. **检查防火墙**：
   ```bash
   # 云端开放端口
   firewall-cmd --list-ports
   # 应该包含 10004/tcp
   ```

#### 问题 3：证书错误

```bash
# EdgeCore 日志
x509: certificate signed by unknown authority
```

**解决方法**：

```bash
# 1. 重新下载证书
rm -rf /etc/kubeedge/ca /etc/kubeedge/certs

# 2. 重新 join
TOKEN=$(keadm gettoken --kube-config=/root/.kube/config)
keadm reset
keadm join --cloudcore-ipport="YOUR_IP:10000" --token="$TOKEN" --edgenode-name="edge-node-1"
```

### 5.2 诊断命令集合

```bash
# ========== 云端诊断 ==========

# 1. CloudCore 日志
kubectl logs -n kubeedge -l kubeedge=cloudcore --tail=100 | grep -i "stream\|tunnel\|error"

# 2. CloudCore 配置
kubectl get cm cloudcore -n kubeedge -o yaml

# 3. iptables 规则
iptables -t nat -L OUTPUT -n -v | grep -E "10003|10250"

# 4. CloudCore 端口监听
kubectl exec -n kubeedge -it $(kubectl get pod -n kubeedge -l kubeedge=cloudcore -o name) -- netstat -tlnp | grep -E "10003|10004"

# ========== 边缘节点诊断 ==========

# 1. EdgeCore 状态
systemctl status edgecore

# 2. EdgeCore 日志
journalctl -u edgecore -n 100 | grep -i "stream\|tunnel\|error"

# 3. EdgeCore 配置
cat /etc/kubeedge/config/edgecore.yaml | grep -A 10 "edgeStream:"

# 4. 网络连通性
telnet YOUR_EXTERNAL_IP 10004

# 5. 证书检查
ls -lh /etc/kubeedge/ca/ /etc/kubeedge/certs/
openssl x509 -in /etc/kubeedge/certs/server.crt -text -noout | grep -A 2 "Subject:"
```

---

## 六、官方参考资料

1. **KubeEdge 官方文档**：
   - [Debug Kubernetes Apps at Edge](https://kubeedge.io/zh/docs/advanced/debug/)
   - [CloudCore Configuration](https://kubeedge.io/zh/docs/setup/config/cloudcore/)
   - [EdgeCore Configuration](https://kubeedge.io/zh/docs/setup/config/edgecore/)

2. **官方设计文档**：
   - [Proposal: Support Kubectl Logs/Exec](https://github.com/kubeedge/kubeedge/blob/master/docs/proposals/sig-node/exec-logs.md)

3. **官方示例仓库**：
   - [kubeedge/examples](https://github.com/kubeedge/examples)

---

## 七、离线部署注意事项

### 7.1 证书管理

在离线环境中，**必须使用 keadm 生成证书**，不能手动创建：

```bash
# ✅ 正确：使用 keadm 初始化
keadm init --advertise-address="YOUR_IP" --kubeedge-version="v1.22.0"

# ❌ 错误：手动创建证书
openssl req -new -x509 ...  # 不推荐
```

### 7.2 镜像准备

离线部署需要提前准备的镜像：

```bash
# CloudCore 镜像
kubeedge/cloudcore:v1.22.0

# IptablesManager 镜像
kubeedge/iptables-manager:v1.22.0

# EdgeCore 二进制（不是镜像）
edgecore-v1.22.0-linux-amd64.tar.gz
```

### 7.3 网络规划

- **10000**: EdgeHub WebSocket 连接
- **10002**: 证书下载（HTTPS）
- **10003**: CloudStream API（HTTPS）
- **10004**: Tunnel WebSocket 隧道

确保这些端口在防火墙中开放。

---

## 八、总结

### 关键配置清单

| 配置项 | 位置 | 必需 | 默认值 |
|--------|------|------|--------|
| `cloudStream.enable` | CloudCore | ✅ | `false` |
| `cloudStream.streamPort` | CloudCore | ✅ | `10003` |
| `cloudStream.tunnelPort` | CloudCore | ✅ | `10004` |
| `dynamicController.enable` | CloudCore | ✅ | `false` |
| `edgeStream.enable` | EdgeCore | ✅ | `false` |
| `edgeStream.server` | EdgeCore | ✅ | - |
| iptables NAT 规则 | Cloud Node | ✅ | - |

### 部署顺序

1. ✅ 使用 `keadm init` 初始化 CloudCore（自动配置 cloudStream）
2. ✅ 修改 CloudCore ConfigMap 启用 `dynamicController`
3. ✅ 重启 CloudCore Pod
4. ✅ 使用 `keadm join` 加入边缘节点
5. ✅ 修改 EdgeCore 配置启用 `edgeStream`
6. ✅ 重启 EdgeCore 服务
7. ✅ 验证 kubectl logs/exec 功能

**本指南基于 KubeEdge v1.22.0 官方文档和最佳实践编写，适用于 K3S + KubeEdge + EdgeMesh 离线部署场景。**
