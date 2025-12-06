# KubeEdge 物联网设备管理 - MQTT 完整集成方案

## 📋 方案概述

本项目针对物联网设备接入场景,完整集成了 Mosquitto MQTT Broker,实现开箱即用的设备管理能力。

## 🎯 架构设计

### Cloud 端
- **不需要 MQTT**: CloudCore 通过 CloudHub 与边缘通信
- **提供管理**: 可选的 DaemonSet 用于统一管理边缘 MQTT (可选)
- **离线包内容**: 包含 MQTT 镜像用于部署到边缘节点

### Edge 端
- **自动部署 MQTT**: 容器方式运行,systemd 管理
- **本地访问**: localhost:1883 (仅 EdgeCore 访问)
- **非 Pod 模式**: 不在 `kubectl get pods` 中显示
- **开机自启**: systemd 服务,稳定可靠

## 🔄 自动化流程

### 1. CI 构建阶段

```yaml
# .github/workflows/build-release.yml
Edge 构建步骤:
├── 下载 eclipse-mosquitto:2.0 镜像
├── 保存为 images/eclipse-mosquitto-2.0.tar (~10MB)
├── 包含 systemd/mosquitto.service
└── 打包到 edge 离线安装包
```

### 2. Edge 安装阶段

```bash
# edge/install/install.sh 自动执行:
[4.5/6] 部署 Mosquitto MQTT Broker
  ├── 导入镜像: ctr -n k8s.io images import eclipse-mosquitto-2.0.tar
  ├── 安装服务: cp mosquitto.service /etc/systemd/system/
  ├── 启动服务: systemctl enable --now mosquitto
  └── 验证运行: localhost:1883
```

### 3. EdgeCore 启动

```yaml
# edgecore.yaml 预配置:
modules:
  eventBus:
    enable: true
    mqttMode: 2  # 外部 MQTT
    mqttServerExternal: tcp://127.0.0.1:1883
    mqttServerInternal: tcp://127.0.0.1:1884
  deviceTwin:
    enable: true  # 设备孪生
```

## 📦 离线包内容

### Cloud 离线包
```
cloud/
├── images/
│   ├── kubeedge-cloudcore-v1.22.0.tar
│   ├── ...
│   └── eclipse-mosquitto-2.0.tar  # 用于部署到 edge
└── manifests/
    └── mosquitto-daemonset.yaml   # 可选的统一管理方案
```

### Edge 离线包  
```
edge/
├── images/
│   └── eclipse-mosquitto-2.0.tar  # ✅ 核心组件
├── systemd/
│   ├── edgecore.service
│   └── mosquitto.service          # ✅ MQTT 服务管理
└── config/kubeedge/
    └── edgecore-config.yaml       # ✅ 已配置 EventBus
```

## 🚀 部署方式对比

| 特性 | DaemonSet (可选) | 容器+Systemd (默认) ✅ |
|------|------------------|------------------------|
| 管理方式 | kubectl | systemd |
| 可见性 | `kubectl get pods` | `systemctl status` |
| 启动顺序 | 依赖 EdgeCore | 先于 EdgeCore |
| 网络访问 | Pod 网络 | Host 网络 (localhost) |
| 适用场景 | 统一管理 | 基础设施组件 |
| 本项目选择 | - | ✅ **推荐** |

## 📝 运维管理

### 查看 MQTT 状态

```bash
# 服务状态
systemctl status mosquitto

# 服务日志
journalctl -u mosquitto -f

# 容器状态
ctr -n k8s.io containers ls | grep mosquitto

# 端口监听
netstat -tuln | grep 1883
```

### 测试 MQTT 连接

```bash
# 订阅测试
mosquitto_sub -h localhost -p 1883 -t test/topic

# 发布测试 (另一个终端)
mosquitto_pub -h localhost -p 1883 -t test/topic -m "Hello IoT"
```

### 重启服务

```bash
# 重启 MQTT
systemctl restart mosquitto

# 重启 EdgeCore (会自动重连 MQTT)
systemctl restart edgecore
```

## 🔍 故障排查

### MQTT 未启动

```bash
# 检查镜像是否导入
ctr -n k8s.io images ls | grep mosquitto

# 检查服务配置
systemctl cat mosquitto

# 查看详细日志
journalctl -u mosquitto -n 100 --no-pager
```

### EdgeCore 连接失败

```bash
# 检查 MQTT 是否监听
ss -tuln | grep 1883

# 检查 EdgeCore 配置
grep -A 10 eventBus /etc/kubeedge/edgecore.yaml

# 查看 EdgeCore 日志
journalctl -u edgecore | grep -i mqtt
```

## 📊 性能指标

| 指标 | 数值 |
|------|------|
| MQTT 镜像大小 | ~10MB |
| 运行时内存占用 | ~20MB |
| 启动时间 | <2秒 |
| CPU 使用率 | <1% (空闲) |
| 端口占用 | 1883 (localhost) |

## ✅ 验证清单

安装完成后,确认以下内容:

- [ ] `systemctl is-active mosquitto` 返回 `active`
- [ ] `netstat -tuln | grep 1883` 显示监听
- [ ] `systemctl is-active edgecore` 返回 `active`
- [ ] EdgeCore 日志无 MQTT 连接错误
- [ ] 可以使用 mosquitto_pub/sub 测试通信

## 🎓 最佳实践

### ✅ 推荐做法

1. **使用容器化 MQTT**: 隔离性好,易于管理
2. **systemd 管理**: 确保开机自启和故障恢复
3. **本地访问**: 仅 localhost,提高安全性
4. **离线部署**: 镜像打包在安装包中
5. **先启动 MQTT**: edgecore.service 依赖 mosquitto

### ❌ 避免做法

1. **不要**将 MQTT 部署为 Pod (EdgeCore 启动依赖)
2. **不要**暴露 MQTT 端口到外网
3. **不要**手动管理 MQTT 容器 (使用 systemd)
4. **不要**在 Cloud 端运行 MQTT (不需要)

## 🔗 相关文档

- [MQTT_REQUIREMENTS.md](./MQTT_REQUIREMENTS.md) - MQTT 需求分析
- [PREREQUISITES_VERIFICATION.md](./PREREQUISITES_VERIFICATION.md) - 前置依赖验证
- [edge/install/README.md](./edge/install/README.md) - Edge 安装指南
- [edge/systemd/mosquitto.service](./edge/systemd/mosquitto.service) - MQTT 服务配置

## 📞 支持

如遇问题,请提供:
- `systemctl status mosquitto` 输出
- `systemctl status edgecore` 输出  
- `journalctl -u mosquitto -n 100` 日志
- `journalctl -u edgecore | grep -i mqtt` 日志

---

**总结**: 本方案通过完全自动化的 MQTT 集成,实现了物联网设备的开箱即用接入能力,无需任何手动配置,符合边缘计算最佳实践。
