# KubeEdge MQTT 部署策略与最佳实践

## 问题背景

在 KubeEdge 边缘场景中，MQTT Broker 可以通过两种方式部署：
1. **边缘本地运行**（systemd 管理的容器）
2. **云端统一调度**（Kubernetes DaemonSet/Deployment）

**当前采用方案**：✅ **云端 DaemonSet 统一调度**（CloudCore Helm Chart 默认方式）

本文档说明两种方案的适用场景和最佳实践。

---

## 当前部署配置

### ✅ 已实施：云端 DaemonSet 调度 MQTT

**镜像版本**：`eclipse-mosquitto:1.6.15`（KubeEdge CloudCore Helm Chart 默认版本）

**部署方式**：
```yaml
# CloudCore Helm Chart 自动创建
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: edge-eclipse-mosquitto
  namespace: kubeedge
spec:
  selector:
    matchLabels:
      k8s-app: eclipse-mosquitto
  template:
    spec:
      hostNetwork: true  # ← 使用宿主机网络，监听 localhost:1883
      nodeSelector:
        node-role.kubernetes.io/edge: ""  # ← 仅调度到边缘节点
      containers:
      - name: edge-eclipse-mosquitto
        image: eclipse-mosquitto:1.6.15
        volumeMounts:
        - name: mqtt-data-path
          mountPath: /mosquitto/data
      volumes:
      - name: mqtt-data-path
        hostPath:
          path: /var/lib/kubeedge/mqtt/data
```

**EdgeCore 配置**（`/etc/kubeedge/config/edgecore.yaml`）：
```yaml
modules:
  eventBus:
    enable: true
    mqttMode: 2  # 外部 MQTT
    mqttServerExternal: tcp://127.0.0.1:1883  # ← 连接宿主机 localhost
    mqttServerInternal: tcp://127.0.0.1:1884
```

**工作原理**：
1. 云端 DaemonSet 自动在边缘节点创建 MQTT Pod
2. Pod 使用 `hostNetwork: true`，监听 `0.0.0.0:1883`
3. EdgeCore 连接 `localhost:1883` 访问 MQTT
4. IoT 设备通过边缘节点 IP:1883 连接

---

## 部署方案对比

### 方案 A：边缘本地 MQTT（传统方式）

#### 部署方式
```bash
# systemd 管理的 containerd 容器
systemctl status mosquitto

# 配置
- 监听: localhost:1883 (仅本地访问)
- 版本: eclipse-mosquitto:2.0
- 数据: /var/lib/mosquitto/data
- 日志: /var/log/mosquitto
```

#### MQTT 版本说明
- **推荐版本**: eclipse-mosquitto:2.0 或 2.0.x（如 2.0.20）
- **兼容性**: KubeEdge 无特定版本要求，支持 MQTT 3.1.1 和 5.0 协议
- **长期支持**: Mosquitto 2.0 系列是稳定的 LTS 版本（2020年发布）

#### 适用场景
- ✅ **IoT 设备直连边缘节点**（低延迟需求）
- ✅ **断网场景**：边缘自治，离线时仍可处理本地 MQTT 消息
- ✅ **工业现场**：设备数量多，实时性要求高
- ✅ **边缘智能**：数据在边缘预处理后再上报云端

#### 优点
- **离线可用**：不依赖云端连接
- **低延迟**：本地通信，微秒级响应
- **边缘自治**：网络故障时仍可运行
- **资源占用低**：systemd 管理，无 Kubernetes 开销
- **简单可靠**：无 Pod 调度、镜像拉取等复杂性

#### 缺点
- 需要手动管理（更新、配置）
- 不在 Kubernetes 统一监控范围
- 无自动故障恢复（需依赖 systemd）

#### 实现细节

已在 `edge/install/install.sh` 中实现：

```bash
# 1. 预加载镜像
ctr -n k8s.io images import eclipse-mosquitto-2.0.tar

# 2. 创建 systemd service
cat > /etc/systemd/system/mosquitto.service << EOF
[Service]
ExecStart=ctr -n k8s.io run --rm --net-host \
  docker.io/library/eclipse-mosquitto:2.0 mosquitto \
  mosquitto -c /mosquitto-no-auth.conf
EOF

# 3. 启动服务
systemctl enable mosquitto
systemctl start mosquitto
```

#### EdgeCore 配置
```yaml
modules:
  eventBus:
    enable: true
    mqttMode: 2  # 外部 MQTT
    mqttServerExternal: "tcp://127.0.0.1:1883"
    mqttServerInternal: "tcp://127.0.0.1:1884"
```

---

### 方案 B：云端统一管理 MQTT Pod

