# KubeEdge 日志采集与资源监控功能 - 快速部署指南

## 功能概述

本功能为 KubeEdge 离线环境提供完整的日志采集和资源监控能力：

- ✅ **kubectl logs** - 从云端查看边缘 Pod 日志
- ✅ **kubectl exec** - 在边缘 Pod 中执行命令
- ✅ **kubectl top node** - 查看边缘节点资源使用情况
- ✅ **kubectl top pod** - 查看边缘 Pod 资源使用情况

## 技术架构

```
┌─────────────────────────────────────────────────────────────┐
│                       云端（Cloud）                          │
│                                                              │
│  ┌──────────────┐      ┌──────────────┐                    │
│  │ Metrics      │      │  CloudCore   │                    │
│  │ Server       │      │              │                    │
│  │              │      │ CloudStream  │                    │
│  │ Port: 10350  │────▶ │ Port: 10003  │                    │
│  └──────────────┘      └──────┬───────┘                    │
│         │                     │                             │
│         │ iptables NAT        │ TLS Tunnel                 │
│         └─────────────────────┘                             │
└────────────────────────────────┬────────────────────────────┘
                                 │
                          云边通信通道
                                 │
┌────────────────────────────────┴────────────────────────────┐
│                       边缘端（Edge）                         │
│                                                              │
│  ┌──────────────┐      ┌──────────────┐                    │
│  │  EdgeCore    │      │   Kubelet    │                    │
│  │              │      │              │                    │
│  │ EdgeStream   │────▶ │ Port: 10250  │                    │
│  │ Port: 10004  │      │              │                    │
│  └──────────────┘      └──────┬───────┘                    │
│                               │                             │
│                        ┌──────▼───────┐                    │
│                        │ 容器日志/指标 │                    │
│                        └──────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. CloudStream（云端）
- **端口**: 10003（数据）、10004（隧道）
- **状态**: 默认启用（Helm Chart 自动配置）
- **功能**: 提供 TLS 隧道，转发 kubectl logs/exec 请求到边缘

### 2. EdgeStream（边缘端）
- **端口**: 10004（连接到云端）
- **状态**: 需要配置启用（安装脚本自动配置）
- **功能**: 接收云端请求，转发到本地 kubelet

### 3. Metrics Server
- **端口**: 通过 iptables 转发 10350 → CloudCore:10003
- **镜像**: `registry.k8s.io/metrics-server/metrics-server:v0.4.1`
- **功能**: 收集边缘节点和 Pod 的资源指标

### 4. iptables NAT 规则
- **规则**: `iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to <CLOUDCORE_IP>:10003`
- **功能**: 将 Metrics Server 请求路由到 CloudStream 隧道

## 自动部署流程

### 云端部署（自动）

执行 `cloud/install/install.sh` 时，脚本会自动：

1. **加载 Metrics Server 镜像**
   ```bash
   # 自动从 images/ 目录加载
   registry.k8s.io/metrics-server/metrics-server:v0.4.1
   ```

2. **部署 Metrics Server**
   ```bash
   # 自动应用部署清单
   kubectl apply -f manifests/metrics-server.yaml
   ```

3. **配置 iptables 规则**
   ```bash
   # 自动执行配置脚本
   bash manifests/iptables-metrics-setup.sh <CLOUDCORE_IP>
   ```

### 边缘端部署（自动）

执行 `edge/install/install.sh` 时，脚本会自动：

1. **启用 EdgeStream**
   ```yaml
   # 自动修改 /etc/kubeedge/config/edgecore.yaml
   modules:
     edgeStream:
       enable: true
       handshakeTimeout: 30
       readDeadline: 15
       server: <CLOUD_IP>:10004
       writeDeadline: 15
   ```

2. **重启 EdgeCore 服务**
   ```bash
   systemctl restart edgecore
   ```

## 验证功能

### 自动验证脚本

```bash
cd /data/kubeedge-cloud-xxx
sudo bash manifests/verify-logs-metrics.sh
```

验证内容包括：
- ✓ CloudCore 状态
- ✓ CloudStream 配置
- ✓ 边缘节点状态
- ✓ kubectl logs 功能
- ✓ kubectl exec 功能
- ✓ Metrics Server 状态
- ✓ kubectl top 功能
- ✓ iptables 规则

### 手动验证命令

#### 1. 检查云端组件

```bash
# 检查 CloudCore
kubectl get pods -n kubeedge -l kubeedge=cloudcore

