# Cloud端离线安装完整性测试检查列表

## 测试目标

验证 cloud 端安装包能够在**完全离线环境**下成功部署 KubeEdge CloudCore。

## 测试环境要求

### 硬件要求
- CPU: 2核以上
- 内存: 4GB以上
- 磁盘: 20GB以上可用空间
- 架构: amd64 或 arm64

### 软件要求
- 操作系统: Linux (Ubuntu 20.04+, CentOS 7+, Debian 10+等)
- 已安装: systemctl, iptables
- **未安装**: kubectl, docker (测试纯离线)

### 网络要求
- 测试机器必须能够**完全断网**
- 或使用防火墙规则阻断所有外网访问

## 测试步骤

### 阶段1: 构建验证

#### 1.1 构建离线包 (在有网络的环境)

```bash
cd /workspaces/kubeprepare
git pull origin main

# 触发 GitHub Actions 构建
git tag v1.0.0-test
git push origin v1.0.0-test

# 等待构建完成，下载 Release 资产
wget https://github.com/NepPure/kubeprepare/releases/download/v1.0.0-test/kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz
```

#### 1.2 验证离线包完整性

```bash
# 运行验证脚本
bash verify_cloud_images.sh kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz

# 预期输出:
# ✅ 验证通过！离线包完整，可用于完全离线安装。
# 包含内容:
#   - KubeEdge组件镜像: 4个
#   - K3s系统镜像: 8个
#   - 二进制文件和配置: 完整
```

**检查点 ✅**: 验证脚本输出"验证通过"

#### 1.3 手动检查镜像文件

```bash
# 列出所有镜像
tar -tzf kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz | grep "^images/.*\.tar$"

# 必须包含以下文件:
# images/docker.io-kubeedge-cloudcore-v1.22.0.tar
# images/docker.io-kubeedge-iptables-manager-v1.22.0.tar
# images/docker.io-kubeedge-controller-manager-v1.22.0.tar
# images/docker.io-kubeedge-admission-v1.22.0.tar
# images/docker.io-rancher-klipper-helm-v0.9.10-build20251111.tar
# images/docker.io-rancher-klipper-lb-v0.4.13.tar
# images/docker.io-rancher-local-path-provisioner-v0.0.32.tar
# images/docker.io-rancher-mirrored-coredns-coredns-1.13.1.tar
# images/docker.io-rancher-mirrored-library-busybox-1.36.1.tar
# images/docker.io-rancher-mirrored-library-traefik-3.5.1.tar
# images/docker.io-rancher-mirrored-metrics-server-v0.8.0.tar
# images/docker.io-rancher-mirrored-pause-3.6.tar
```

**检查点 ✅**: 12个镜像文件全部存在

### 阶段2: 离线安装测试

#### 2.1 准备测试环境

```bash
# 传输离线包到测试机器
scp kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz test-server:/tmp/

# SSH到测试机器
ssh test-server

# 解压离线包
cd /tmp
tar -xzf kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz
cd kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64
```

#### 2.2 断网测试

```bash
# 方法1: 使用iptables完全阻断外网 (推荐)
sudo iptables -A OUTPUT -p tcp --dport 443 -j REJECT
sudo iptables -A OUTPUT -p tcp --dport 80 -j REJECT
sudo iptables -A OUTPUT -p udp --dport 53 -j REJECT

# 验证无法联网
ping -c 3 8.8.8.8  # 应该失败
curl -I https://google.com  # 应该失败

# 方法2: 断开网络接口
# sudo ip link set eth0 down
```

**检查点 ✅**: 确认机器完全无法访问互联网

#### 2.3 执行安装

```bash
# 记录开始时间
START_TIME=$(date +%s)

# 获取本机IP (用于云端对外IP)
SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)

# 执行安装
sudo ./install.sh "$SERVER_IP"

# 记录结束时间
END_TIME=$(date +%s)
INSTALL_DURATION=$((END_TIME - START_TIME))

echo "安装耗时: ${INSTALL_DURATION}秒"
```

