# MQTT 云端 DaemonSet 部署快速指南

## 📋 当前架构

```
云端 Kubernetes 集群 (152.136.201.36)
│
├─ CloudCore Helm Chart
│  └─ DaemonSet: edge-eclipse-mosquitto
│     └─ 调度策略: 仅边缘节点
│        └─ 镜像: eclipse-mosquitto:1.6.15
│
└─ 自动调度 ▼
            │
            ▼
边缘节点 (154.8.209.41)
│
├─ MQTT Pod (DaemonSet 创建)
│  ├─ 镜像: eclipse-mosquitto:1.6.15
│  ├─ 网络: hostNetwork: true
│  ├─ 监听: 0.0.0.0:1883
│  └─ 数据: /var/lib/kubeedge/mqtt/data
│
└─ EdgeCore
   └─ 配置: tcp://127.0.0.1:1883
      └─ IoT 设备连接 → 边缘节点IP:1883
```

---

## ✅ 当前部署状态检查

### 1. 检查云端 DaemonSet

```bash
# 登录云端
ssh root@152.136.201.36

# 查看 DaemonSet
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl get daemonset -n kubeedge edge-eclipse-mosquitto

# 预期输出：
# NAME                      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
# edge-eclipse-mosquitto    1         1         1       1            1
```

### 2. 检查边缘 MQTT Pod

```bash
# 查看 MQTT Pod
k3s kubectl get pods -n kubeedge -l k8s-app=eclipse-mosquitto -o wide

# 预期输出：
# NAME                           READY   STATUS    RESTARTS   NODE
# edge-eclipse-mosquitto-xxxxx   1/1     Running   0          edge-node-xxx

# 查看 Pod 详情
k3s kubectl describe pod -n kubeedge -l k8s-app=eclipse-mosquitto
```

### 3. 验证边缘节点 MQTT 服务

```bash
# 登录边缘节点
ssh root@154.8.209.41

# 检查端口监听
ss -tlnp | grep 1883

# 预期输出：
# LISTEN  0  100  0.0.0.0:1883  0.0.0.0:*  users:(("mosquitto",pid=xxx,fd=4))
# LISTEN  0  100     [::]:1883     [::]:*  users:(("mosquitto",pid=xxx,fd=5))

# 检查 MQTT 进程
ps aux | grep mosquitto
```

---

## 🔧 故障排查

### 问题 1: Pod 状态为 `ImagePullBackOff`

**原因**: 边缘节点未预加载 MQTT 镜像

**解决**:
```bash
# 方式 A: 边缘节点手动导入镜像
ssh root@154.8.209.41
cd /data/edge-install-package
ctr -n k8s.io images import eclipse-mosquitto-1.6.15.tar

# 方式 B: 临时允许拉取（在线环境）
# Pod 会自动重试拉取镜像

# 验证镜像
ctr -n k8s.io images ls | grep mosquitto
# 预期: docker.io/library/eclipse-mosquitto:1.6.15
```

### 问题 2: Pod 状态为 `CrashLoopBackOff`

**原因**: 数据目录权限或配置问题

**解决**:
```bash
# 查看 Pod 日志
k3s kubectl logs -n kubeedge -l k8s-app=eclipse-mosquitto

# 检查数据目录
ssh root@154.8.209.41
ls -ld /var/lib/kubeedge/mqtt/data
# 确保目录存在且有写权限

# 创建目录（如果不存在）
mkdir -p /var/lib/kubeedge/mqtt/data
chmod 755 /var/lib/kubeedge/mqtt/data
```

### 问题 3: EdgeCore 无法连接 MQTT

**检查 EdgeCore 配置**:
```bash
ssh root@154.8.209.41
grep -A 5 'mqttServerExternal' /etc/kubeedge/config/edgecore.yaml

# 预期配置：
#   mqttServerExternal: tcp://127.0.0.1:1883
#   mqttMode: 2  # 外部 MQTT
```

**重启 EdgeCore**:
```bash
systemctl restart edgecore
journalctl -u edgecore -f | grep -i mqtt
```

---

## 🎯 完整验证流程