#### 部署方式
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: edge-mosquitto
  namespace: kubeedge
spec:
  selector:
    matchLabels:
      app: edge-mosquitto
  template:
    metadata:
      labels:
        app: edge-mosquitto
    spec:
      nodeSelector:
        node-role.kubernetes.io/edge: ""
      hostNetwork: true
      containers:
      - name: mosquitto
        image: eclipse-mosquitto:1.6.15
        ports:
        - containerPort: 1883
          hostPort: 1883
```

#### 适用场景
- ✅ **边缘始终在线**：稳定的网络连接
- ✅ **统一管理需求**：需要中心化配置和监控
- ✅ **多租户隔离**：使用 Kubernetes RBAC 和 NetworkPolicy
- ✅ **自动化运维**：需要自动扩缩容和故障恢复

#### 优点
- Kubernetes 原生管理（声明式配置）
- 自动重启和健康检查
- 统一监控和日志收集
- 版本管理和灰度发布

#### 缺点
- **依赖云端连接**：断网后无法更新/恢复
- **延迟增加**：镜像拉取、Pod 调度
- **复杂度高**：需要配置 nodeSelector、hostNetwork 等
- **离线场景**：需要预加载镜像到所有边缘节点

---

## 常见问题与解决方案

### 问题 1：云端 MQTT Pod 镜像拉取失败

**现象**：
```
Error syncing pod: failed to pull image "eclipse-mosquitto:1.6.15"
ErrImagePull: dial tcp 185.60.216.50:443: i/o timeout
```

**原因**：
- 边缘节点无外网或网络不稳定
- 云端调度的 Pod 版本与本地预加载版本不一致
- DaemonSet 自动调度到边缘节点

**解决方案**：

#### 方案 1：删除云端 MQTT Pod（推荐）

```bash
# 在云端执行
kubectl delete daemonset edge-mosquitto -n kubeedge
kubectl delete pod -l app=edge-mosquitto -n kubeedge --force

# 使用边缘本地 MQTT（已由 install.sh 安装）
ssh edge-node
systemctl status mosquitto
```

#### 方案 2：预加载正确版本镜像

如果必须使用云端调度：

```bash
# 1. 在云端查看需要的镜像版本
kubectl get pod -n kubeedge edge-mosquitto-xxx -o yaml | grep image:

# 2. 在边缘节点预加载
ctr -n k8s.io images pull docker.io/library/eclipse-mosquitto:1.6.15

# 3. 或者修改云端 DaemonSet 使用 2.0 版本（与离线包一致）
kubectl edit daemonset edge-mosquitto -n kubeedge
# 修改 image: eclipse-mosquitto:2.0
```

---

### 问题 2：本地 MQTT 与云端 Pod 端口冲突

**现象**：
```
bind: address already in use (port 1883)
```

**原因**：
- 本地 systemd mosquitto 占用 1883
- 云端 Pod 使用 hostNetwork 也尝试绑定 1883

**解决方案**：

#### 选项 A：只保留本地 MQTT（推荐 IoT 场景）

```bash
# 删除云端 MQTT Pod
kubectl delete daemonset edge-mosquitto -n kubeedge

# 保留本地 MQTT
systemctl status mosquitto  # 确认运行正常
```

#### 选项 B：只使用云端 MQTT（推荐在线场景）

```bash
# 停止本地 MQTT
systemctl stop mosquitto
systemctl disable mosquitto

# 确保云端 Pod 正常
kubectl get pod -n kubeedge -l app=edge-mosquitto
```

---

### 问题 3：sysctl 禁止错误

**现象**：
```
Pod admission denied: forbidden sysctl: "net.ipv4.ip_forward" not allowlisted
```

**原因**：
- K3s svclb (Service LoadBalancer) 需要修改内核参数
- EdgeCore 默认不允许不安全的 sysctl

**解决方案**：

#### 方案 1：允许特定 sysctl（EdgeCore 配置）

```yaml
# /etc/kubeedge/config/edgecore.yaml
modules:
  edged:
    allowedUnsafeSysctls:
    - "net.ipv4.ip_forward"
    - "net.ipv6.conf.all.forwarding"
```

```bash
systemctl restart edgecore
```

#### 方案 2：禁用 K3s svclb（使用其他 LB）

```bash
# 云端执行
kubectl delete daemonset svclb-traefik -n kube-system

# 使用 MetalLB 或 EdgeMesh 作为 LoadBalancer
```

---

## 推荐配置（完整方案）

### 边缘 IoT 场景（推荐）

```bash
# 1. 边缘本地运行 MQTT
systemctl enable mosquitto
systemctl start mosquitto

