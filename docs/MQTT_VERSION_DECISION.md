# KubeEdge MQTT 版本选择与统一方案

## 版本决策摘要

**统一版本**: `eclipse-mosquitto:2.0` (或 2.0.x 如 2.0.20)

---

## KubeEdge 版本兼容性分析

### 官方文档查询结果

根据 KubeEdge 官方仓库代码和文档分析：

1. **无强制版本要求**
   - KubeEdge 使用标准 MQTT 协议（3.1.1 和 5.0）
   - 不依赖特定 Mosquitto 版本或特性
   - 官方测试中使用操作系统默认的 mosquitto 包

2. **历史版本参考**
   ```
   KubeEdge v1.11-v1.14: 修复了 CRI Runtime 下 MQTT 容器异常退出问题
   KubeEdge v1.16: 推荐使用 DaemonSet 管理 MQTT，弃用 --with-mqtt 标志
   KubeEdge v1.22: 升级 Kubernetes 依赖到 v1.31.12，MQTT 无变化
   ```

3. **官方安装脚本**
   - `keadm` 通过系统包管理器安装 mosquitto（版本由发行版决定）
   - Ubuntu: `apt-get install mosquitto`
   - CentOS: `yum install mosquitto`
   - 未指定具体版本号

4. **测试环境使用**
   - E2E 测试连接 `tcp://127.0.0.1:1884`（内部 MQTT）
   - 无特定镜像版本硬编码

---

## Mosquitto 版本历史

| 版本 | 发布日期 | 状态 | 主要特性 |
|------|----------|------|----------|
| 1.6.x | 2019年 | 旧版本 | MQTT 3.1.1 |
| 2.0.x | 2020年12月 | **LTS（长期支持）** | MQTT 5.0, 安全增强 |
| 2.1.x | 2024年9月 | 最新稳定版 | 性能优化 |

### eclipse-mosquitto:2.0 优势

1. **长期支持（LTS）**
   - 2020年发布，经过 4 年生产验证
   - 持续安全更新（最新 2.0.20）

2. **协议兼容**
   - 完整支持 MQTT 3.1.1（KubeEdge 主要使用）
   - 向后兼容 MQTT 5.0

3. **生态成熟**
   - Docker Hub 官方镜像：500M+ 下载量
   - 广泛的社区支持和文档

4. **轻量稳定**
   - 镜像大小：~10MB
   - 内存占用：< 10MB（空闲状态）

---

## 当前部署状态

### 边缘节点（Edge）

- **镜像版本**: `eclipse-mosquitto:2.0`
- **管理方式**: systemd service（通过 containerd ctr 运行）
- **配置位置**: `/etc/systemd/system/mosquitto.service`
- **监听地址**: `localhost:1883`（本地访问）
- **数据目录**: `/var/lib/mosquitto/data`
- **日志目录**: `/var/log/mosquitto`

```bash
# 查看状态
systemctl status mosquitto

# 验证运行
ss -tlnp | grep 1883
```

**EdgeCore 配置** (`/etc/kubeedge/config/edgecore.yaml`):
```yaml
modules:
  eventBus:
    enable: true
    mqttMode: 2  # 2=外部 MQTT
    mqttQOS: 0
    mqttRetain: false
    mqttServerExternal: tcp://127.0.0.1:1883
    mqttServerInternal: tcp://127.0.0.1:1884  # 内部不使用
```

### 云端（Cloud）

- **MQTT 部署**: ❌ **不部署**
- **说明**: 云端不需要运行 MQTT Broker
  - KubeEdge IoT 架构中，设备直连边缘节点的 MQTT
  - 边缘通过 EdgeHub 与云端 CloudCore 通信（WebSocket/QUIC）

**之前错误（已解决）**:
- ❌ 云端错误调度了 MQTT Pod (`eclipse-mosquitto:1.6.15`)
- ❌ 与边缘本地 MQTT 端口冲突（都监听 1883）
- ✅ 已通过文档说明正确部署方式

---

## 版本升级路径（可选）

### 保持 2.0 不变（推荐）

**理由**:
- ✅ 已稳定运行
- ✅ 满足 KubeEdge 需求
- ✅ 无兼容性问题
- ✅ 减少变更风险

### 升级到 2.0.20（可选）

如需最新安全更新：

```bash
# 1. 拉取新镜像
ctr -n k8s.io images pull docker.io/library/eclipse-mosquitto:2.0.20

# 2. 修改 systemd service
sed -i 's/eclipse-mosquitto:2.0/eclipse-mosquitto:2.0.20/g' \
  /etc/systemd/system/mosquitto.service

# 3. 重启服务
systemctl daemon-reload
systemctl restart mosquitto
```

### 升级到 2.1.x（不推荐）

**不推荐理由**:
- ⚠️ 新版本（2024年9月发布）
- ⚠️ 生产验证时间短
- ⚠️ 无显著功能增益
- ⚠️ 可能存在未知问题

---

## 部署脚本当前状态

### edge/install/install.sh