### 步骤 1: 边缘节点预导入镜像

```bash
# 在边缘节点执行安装脚本时，会自动导入
sudo ./install.sh <云端地址> <token> <节点名称>

# 手动验证镜像
ctr -n k8s.io images ls | grep eclipse-mosquitto:1.6.15
```

### 步骤 2: 等待 DaemonSet 调度

```bash
# 云端查看 Pod 创建进度
k3s kubectl get pods -n kubeedge -l k8s-app=eclipse-mosquitto -w

# 等待状态变为 Running（可能需要 1-2 分钟）
```

### 步骤 3: 验证 MQTT 功能

```bash
# 边缘节点安装测试工具
ssh root@154.8.209.41
apt-get install -y mosquitto-clients

# 测试发布
mosquitto_pub -h localhost -p 1883 -t test/topic -m "Hello MQTT"

# 测试订阅（另一个终端）
mosquitto_sub -h localhost -p 1883 -t test/topic
# 预期: 收到 "Hello MQTT" 消息
```

---

## 📊 镜像准备清单

### 云端镜像（由 CloudCore Helm Chart 管理）

```bash
# 云端无需预加载 MQTT 镜像
# DaemonSet 定义中已包含镜像配置
```

### 边缘镜像（需要预加载）

```bash
# 方式 A: 包含在边缘离线安装包中
edge-install-package/
└── images/
    └── eclipse-mosquitto-1.6.15.tar  # ← 添加此文件

# 制作镜像 tar 包
docker pull eclipse-mosquitto:1.6.15
docker save eclipse-mosquitto:1.6.15 -o eclipse-mosquitto-1.6.15.tar

# 或使用 containerd
ctr -n k8s.io images pull docker.io/library/eclipse-mosquitto:1.6.15
ctr -n k8s.io images export eclipse-mosquitto-1.6.15.tar docker.io/library/eclipse-mosquitto:1.6.15
```

---

## 🔄 从本地 systemd 迁移到 DaemonSet

### 如果之前使用本地 systemd MQTT

```bash
# 1. 停止并禁用本地 MQTT
ssh root@154.8.209.41
systemctl stop mosquitto
systemctl disable mosquitto
rm /etc/systemd/system/mosquitto.service
systemctl daemon-reload

# 2. 备份数据（如果有重要数据）
mkdir -p /tmp/mqtt-backup
cp -r /var/lib/mosquitto/data /tmp/mqtt-backup/

# 3. 清理本地 MQTT 容器
ctr -n k8s.io task kill mosquitto || true
ctr -n k8s.io container delete mosquitto || true

# 4. 等待云端 DaemonSet 调度
# Pod 会自动创建并使用 /var/lib/kubeedge/mqtt/data

# 5. 验证 MQTT Pod 运行
ss -tlnp | grep 1883
```

---

## 📖 相关文档

- [IoT MQTT 部署策略](./IOT_MQTT_DEPLOYMENT_STRATEGY.md) - 部署方案对比
- [MQTT 版本决策](./MQTT_VERSION_DECISION.md) - 版本选择说明
- [EdgeCore 配置最佳实践](./EDGECORE_CONFIG_BEST_PRACTICES.md) - 完整配置指南

---

## ⚡ 快速命令参考

```bash
# 云端检查
ssh root@152.136.201.36 "k3s kubectl get pods -n kubeedge -l k8s-app=eclipse-mosquitto"

# 边缘检查
ssh root@154.8.209.41 "ss -tlnp | grep 1883"

# 查看 MQTT 日志
ssh root@152.136.201.36 "k3s kubectl logs -n kubeedge -l k8s-app=eclipse-mosquitto -f"

# 重启 MQTT Pod
ssh root@152.136.201.36 "k3s kubectl delete pod -n kubeedge -l k8s-app=eclipse-mosquitto"
# Pod 会自动重建

# EdgeCore 重启
ssh root@154.8.209.41 "systemctl restart edgecore"
```

---

**最后更新**: 2025-12-07  
**适用版本**: KubeEdge v1.22.0 + CloudCore Helm Chart
