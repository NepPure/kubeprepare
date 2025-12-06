# KubeEdge 边缘端安装指南

本指南说明如何在离线环境下安装和配置 KubeEdge 边缘端。

## 目录

1. [系统要求](#系统要求)
2. [安装包内容](#安装包内容)
3. [安装步骤](#安装步骤)
4. [配置说明](#配置说明)
5. [验证安装](#验证安装)
6. [故障排除](#故障排除)
7. [管理与维护](#管理与维护)

## 系统要求

### 硬件要求

- **操作系统**: Linux (CentOS, Ubuntu, Debian, Rocky Linux, Raspberry Pi OS 等)
- **架构**: amd64 或 arm64
- **内存**: 最少 512MB (建议 1GB)
- **CPU**: 单核最少 (多核性能更佳)
- **磁盘**: 最少 10GB 可用空间
- **网络**: 需要网络连接到云端节点

### 软件要求

- `bash` 4.0+
- `systemctl` 服务管理工具
- 容器运行时：
  - Docker (预装) 或
  - containerd (包含在安装包中)

### 网络要求

- 边缘节点必须能够访问云端节点的：
  - 端口 10000 (TCP/WebSocket) 用于 CloudHub
  - 端口 10003 (TCP) 用于流媒体传输
- 可选: SSH 访问用于管理

### 所需凭据

- 云端节点 IP 地址和端口
- 边缘连接 token (从云端安装得到)

## 安装包内容

离线安装包包含以下文件：

```
kubeedge-edge-<版本>-<架构>.tar.gz
├── edgecore                       # KubeEdge EdgeCore 二进制文件
├── containerd-<arch>              # containerd 二进制文件
├── runc                           # runc 二进制文件
├── cni-plugins/                   # CNI 插件
├── install.sh                     # 安装脚本
└── config/
    └── kubeedge/
        └── edgecore-config.yaml   # 默认 EdgeCore 配置
```

## 安装步骤

### 第 1 步：解压安装包

```bash
# 解压安装包
tar -xzf kubeedge-edge-<版本>-<架构>.tar.gz

# 进入解压目录
cd kubeedge-edge-<版本>-<架构>
```

### 第 2 步：获取云端信息

需要以下信息来接入云端：

1. **云端 IP 地址**: 云端的对外 IP 或域名
2. **云端 token**: 从云端安装脚本获得
3. **边缘节点名称**: 为此边缘节点命名

### 第 3 步：执行安装

运行安装脚本连接到云端：

```bash
# 基础安装 (自动检测架构)
sudo ./install.sh <云端IP>:<云端端口> <token> <节点名称>

# 示例
sudo ./install.sh 192.168.1.100:10000 eyJhbGc... my-edge-node

# 如果云端端口是 10000，可简化为
sudo ./install.sh 192.168.1.100 eyJhbGc... my-edge-node
```

**脚本执行内容**:
1. 检查系统要求和架构
2. 安装 containerd 和 runc
3. 配置 CNI 插件
4. 安装 KubeEdge EdgeCore
5. 创建并启动 edgecore 服务
6. 建立与云端的连接

### 第 4 步：验证连接

安装完成后验证边缘节点是否成功连接：

```bash
# 检查 EdgeCore 服务状态
sudo systemctl status edgecore

# 查看连接日志
sudo journalctl -u edgecore -f
```

在云端节点上验证：

```bash
# 查看已连接的边缘节点
kubectl get nodes

# 应该看到边缘节点已加入集群
# NAME            STATUS   ROLES    AGE   VERSION
# my-edge-node    Ready    edge     10s   v1.22.0
```

## 配置说明

### EdgeCore 配置文件

EdgeCore 配置文件位置: `/etc/kubeedge/edgecore.yaml`

主要配置项：

```yaml
edgeHub:
  websocket:
    server: 192.168.1.100:10000   # 云端 WebSocket 服务器地址
    certfile: /var/lib/kubeedge/certs/server.crt  # 证书文件
    keyfile: /var/lib/kubeedge/certs/server.key   # 密钥文件
    handshakeTimeout: 30           # 握手超时时间 (秒)
    readDeadline: 15               # 读取超时 (秒)
    writeDeadline: 15              # 写入超时 (秒)

database:
  dataSource: /var/lib/kubeedge/edgecore.db  # 数据库文件位置

modules:
  edgeHub:
    enable: true
  edgeCore:
    enable: true
  metamanager:
    enable: true
  devicetwin:
    enable: true
```

### 修改配置

修改 EdgeCore 设置：

```bash
# 编辑配置文件
sudo nano /etc/kubeedge/edgecore.yaml

# 重启 EdgeCore 应用更改
sudo systemctl restart edgecore
```

### 网络配置

如果云端节点在防火墙后面：

```bash
# 确保可以访问云端
ping 192.168.1.100
nc -zv 192.168.1.100 10000
```

## 验证安装

### 检查服务状态

```bash
# 检查 EdgeCore 服务
sudo systemctl status edgecore

# 检查 containerd 服务
sudo systemctl status containerd

# 查看服务自启动状态
sudo systemctl is-enabled edgecore
sudo systemctl is-enabled containerd
```

### 查看日志

```bash
# EdgeCore 日志
sudo journalctl -u edgecore -f

# containerd 日志
sudo journalctl -u containerd -f

# 直接查看 EdgeCore 日志文件
sudo tail -f /var/log/kubeedge/edgecore.log
```

### 验证容器运行时

```bash
# 测试 containerd
sudo ctr version

# 列出容器
sudo ctr container list

# 查看镜像
sudo ctr image list
```

### 检查节点信息

在云端节点上验证边缘节点：

```bash
# 列出所有节点
kubectl get nodes

# 查看边缘节点详情
kubectl describe node my-edge-node

# 查看边缘节点上运行的 pod
kubectl get pods -A --field-selector spec.nodeName=my-edge-node
```

## 故障排除

### 连接失败

**问题**: 边缘节点无法连接到云端

**解决方案**:
1. 验证云端 IP 地址和端口正确
2. 测试网络连通性: `nc -zv <云端IP> 10000`
3. 检查防火墙规则: `sudo iptables -L`
4. 查看 EdgeCore 日志: `sudo journalctl -u edgecore -f`

```bash
# 测试连接
curl -v telnet://192.168.1.100:10000
```

### EdgeCore 服务无法启动

**问题**: edgecore 服务启动失败

**解决方案**:
```bash
# 检查服务状态
sudo systemctl status edgecore

# 查看启动错误
sudo journalctl -u edgecore -n 50

# 检查配置文件语法
sudo edgecore -v 4

# 重启服务
sudo systemctl restart edgecore
```

### Token 过期或无效

**问题**: 使用过期的 token 无法连接

**解决方案**:
1. 从云端重新获取有效的 token
2. 更新配置文件中的 token
3. 重启 EdgeCore 服务

```bash
# 编辑配置获取新 token
sudo nano /etc/kubeedge/edgecore.yaml

# 重启服务
sudo systemctl restart edgecore
```

### 容器无法启动

**问题**: 边缘节点上容器无法运行

**解决方案**:
```bash
# 检查 containerd 状态
sudo systemctl status containerd

# 查看 containerd 日志
sudo journalctl -u containerd -f

# 检查镜像
sudo ctr image list

# 测试拉取镜像
sudo ctr image pull docker.io/library/alpine:latest
```

### 内存或磁盘不足

**问题**: 边缘节点内存或磁盘空间不足

**解决方案**:
```bash
# 查看磁盘使用情况
df -h

# 查看内存使用情况
free -h

# 清理无用的容器和镜像
sudo ctr container rm -force <container-id>
sudo ctr image rm <image-ref>

# 清理数据库
sudo rm /var/lib/kubeedge/edgecore.db
sudo systemctl restart edgecore
```

## 管理与维护

### 查看运行状态

```bash
# 检查连接状态
sudo systemctl status edgecore

# 查看 pod 状态
kubectl get pods -A --field-selector spec.nodeName=my-edge-node

# 查看节点资源使用
kubectl top node my-edge-node
```

### 更新配置

```bash
# 编辑配置
sudo nano /etc/kubeedge/edgecore.yaml

# 验证配置
sudo edgecore --config=/etc/kubeedge/edgecore.yaml --check-config

# 应用更改
sudo systemctl restart edgecore
```

### 备份与恢复

```bash
# 备份配置和数据
sudo tar -czf kubeedge-edge-backup-$(date +%Y%m%d).tar.gz \
  /etc/kubeedge \
  /var/lib/kubeedge

# 恢复备份
sudo tar -xzf kubeedge-edge-backup-*.tar.gz -C /
```

### 卸载和清理

```bash
# 停止服务
sudo systemctl stop edgecore
sudo systemctl stop containerd

# 清理数据和配置
sudo rm -rf /etc/kubeedge
sudo rm -rf /var/lib/kubeedge
sudo rm -rf /var/lib/containerd

# 删除二进制文件
sudo rm -f /usr/local/bin/edgecore
sudo rm -f /usr/local/bin/containerd*
sudo rm -f /usr/local/bin/ctr
sudo rm -f /usr/local/bin/runc
```

## 相关资源

- **KubeEdge 官方文档**: https://kubeedge.io/docs/
- **GitHub Issues**: https://github.com/kubeedge/kubeedge/issues
- **EdgeCore 日志**: `/var/log/kubeedge/edgecore.log`

## 快速参考

| 任务 | 命令 |
|------|------|
| 检查连接 | `sudo systemctl status edgecore` |
| 查看日志 | `sudo journalctl -u edgecore -f` |
| 重启服务 | `sudo systemctl restart edgecore` |
| 获取节点名称 | `hostname` |
| 查看 pod 状态 | `kubectl get pods --field-selector spec.nodeName=<node-name>` |
| 查看节点详情 | `kubectl describe node <node-name>` |