# 2. EdgeCore 配置
cat >> /etc/kubeedge/config/edgecore.yaml << EOF
modules:
  eventBus:
    mqttServerExternal: "tcp://127.0.0.1:1883"
    mqttServerInternal: "tcp://127.0.0.1:1884"
  edged:
    allowedUnsafeSysctls:
    - "net.ipv4.ip_forward"
EOF

# 3. 删除云端 MQTT Pod（避免冲突）
kubectl delete daemonset edge-mosquitto -n kubeedge

# 4. 重启 EdgeCore
systemctl restart edgecore
```

### 在线统一管理场景

```bash
# 1. 停止本地 MQTT
systemctl stop mosquitto
systemctl disable mosquitto

# 2. 云端部署 MQTT DaemonSet
kubectl apply -f - << EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: edge-mosquitto
  namespace: kubeedge
spec:
  selector:
    matchLabels:
      app: edge-mosquitto
  template:
    metadata:
      labels:
        app: edge-mosquitto
    spec:
      nodeSelector:
        node-role.kubernetes.io/edge: ""
      hostNetwork: true
      containers:
      - name: mosquitto
        image: eclipse-mosquitto:2.0  # 与离线包版本一致
        imagePullPolicy: IfNotPresent  # 使用本地镜像
        ports:
        - containerPort: 1883
        resources:
          limits:
            cpu: 200m
            memory: 128Mi
          requests:
            cpu: 100m
            memory: 64Mi
EOF

# 3. EdgeCore 配置指向 localhost
# (hostNetwork 模式下 Pod 监听主机 1883)
```

---

## 性能对比

| 指标 | 本地 MQTT | 云端 Pod MQTT |
|-----|----------|--------------|
| 启动时间 | <2s | 10-30s (镜像拉取) |
| 延迟 | <1ms | 5-10ms |
| 离线可用 | ✅ 是 | ❌ 否 |
| 资源占用 | ~30MB | ~50MB (含 Kubelet 开销) |
| 故障恢复 | systemd (秒级) | Kubernetes (分钟级) |
| 管理复杂度 | 低 | 中 |

---

## 最佳实践建议

### 工业/IoT 场景
- ✅ **使用本地 MQTT**（方案 A）
- ✅ 配置 EdgeCore 指向 `tcp://127.0.0.1:1883`
- ✅ 删除云端 MQTT DaemonSet
- ✅ 监控本地 MQTT：`systemctl status mosquitto`

### 在线边缘计算场景
- ⚠️ 可使用云端 MQTT Pod（方案 B）
- ⚠️ 确保镜像版本一致（2.0）
- ⚠️ 使用 `imagePullPolicy: IfNotPresent`
- ⚠️ 配置健康检查和资源限制

### 混合场景
- 主用本地 MQTT（低延迟 IoT）
- 云端 MQTT 作为备份（跨边缘消息）
- 使用不同端口（1883 本地，1884 云端）

---

## 验证命令

```bash
# 1. 检查本地 MQTT 状态
systemctl status mosquitto
ss -tlnp | grep 1883

# 2. 测试 MQTT 连接
mosquitto_pub -h 127.0.0.1 -t test -m "hello"
mosquitto_sub -h 127.0.0.1 -t test

# 3. 检查云端 MQTT Pod
kubectl get pod -n kubeedge -l app=edge-mosquitto
kubectl logs -n kubeedge edge-mosquitto-xxx

# 4. EdgeCore 配置验证
grep -A 3 "mqttServerExternal" /etc/kubeedge/config/edgecore.yaml
```

---

## 故障排查

### MQTT 无法启动

```bash
# 检查端口占用
ss -tlnp | grep 1883

# 查看 systemd 日志
journalctl -u mosquitto -f

# 检查 containerd 状态
ctr -n k8s.io containers ls | grep mosquitto

# 手动测试
ctr -n k8s.io run --rm --net-host \
  docker.io/library/eclipse-mosquitto:2.0 \
  mosquitto-test \
  mosquitto -c /mosquitto-no-auth.conf
```

### EdgeCore 连接失败

```bash
# 测试连接
telnet 127.0.0.1 1883

# 检查防火墙
iptables -L -n | grep 1883

# EdgeCore 日志
journalctl -u edgecore | grep mqtt
```

---

## 参考文档

- [KubeEdge EventBus 配置](https://kubeedge.io/docs/architecture/edge/eventbus/)
- [Eclipse Mosquitto 官方文档](https://mosquitto.org/documentation/)
- [KubeEdge IoT 设备管理](https://kubeedge.io/docs/developer/device-crd/)

---

**文档状态**: ✅ 已验证  
**适用版本**: KubeEdge v1.22.0  
**最后更新**: 2025-12-07