**检查点 ✅**: 安装脚本无错误退出 (exit code 0)

#### 2.4 验证安装日志

```bash
# 检查安装日志
sudo cat /var/log/kubeedge-cloud-install.log

# 必须包含以下关键输出:
# ✓ Binaries located
# ✓ Prerequisites checked
# ✓ Found 12 images to load (或类似数量)
# ✓ Images imported: 12 successful, 0 failed
# ✓ k3s is ready
# ✓ Kubernetes API is ready
# ✓ Namespace created
# ✓ Pre-imported 4 KubeEdge images
# ✓ CloudCore is ready
# ✓ Edge token generated
```

**检查点 ✅**: 日志显示"Pre-imported 4 KubeEdge images"

#### 2.5 验证服务状态

```bash
# 检查k3s服务
sudo systemctl status k3s
# 预期: active (running)

# 检查kubectl可用性
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl cluster-info
# 预期: 输出集群信息

# 检查节点状态
kubectl get nodes
# 预期: 1个节点，状态Ready

# 检查kubeedge命名空间
kubectl get ns kubeedge
# 预期: Active
```

**检查点 ✅**: k3s服务运行正常，kubectl命令可用

#### 2.6 验证KubeEdge组件

```bash
# 检查CloudCore Pod
kubectl -n kubeedge get pod
# 预期: cloudcore pod状态Running

# 检查所有容器
kubectl -n kubeedge get pod -o wide

# 检查镜像拉取状态 (不应有ImagePullBackOff)
kubectl -n kubeedge get events | grep -i pull
# 预期: 无拉取失败事件

# 验证CloudCore日志
kubectl -n kubeedge logs deployment/cloudcore | head -20
# 预期: 无错误日志
```

**检查点 ✅**: CloudCore Pod状态Running，无ImagePullBackOff

#### 2.7 验证镜像已加载

```bash
# 列出k3s containerd中的镜像
sudo /usr/local/bin/k3s ctr images ls | grep kubeedge

# 必须包含:
# kubeedge/cloudcore:v1.22.0
# kubeedge/iptables-manager:v1.22.0
# kubeedge/controller-manager:v1.22.0
# kubeedge/admission:v1.22.0

# 统计镜像数量
IMAGE_COUNT=$(sudo /usr/local/bin/k3s ctr images ls | wc -l)
echo "已加载镜像数量: $IMAGE_COUNT"
# 预期: >= 12
```

**检查点 ✅**: 4个KubeEdge镜像全部加载

#### 2.8 验证Token生成

```bash
# 检查token文件
sudo cat /etc/kubeedge/tokens/edge-token.txt

# 应该包含:
# {
#   "cloudIP": "xxx.xxx.xxx.xxx",
#   "cloudPort": 10000,
#   "token": "...",
#   "generatedAt": "...",
#   "edgeConnectCommand": "..."
# }

# 验证token不为空
TOKEN=$(sudo cat /etc/kubeedge/tokens/edge-token.txt | grep -o '"token": "[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN" ]; then
    echo "✓ Token生成成功: ${TOKEN:0:20}..."
else
    echo "✗ Token生成失败"
    exit 1
fi
```

**检查点 ✅**: Token文件存在且格式正确

### 阶段3: 网络监控测试

#### 3.1 监控网络流量

```bash
# 在安装过程中监控网络流量 (需要在安装前启动)
# 终端1: 启动流量监控
sudo tcpdump -i any -n 'tcp port 80 or tcp port 443' -w /tmp/install_traffic.pcap &
TCPDUMP_PID=$!

# 终端2: 执行安装
sudo ./install.sh "$SERVER_IP"

# 终端1: 停止监控
sudo kill $TCPDUMP_PID

# 分析流量
tcpdump -r /tmp/install_traffic.pcap | wc -l
# 预期: 0 (无外网访问)
```

**检查点 ✅**: 安装过程无任何外网HTTP/HTTPS请求

#### 3.2 验证DNS查询

