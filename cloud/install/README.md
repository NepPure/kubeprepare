# KubeEdge 云端安装指南

本指南说明如何在离线环境下使用 k3s 安装和配置 KubeEdge 云端。

## 目录

1. [系统要求](#系统要求)
2. [安装包内容](#安装包内容)
3. [安装步骤](#安装步骤)
4. [配置说明](#配置说明)
5. [验证安装](#验证安装)
6. [故障排除](#故障排除)
7. [边缘节点接入](#边缘节点接入)

## 系统要求

### 硬件要求

- **操作系统**: Linux (CentOS, Ubuntu, Debian, Rocky Linux 等)
- **架构**: amd64 或 arm64
- **内存**: 最少 2GB (生产环境建议 4GB)
- **CPU**: 最少 2 核 (生产环境建议 4 核)
- **磁盘**: 最少 20GB 可用空间
- **网络**: 建议使用固定 IP 地址

### 软件要求

- `bash` 4.0+
- `systemctl` 服务管理工具
- `wget` 或 `curl` (用于在线构建阶段)
- `jq` (可选，用于 JSON 输出格式化)

### 端口要求

以下端口必须对外开放：

| 端口 | 协议 | 服务 | 方向 |
|------|------|------|------|
| 10000 | WebSocket | CloudHub | 入站 (边缘→云端) |
| 10001 | TCP | API Server | 入站 |
| 10002 | TCP | 指标 | 可选 |
| 10003 | TCP | 流媒体 | 入站 (边缘→云端) |
| 6443 | TCP | Kubernetes API | 入站 |

## 安装包内容

离线安装包包含以下文件：

```
kubeedge-cloud-<版本>-k3s-<k3s版本>-<架构>.tar.gz
├── k3s-<架构>                    # k3s 二进制文件
├── cloudcore                      # KubeEdge CloudCore 二进制文件
├── keadm                          # KubeEdge 管理工具
├── install.sh                     # 安装脚本
└── config/
    └── kubeedge/
        └── cloudcore-config.yaml  # 默认 CloudCore 配置
```

## 安装步骤

### 第 1 步：解压安装包

```bash
# 解压安装包
tar -xzf kubeedge-cloud-<版本>-k3s-<k3s版本>-<架构>.tar.gz

# 进入解压目录
cd kubeedge-cloud-<版本>-k3s-<k3s版本>-<架构>
```

### 第 2 步：确定对外 IP 地址

确定边缘节点用来连接云端的外网 IP 地址或域名：

```bash
# 列出网卡信息
ip addr

# 或查看主机名解析
hostname -I
```

**重要**: 这个 IP 地址必须能从边缘节点访问。如果在防火墙后面，需要配置端口转发。

### 第 3 步：执行安装

使用外网 IP 执行安装脚本：

```bash
# 基础安装
sudo ./install.sh <对外IP>

# 指定节点名称的安装
sudo ./install.sh <对外IP> <节点名称>

# 示例
sudo ./install.sh 192.168.1.100
sudo ./install.sh cloud.example.com k3s-master
```

**脚本执行内容**:
1. 检查系统要求
2. 安装 k3s Kubernetes 集群
3. 安装 KubeEdge CloudCore
4. 生成边缘节点连接 token
5. 创建 k3s 和 CloudCore 的 systemd 服务
6. 显示 token 和后续步骤

### 第 4 步：获取边缘节点 Token

安装脚本完成后会显示边缘节点 token。请妥善保存此 token，边缘节点安装时需要使用：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
边缘节点 TOKEN:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
  "cloudIP": "192.168.1.100",
  "cloudPort": 10000,
  "token": "eyJhbGc...",
  "generatedAt": "2024-12-06T10:30:45Z",
  "edgeConnectCommand": "sudo ./install.sh 192.168.1.100:10000 eyJhbGc..."
}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Token 文件位置: `/etc/kubeedge/tokens/edge-token.txt`

## 配置说明

### CloudCore 配置文件

CloudCore 配置文件位置: `/etc/kubeedge/edgecore.yaml`

主要配置项：

```yaml
cloudHub:
  listenAddr: 0.0.0.0
  port: 10000                    # 可根据需要修改 (同时更新防火墙规则)
  protocol: websocket            # WebSocket 协议
  nodeLimit: 1000                # 最大连接边缘节点数

cloudStream:
  enable: true
  streamPort: 10003              # 设备数据流端口

modules:
  cloudHub:
    enable: true
  edgeController:
    enable: true
  deviceController:
    enable: true
```

### 修改配置

修改 CloudCore 设置：

```bash
# 编辑配置文件
sudo nano /etc/kubeedge/edgecore.yaml

# 重启 CloudCore 应用更改
sudo systemctl restart edgecore
```

### 防火墙规则

如果使用 firewalld 或 ufw：

```bash
# firewalld
sudo firewall-cmd --permanent --add-port=10000/tcp
sudo firewall-cmd --permanent --add-port=10003/tcp
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --reload

# ufw
sudo ufw allow 10000/tcp
sudo ufw allow 10003/tcp
sudo ufw allow 6443/tcp
```

## 验证安装

### 检查服务状态

```bash
# 检查 k3s 服务
sudo systemctl status k3s

# 检查 CloudCore 服务
sudo systemctl status edgecore

# 或使用 kubectl
kubectl get nodes
```

### 查看日志

```bash
# k3s 日志
sudo journalctl -u k3s -f

# CloudCore 日志
sudo journalctl -u edgecore -f

# KubeEdge pod 日志
kubectl -n kubeedge logs -f deployment/cloudcore
```

### 验证 Kubernetes 集群

```bash
# 获取集群信息
kubectl cluster-info

# 列出节点
kubectl get nodes

# 列出命名空间
kubectl get namespaces

# 检查 KubeEdge 组件
kubectl -n kubeedge get pod
```

## 故障排除

### 安装失败

**问题**: 安装脚本执行失败

**解决方案**:
1. 确认使用了 `sudo` 运行
2. 验证 IP 地址是否正确且可访问
3. 检查系统资源: `free -h` 和 `df -h`
4. 查看日志文件: `/var/log/kubeedge-cloud-install.log`

### 边缘节点无法连接

**问题**: 边缘节点连接失败

**解决方案**:
1. 验证对外 IP 地址是否正确: `ip addr`
2. 从边缘节点测试连接: `nc -zv <云端IP> 10000`
3. 检查防火墙规则: `sudo firewall-cmd --list-all`

## 边缘节点接入

成功安装云端后，即可接入边缘节点。详见边缘节点安装指南。