```bash
# Line 432-465: MQTT 镜像导入和 systemd service 创建
MQTT_IMAGE_TAR=$(find "$SCRIPT_DIR" -name "eclipse-mosquitto-2.0.tar" -type f 2>/dev/null | head -1)

# systemd service 使用固定版本
ExecStart=$CTR_BIN -n k8s.io run \
  --rm \
  --net-host \
  docker.io/library/eclipse-mosquitto:2.0 \
  mosquitto \
  mosquitto -c /mosquitto-no-auth.conf
```

**状态**: ✅ **已统一使用 2.0 版本，无需修改**

### cloud/install/install.sh

**状态**: ✅ **无 MQTT 部署代码（设计正确）**

---

## 验证命令

### 边缘节点验证

```bash
# 1. 检查 MQTT 服务状态
systemctl status mosquitto

# 2. 验证端口监听
ss -tlnp | grep 1883

# 3. 检查镜像版本
ctr -n k8s.io images ls | grep mosquitto

# 4. 查看 EdgeCore 配置
grep -A 10 "eventBus:" /etc/kubeedge/config/edgecore.yaml

# 5. 测试 MQTT 连接（需要 mosquitto-clients）
mosquitto_pub -h localhost -p 1883 -t test -m "hello"
mosquitto_sub -h localhost -p 1883 -t test
```

### 云端验证（确认无 MQTT Pod）

```bash
# 1. 检查 kubeedge 命名空间
kubectl get pods -n kubeedge | grep -i mosquitto
# 预期输出: 无结果（正常）

# 2. 检查 DaemonSet
kubectl get daemonset -n kubeedge | grep -i mosquitto
# 预期输出: 无结果（正常）

# 3. 检查所有命名空间
kubectl get pods --all-namespaces | grep -i mosquitto
# 预期输出: 无结果（正常）
```

---

## 常见问题

### Q1: 为什么选择 2.0 而不是最新的 2.1？

**A**: 
- **稳定性优先**: 2.0 已有 4 年生产验证
- **生态成熟**: 2.0 是 LTS 版本，社区支持更好
- **风险控制**: 新版本可能存在未知问题
- **功能充足**: 2.0 完全满足 KubeEdge 需求

### Q2: KubeEdge 对 MQTT 版本有要求吗？

**A**: 
- **无强制要求**: 只要支持 MQTT 3.1.1 协议即可
- **协议兼容**: Mosquitto 1.6/2.0/2.1 均支持
- **官方测试**: 使用系统默认 mosquitto（版本不固定）

### Q3: 云端需要部署 MQTT 吗？

**A**: 
- **❌ 不需要**: 云端不运行 MQTT Broker
- **架构说明**: 
  - IoT 设备 → MQTT (边缘本地) → EdgeCore
  - EdgeCore → WebSocket/QUIC → CloudCore (云端)
- **错误示例**: 云端调度 MQTT Pod 会导致端口冲突

### Q4: 如何升级 MQTT 版本？

**A**: 
```bash
# 1. 导入新镜像
ctr -n k8s.io images import eclipse-mosquitto-2.0.20.tar

# 2. 修改 systemd service
vi /etc/systemd/system/mosquitto.service
# 将 :2.0 改为 :2.0.20

# 3. 重启服务
systemctl daemon-reload
systemctl restart mosquitto

# 4. 验证版本
ctr -n k8s.io containers info mosquitto | grep Image
```

### Q5: 边缘本地 MQTT 和云端 DaemonSet 部署有什么区别？

**A**: 见 `docs/IOT_MQTT_DEPLOYMENT_STRATEGY.md` 详细对比

---

## 参考文档

1. **KubeEdge 官方**:
   - [Architecture - EventBus](https://kubeedge.io/en/docs/architecture/edge/eventbus)
   - [CHANGELOG-1.16](https://github.com/kubeedge/kubeedge/blob/main/CHANGELOG/CHANGELOG-1.16.md#important-steps-before-upgrading) - MQTT DaemonSet 说明

2. **Mosquitto 官方**:
   - [Version History](https://mosquitto.org/ChangeLog.txt)
   - [Docker Images](https://hub.docker.com/_/eclipse-mosquitto)

3. **本项目文档**:
   - [IoT MQTT 部署策略](./IOT_MQTT_DEPLOYMENT_STRATEGY.md)
   - [离线镜像修复指南](./OFFLINE_IMAGE_FIX.md)

---

## 结论

**✅ 推荐方案**: 保持当前 `eclipse-mosquitto:2.0` 不变

**理由**:
1. ✅ 满足 KubeEdge 所有需求（无版本限制）
2. ✅ 稳定可靠（4 年生产验证）
3. ✅ 边缘已部署并正常运行
4. ✅ 云端无需部署 MQTT
5. ✅ 减少变更风险

**可选升级**: 如有安全要求，可升级到 `2.0.20`（同一 LTS 系列）

**不建议**: 升级到 2.1.x（新版本，风险未知）

---

**最后更新**: 2025-01-07  
**文档版本**: 1.0  
**适用于**: KubeEdge v1.22.0 + K3s v1.29
