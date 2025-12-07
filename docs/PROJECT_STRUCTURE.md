# KubeEdge 1.22 离线安装项目结构

这是一个完整的 KubeEdge 1.22 离线安装解决方案，支持云端和边缘端的完全离线部署。

## 项目结构

```
kubeprepare/
├── cloud/                          # 云端安装包和脚本
│   ├── build/
│   │   └── build.sh               # 构建云端离线包 (支持 amd64/arm64)
│   ├── install/
│   │   ├── install.sh             # 云端一键安装脚本（已增强：自动部署 Metrics Server）
│   │   ├── README.md              # 云端详细安装指南
│   │   └── manifests/             # 【新增】日志与监控部署清单
│   │       ├── metrics-server.yaml           # Metrics Server 部署配置
│   │       ├── iptables-metrics-setup.sh     # iptables 规则配置脚本
│   │       └── verify-logs-metrics.sh        # 功能验证脚本
│   └── release/                   # 生成的离线包存放位置
│       └── (自动生成)
│
├── edge/                           # 边缘端安装包和脚本
│   ├── build/
│   │   └── build.sh               # 构建边缘端离线包 (支持 amd64/arm64)
│   ├── install/
│   │   ├── install.sh             # 边缘端一键安装脚本（已增强：自动启用 EdgeStream）
│   │   └── README.md              # 边缘端详细安装指南
│   └── release/                   # 生成的离线包存放位置
│       └── (自动生成)
│
├── scripts/
│   └── create-release.sh           # 自动化构建和 GitHub Release 发布脚本
│
├── cleanup.sh                      # 清理脚本 (用于卸载和重新安装)
├── .github/workflows/
│   └── build-release.yml           # CI/CD 工作流 (GitHub Actions)
├── README.md                       # 项目主文档
└── PROJECT_STRUCTURE.md            # 本文件
```

## 主要文件说明

### cloud/build/build.sh
构建云端离线安装包，包含 k3s 和 KubeEdge CloudCore。

**用法**:
```bash
bash cloud/build/build.sh amd64    # 构建 amd64 版本
bash cloud/build/build.sh arm64    # 构建 arm64 版本
```

**输出**:
- `cloud/release/kubeedge-cloud-v1.22.0-k3s-v1.28.0-amd64.tar.gz`
- `cloud/release/kubeedge-cloud-v1.22.0-k3s-v1.28.0-arm64.tar.gz`

### cloud/install/install.sh
云端一键安装脚本，自动安装 k3s 和 KubeEdge 云端，并生成边缘节点连接 token。

**【已增强】**新增功能：
- ✅ 自动部署 Metrics Server（用于资源监控）
- ✅ 自动配置 iptables 规则（用于 kubectl top）
- ✅ 自动启用 CloudStream（用于 kubectl logs/exec）

**用法**:
```bash
sudo bash cloud/install/install.sh \
  --package /path/to/package.tar.gz \
  --cloud-ip 192.168.1.100 \
  --port 10000
```

**参数**:
- `--package`: 离线包路径
- `--cloud-ip`: 云端对外 IP 地址 (必需)
- `--port`: CloudHub 监听端口 (默认 10000)

**输出**:
- Kubernetes 集群已部署
- KubeEdge CloudCore 已安装（CloudStream 已启用）
- Metrics Server 已部署并配置
- iptables NAT 规则已配置
- 边缘节点接入 token 已生成

### edge/build/build.sh
构建边缘端离线安装包，包含 containerd、runc 和 KubeEdge EdgeCore。

**用法**:
```bash
bash edge/build/build.sh amd64     # 构建 amd64 版本
bash edge/build/build.sh arm64     # 构建 arm64 版本
```

**输出**:
- `edge/release/kubeedge-edge-v1.22.0-amd64.tar.gz`
- `edge/release/kubeedge-edge-v1.22.0-arm64.tar.gz`

### edge/install/install.sh
边缘端一键安装脚本，自动安装容器运行时和 KubeEdge 边缘端，并连接到云端。

**【已增强】**新增功能：
- ✅ 自动启用 EdgeStream（用于 kubectl logs/exec）
- ✅ 自动配置 EdgeStream 服务器地址
- ✅ 自动配置 EdgeStream 超时参数

**用法**:
```bash
sudo bash edge/install/install.sh \
  --package /path/to/package.tar.gz \
  --cloud-url wss://192.168.1.100:10000/edge/node-name \
  --token <token-from-cloud> \
  --node-name node-name
```

**参数**:
- `--package`: 离线包路径
- `--cloud-url`: 云端 WebSocket 连接地址 (必需)
- `--token`: 云端生成的连接 token (必需)
- `--node-name`: 边缘节点名称 (必需)

### cleanup.sh
清理脚本，用于卸载所有 KubeEdge 组件。

**用法**:
```bash
sudo bash cleanup.sh
```

**清理内容**:
- 停止并卸载 edgecore 和 containerd 服务
- 删除二进制文件
- 删除 CNI 插件
- 删除配置文件和数据目录

## 工作流程

### 云端部署流程

```
1. 在联网机器上执行
   ├── bash cloud/build/build.sh amd64
   └── 生成离线包

2. 将离线包上传到云端服务器

3. 在云端服务器执行
   ├── sudo bash cloud/install/install.sh \
   │      --package package.tar.gz \
   │      --cloud-ip 192.168.1.100
   └── 云端安装完成，生成 token

4. 保存输出的 token
```

### 边缘端部署流程