# 检查 CloudStream 配置
kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 5 "cloudStream:"

# 检查 Metrics Server
kubectl get pods -n kube-system -l k8s-app=metrics-server

# 检查 iptables 规则
sudo iptables -t nat -L OUTPUT -n | grep 10350
```

#### 2. 检查边缘节点

```bash
# 检查节点状态
kubectl get nodes -l node-role.kubernetes.io/edge=''

# SSH 到边缘节点，检查 EdgeStream 配置
ssh <edge-node> "grep -A 10 'edgeStream:' /etc/kubeedge/config/edgecore.yaml"

# 检查 EdgeCore 服务状态
ssh <edge-node> "systemctl status edgecore"
```

#### 3. 测试日志和监控功能

```bash
# 部署测试 Pod 到边缘节点
kubectl run test-nginx --image=nginx --overrides='{"spec":{"nodeSelector":{"node-role.kubernetes.io/edge":""}}}'

# 等待 Pod 运行
kubectl wait --for=condition=ready pod test-nginx --timeout=60s

# 测试 kubectl logs
kubectl logs test-nginx

# 测试 kubectl exec
kubectl exec test-nginx -- hostname

# 测试 kubectl top
kubectl top node
kubectl top pod

# 清理测试 Pod
kubectl delete pod test-nginx
```

## 故障排查

### kubectl logs/exec 不工作

**症状**: 执行 `kubectl logs <pod>` 或 `kubectl exec <pod>` 失败

**排查步骤**:

1. **检查 CloudStream 状态**
   ```bash
   kubectl get cm cloudcore -n kubeedge -o yaml | grep -A 5 "cloudStream:"
   # 应该看到 enable: true 和 streamPort: 10003
   ```

2. **检查 EdgeStream 配置**
   ```bash
   ssh <edge-node> "grep -A 10 'edgeStream:' /etc/kubeedge/config/edgecore.yaml"
   # 应该看到 enable: true 和 server: <cloud-ip>:10004
   ```

3. **检查端口连通性**
   ```bash
   # 从边缘节点测试
   ssh <edge-node> "telnet <cloud-ip> 10004"
   # 应该能连接
   ```

4. **查看 CloudCore 日志**
   ```bash
   kubectl logs -n kubeedge -l kubeedge=cloudcore --tail=100
   # 查找 "stream" 相关错误
   ```

5. **查看 EdgeCore 日志**
   ```bash
   ssh <edge-node> "journalctl -u edgecore -n 100"
   # 查找 "edgeStream" 或 "tunnel" 相关错误
   ```

**解决方法**:
```bash
# 重新配置 EdgeStream（边缘节点）
ssh <edge-node>
sudo sed -i '/edgeStream:/,/enable:/ s/enable: false/enable: true/' /etc/kubeedge/config/edgecore.yaml
sudo systemctl restart edgecore
```

### kubectl top 不工作

**症状**: 执行 `kubectl top node` 或 `kubectl top pod` 失败

**排查步骤**:

1. **检查 Metrics Server 状态**
   ```bash
   kubectl get pods -n kube-system -l k8s-app=metrics-server
   # 应该显示 Running
   ```

2. **检查 Metrics Server 日志**
   ```bash
   kubectl logs -n kube-system -l k8s-app=metrics-server --tail=50
   # 查找连接错误
   ```

3. **检查 iptables 规则**
   ```bash
   sudo iptables -t nat -L OUTPUT -n | grep 10350
   # 应该看到 DNAT 规则
   ```

4. **测试端口连通性**
   ```bash
   # CloudCore Stream 端口应该可访问
   telnet <cloud-ip> 10003
   ```

5. **检查 APIService**
   ```bash
   kubectl get apiservice v1beta1.metrics.k8s.io
   # 状态应该是 True
   ```

**解决方法**:
```bash
# 重新配置 iptables
cd /data/kubeedge-cloud-xxx
sudo bash manifests/iptables-metrics-setup.sh <CLOUD_IP>