```bash
# 检查DNS查询日志
sudo journalctl -u k3s | grep -i "dns\|resolve"
# 预期: 无外部域名解析失败
```

**检查点 ✅**: 无外部DNS解析尝试

### 阶段4: 清理测试

#### 4.1 恢复网络

```bash
# 恢复iptables
sudo iptables -D OUTPUT -p tcp --dport 443 -j REJECT
sudo iptables -D OUTPUT -p tcp --dport 80 -j REJECT
sudo iptables -D OUTPUT -p udp --dport 53 -j REJECT

# 或恢复网络接口
# sudo ip link set eth0 up

# 验证网络恢复
ping -c 3 8.8.8.8
```

#### 4.2 卸载测试

```bash
# 使用cleanup脚本清理
sudo bash /workspaces/kubeprepare/cleanup.sh

# 手动清理残留
sudo rm -rf /etc/rancher/k3s
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /etc/kubeedge
sudo rm -rf /var/lib/kubeedge
sudo rm -f /usr/local/bin/k3s
sudo rm -f /usr/local/bin/keadm
```

## 测试结果记录

### 测试矩阵

| 测试项 | 状态 | 备注 |
|--------|------|------|
| 离线包构建 | ⬜ | |
| 完整性验证 | ⬜ | |
| 镜像文件检查 | ⬜ | |
| 断网环境准备 | ⬜ | |
| 离线安装执行 | ⬜ | |
| 安装日志验证 | ⬜ | |
| 服务状态检查 | ⬜ | |
| KubeEdge组件验证 | ⬜ | |
| 镜像加载验证 | ⬜ | |
| Token生成验证 | ⬜ | |
| 网络流量监控 | ⬜ | |
| DNS查询检查 | ⬜ | |

### 测试通过标准

所有测试项必须满足以下条件：

✅ 构建: 离线包包含12个镜像文件
✅ 安装: 无错误完成，耗时<10分钟
✅ 日志: 包含"Pre-imported 4 KubeEdge images"
✅ 服务: k3s和CloudCore运行正常
✅ 镜像: 4个KubeEdge镜像已加载
✅ 网络: 安装过程0个外网请求
✅ Token: 成功生成且格式正确

## 常见问题排查

### 问题1: 镜像导入失败

**症状**: 日志显示"Failed to import xxx.tar"

**排查**:
```bash
# 检查镜像文件完整性
ls -lh images/
md5sum images/*.tar

# 手动导入测试
sudo /usr/local/bin/k3s ctr images import images/docker.io-kubeedge-cloudcore-v1.22.0.tar
```

### 问题2: CloudCore Pod ImagePullBackOff

**症状**: `kubectl get pod`显示ImagePullBackOff

**排查**:
```bash
# 检查镜像是否已加载
sudo /usr/local/bin/k3s ctr images ls | grep kubeedge

# 检查Pod事件
kubectl -n kubeedge describe pod <pod-name>

# 检查keadm init是否在镜像导入后执行
sudo cat /var/log/kubeedge-cloud-install.log | grep -A5 "Pre-importing KubeEdge"
```

### 问题3: Token生成失败

**症状**: token文件为空或格式错误

**排查**:
```bash
# 检查CloudCore是否运行
kubectl -n kubeedge get pod

# 手动生成token
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo /usr/local/bin/keadm gettoken --kube-config=/etc/rancher/k3s/k3s.yaml
```

## 自动化测试脚本

TODO: 创建自动化测试脚本 `test_offline_install.sh`

## 测试报告模板

```
测试日期: YYYY-MM-DD
测试人员: 
测试环境: 
  - OS: 
  - 架构: 
  - 内核: 

测试结果: [通过/失败]

详细数据:
  - 离线包大小: 
  - 安装耗时: 
  - 镜像数量: 
  - 网络请求: 

问题记录:
  1. 
  2. 

建议:
  1. 
  2. 
```

## 版本历史

- v1.0.0 (2025-12-06): 初始版本，修复KubeEdge镜像离线支持