```
1. 在联网机器上执行
   ├── bash edge/build/build.sh amd64
   └── 生成离线包

2. 将离线包上传到边缘节点

3. 在边缘节点执行
   ├── sudo bash edge/install/install.sh \
   │      --package package.tar.gz \
   │      --cloud-url wss://192.168.1.100:10000/edge/node-name \
   │      --token <token-from-cloud> \
   │      --node-name node-name
   └── 边缘端安装完成并连接到云端

4. 在云端验证
   └── kubectl get nodes
```

## 特性

### ✅ 完全离线支持
- 所有依赖已包含在离线包中
- 安装过程无需互联网连接
- 适合隔离环境部署

### ✅ 多架构支持
- amd64 (Intel/AMD 64 位处理器)
- arm64 (ARM 64 位处理器，如树莓派、Jetson)

### ✅ 一键自动安装
- 云端一条命令完成部署
- 边缘端一条命令完成连接
- 自动检查系统要求
- 自动生成配置文件

### ✅ 安全的 Token 机制
- 云端自动生成边缘连接 token
- 边缘端使用 token 安全连接
- Token 自动管理和过期处理

### ✅ 持续集成和发布
- 自动构建多架构安装包
- 自动发布到 GitHub Release
- 支持版本管理和下载

## 版本信息

- **KubeEdge**: v1.22
- **k3s**: 最新稳定版 (v1.28 或更高)
- **Kubernetes API**: v1.28.0
- **支持架构**: amd64, arm64
- **支持的 Linux 发行版**: CentOS, Ubuntu, Debian, Rocky Linux, Raspberry Pi OS 等

## 快速开始

### 部署云端 (5 分钟)

```bash
# 1. 构建离线包 (在联网机器上)
cd cloud/build
bash build.sh amd64

# 2. 上传包到云端服务器 (假设 /tmp/package.tar.gz)

# 3. 在云端执行安装
cd /tmp
tar -xzf package.tar.gz
cd kubeedge-cloud-*
sudo ./install.sh 192.168.1.100

# 4. 查看 token
cat /etc/kubeedge/tokens/edge-token.txt
```

### 部署边缘端 (5 分钟)

```bash
# 1. 构建离线包 (在联网机器上)
cd edge/build
bash build.sh amd64

# 2. 上传包到边缘节点

# 3. 在边缘节点执行安装
sudo ./install.sh \
  --cloud-url wss://192.168.1.100:10000/edge/my-node \
  --token <YOUR_TOKEN> \
  --node-name my-node

# 4. 验证连接 (在云端执行)
kubectl get nodes
```

## 常见问题

**Q: 如何重新安装？**
A: 执行 `sudo bash cleanup.sh` 清理所有组件，然后重新运行安装脚本。

**Q: 支持哪些架构？**
A: 支持 amd64 和 arm64，构建时通过参数指定。

**Q: 如何修改云端端口？**
A: 在安装时使用 `--port` 参数指定，或编辑 `/etc/kubeedge/edgecore.yaml` 修改。

**Q: 边缘节点无法连接怎么办？**
A: 检查网络连通性、防火墙规则、token 是否正确，查看日志文件排查问题。

## 新增功能文档

### 日志采集与资源监控

项目已集成完整的边缘日志采集和资源监控功能：

- **kubectl logs**: 从云端查看边缘 Pod 日志
- **kubectl exec**: 在边缘 Pod 中执行命令
- **kubectl top node**: 查看边缘节点资源使用情况
- **kubectl top pod**: 查看边缘 Pod 资源使用情况

#### 新增文件

```
cloud/install/manifests/
├── metrics-server.yaml              # Metrics Server 部署清单（RBAC + Deployment + Service）
├── iptables-metrics-setup.sh        # iptables 规则配置脚本（自动转发 10350 → 10003）
└── verify-logs-metrics.sh           # 功能验证脚本（自动检查所有组件）
```

#### 功能验证

```bash
# 自动验证所有功能
cd /data/kubeedge-cloud-xxx
sudo bash manifests/verify-logs-metrics.sh
```

验证项目：
- ✓ CloudCore 和 CloudStream 状态
- ✓ Metrics Server 部署状态
- ✓ iptables 规则配置
- ✓ kubectl logs/exec 功能测试
- ✓ kubectl top 功能测试

#### 详细文档

- [快速部署指南](./QUICK_DEPLOY_LOGS_METRICS.md) - 使用说明和故障排查
- [完整方案文档](./LOG_METRICS_OFFLINE_DEPLOYMENT.md) - 架构设计和实现细节

## 相关文档

- [云端安装指南](./cloud/install/README.md)
- [边缘端安装指南](./edge/install/README.md)
- [日志与监控快速部署](./QUICK_DEPLOY_LOGS_METRICS.md) 【新增】
- [日志与监控完整方案](./LOG_METRICS_OFFLINE_DEPLOYMENT.md) 【新增】
- [KubeEdge 官方文档](https://kubeedge.io/docs/)
- [k3s 文档](https://docs.k3s.io/)

## 故障排除

### 查看日志

```bash
# 云端日志
sudo journalctl -u edgecore -f        # CloudCore 日志
sudo journalctl -u k3s -f             # k3s 日志

# 边缘端日志
sudo journalctl -u edgecore -f        # EdgeCore 日志
sudo journalctl -u containerd -f      # 容器运行时日志
```

### 检查安装日志

```bash
# 云端安装日志
sudo tail -f /var/log/kubeedge-cloud-install.log

# 查看主要配置文件
sudo cat /etc/kubeedge/edgecore.yaml
```

## 贡献和反馈

欢迎提交 Issue 和 Pull Request！