# 重启 Metrics Server
kubectl rollout restart deployment metrics-server -n kube-system
kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s
```

### Metrics Server Pod 无法启动

**症状**: Metrics Server Pod 处于 CrashLoopBackOff 或 Error 状态

**排查步骤**:

1. **查看 Pod 详情**
   ```bash
   kubectl describe pod -n kube-system -l k8s-app=metrics-server
   ```

2. **查看 Pod 日志**
   ```bash
   kubectl logs -n kube-system -l k8s-app=metrics-server --previous
   ```

3. **检查镜像是否加载**
   ```bash
   # 在云端节点（k3s）
   sudo k3s crictl images | grep metrics-server
   ```

**解决方法**:
```bash
# 重新加载镜像
cd /data/kubeedge-cloud-xxx
sudo k3s ctr images import images/registry.k8s.io-metrics-server-metrics-server-v0.4.1.tar

# 重新部署
kubectl delete -f manifests/metrics-server.yaml
kubectl apply -f manifests/metrics-server.yaml
```

## 离线包构建

GitHub Actions 会自动将 Metrics Server 镜像打包到云端离线包：

```yaml
# .github/workflows/build-release-cloud.yml
METRICS_IMAGES=(
  "registry.k8s.io/metrics-server/metrics-server:v0.4.1"
)
```

离线包内容：
```
kubeedge-cloud-<version>-<arch>.tar.gz
├── images/
│   ├── registry.k8s.io-metrics-server-metrics-server-v0.4.1.tar  # 新增
│   └── ... (其他镜像)
├── manifests/
│   ├── metrics-server.yaml              # 新增
│   ├── iptables-metrics-setup.sh        # 新增
│   └── verify-logs-metrics.sh           # 新增
└── install/
    └── install.sh                       # 已增强
```

## 使用示例

### 场景 1: 查看边缘 Pod 日志

```bash
# 列出所有边缘 Pod
kubectl get pods -A -o wide | grep edge-node

# 查看 Pod 日志
kubectl logs <pod-name> -n <namespace>

# 实时跟踪日志
kubectl logs -f <pod-name> -n <namespace>

# 查看最近 100 行日志
kubectl logs --tail=100 <pod-name> -n <namespace>
```

### 场景 2: 在边缘 Pod 中执行命令

```bash
# 进入 Pod Shell
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# 执行单个命令
kubectl exec <pod-name> -n <namespace> -- hostname

# 查看 Pod 内文件
kubectl exec <pod-name> -n <namespace> -- ls -la /app
```

### 场景 3: 监控边缘资源使用

```bash
# 查看所有节点资源
kubectl top node

# 查看边缘节点资源（带标签过滤）
kubectl top node -l node-role.kubernetes.io/edge=''

# 查看所有 Pod 资源
kubectl top pod -A

# 查看特定命名空间的 Pod 资源
kubectl top pod -n <namespace>

# 按资源使用排序
kubectl top pod -A --sort-by=cpu
kubectl top pod -A --sort-by=memory
```

### 场景 4: 故障诊断

```bash
# 查看 Pod 事件
kubectl describe pod <pod-name> -n <namespace>

# 查看 Pod 日志（包括之前的容器）
kubectl logs <pod-name> -n <namespace> --previous

# 查看多容器 Pod 中某个容器的日志
kubectl logs <pod-name> -n <namespace> -c <container-name>

# 在 Pod 中执行网络诊断
kubectl exec <pod-name> -n <namespace> -- ping -c 4 google.com
kubectl exec <pod-name> -n <namespace> -- curl -I http://example.com
```

## 性能考虑

- **CloudStream 连接数**: 默认最大 10000 个并发连接
- **Metrics Server 收集间隔**: 30 秒（可调整 `--metric-resolution` 参数）
- **EdgeStream 超时**: 握手 30 秒，读写 15 秒
- **网络带宽**: kubectl logs 会占用云边带宽，建议使用 `--tail` 限制输出

## 安全考虑

- **TLS 加密**: CloudStream ↔ EdgeStream 使用 TLS 加密
- **证书管理**: 由 KubeEdge Helm Chart 自动生成和分发
- **权限控制**: Metrics Server 使用 Kubernetes RBAC，仅能访问授权资源
- **iptables 规则**: 仅在 OUTPUT 链添加，不影响 FORWARD 链安全

## 参考文档

- [KubeEdge 官方文档 - Debug Guide](https://github.com/kubeedge/website/blob/master/docs/advanced/debug.md)
- [KubeEdge 官方文档 - Metrics Server](https://github.com/kubeedge/website/blob/master/docs/advanced/metrics.md)
- [完整方案文档](../LOG_METRICS_OFFLINE_DEPLOYMENT.md)
