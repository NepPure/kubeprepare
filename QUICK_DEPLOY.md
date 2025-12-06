# 快速部署指南

## 云端部署

### 方式 1：直接下载脚本并执行（推荐）

在远程云端服务器上执行：

```bash
# 下载部署脚本
curl -fsSL -o cloud-deploy.sh https://raw.githubusercontent.com/NepPure/kubeprepare/main/cloud-deploy.sh

# 执行部署（如果需要指定 IP 和端口）
bash cloud-deploy.sh 152.136.201.36 10000
```

或者使用本地上传的脚本：

```bash
# 从本地上传脚本
scp cloud-deploy.sh ubuntu@152.136.201.36:~/

# SSH 连接后执行
ssh ubuntu@152.136.201.36
bash ~/cloud-deploy.sh 152.136.201.36 10000
```

### 方式 2：手动上传安装包

```bash
# 本地上传安装包（使用密码认证）
scp cloud/release/kubeedge-cloud-*.tar.gz ubuntu@152.136.201.36:/tmp/

# SSH 连接后
ssh ubuntu@152.136.201.36
cd /tmp
tar -xzf kubeedge-cloud-*.tar.gz
sudo bash install.sh --cloud-ip 152.136.201.36 --port 10000
```

## 边缘端部署

### 前置条件

1. 云端已部署完成
2. 从云端获取边缘节点接入 token

在云端执行：
```bash
sudo keadm gettoken --kubeconfig=/etc/kubernetes/admin.conf
# 输出示例: a04d6a4025a99652db2c4ffbbd4a4e19.eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### 边缘节点部署

```bash
# 下载部署脚本
curl -fsSL -o edge-deploy.sh https://raw.githubusercontent.com/NepPure/kubeprepare/main/edge-deploy.sh

# 执行部署
bash edge-deploy.sh \
  wss://152.136.201.36:10000 \
  <your-token-here> \
  edge-node-1
```

或者：

```bash
# 本地上传脚本和包
scp edge/release/kubeedge-edge-*.tar.gz ubuntu@edge-server:/tmp/
scp edge-deploy.sh ubuntu@edge-server:~/

# SSH 连接后
ssh ubuntu@edge-server
bash ~/edge-deploy.sh wss://152.136.201.36:10000 <token> edge-node-1
```

## 验证部署

### 云端

```bash
# 查看 k3s 集群
sudo /usr/local/bin/k3s kubectl get nodes

# 查看 KubeEdge CloudCore
sudo systemctl status kubeedge-cloudcore
sudo journalctl -u kubeedge-cloudcore -f
```

### 边缘端

```bash
# 查看 EdgeCore 状态
sudo systemctl status edgecore

# 查看日志
sudo journalctl -u edgecore -f

# 查看本地容器
sudo ctr -n k8s.io containers list
```

## 常见问题

### Q: 如何卸载？

```bash
# 云端
sudo systemctl stop kubeedge-cloudcore k3s
sudo rm -rf /etc/kubeedge /var/lib/kubeedge

# 边缘端
sudo systemctl stop edgecore
sudo rm -rf /etc/kubeedge /var/lib/kubeedge
```

### Q: 如何重新获取 token？

在云端执行：
```bash
sudo keadm gettoken --kubeconfig=/etc/kubernetes/admin.conf
```

### Q: 部署失败如何调试？

```bash
# 查看详细日志
sudo journalctl -u kubeedge-cloudcore -n 100
sudo journalctl -u edgecore -n 100

# 查看配置文件
sudo cat /etc/kubeedge/config/cloudcore.yaml
sudo cat /etc/kubeedge/config/edgecore.yaml
```

## 脚本参数说明

### cloud-deploy.sh

```bash
bash cloud-deploy.sh [cloud-ip] [port] [package-url]

参数：
  cloud-ip    : CloudHub 监听 IP (默认: 本机 IP)
  port        : CloudHub 监听端口 (默认: 10000)
  package-url : 安装包下载地址 (默认: GitHub releases)

示例：
  bash cloud-deploy.sh 10.0.0.1 10000
  bash cloud-deploy.sh 152.136.201.36 10000
```

### edge-deploy.sh

```bash
bash edge-deploy.sh <cloud-url> <token> [node-name] [package-url]

参数：
  cloud-url   : 云端 WebSocket 地址 (必需)
  token       : 边缘节点接入 token (必需)
  node-name   : 边缘节点名称 (默认: edge-node)
  package-url : 安装包下载地址 (默认: GitHub releases)

示例：
  bash edge-deploy.sh wss://10.0.0.1:10000 abc123xyz edge-node-1
  bash edge-deploy.sh wss://152.136.201.36:10000 <token> my-edge-device
```
