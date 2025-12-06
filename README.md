# KubeEdge 1.22 离线安装项目

## 简介

这是一个完整的 KubeEdge 1.22 离线安装解决方案，包括：
- **云端**：k3s + KubeEdge CloudCore（支持 amd64/arm64）
- **边缘端**：containerd + runc + KubeEdge EdgeCore（支持 amd64/arm64）

支持在**完全离线环境**下快速部署 KubeEdge 边缘计算基础设施。

### 完整离线支持

✅ **云端镜像完整打包** (最新修复)
- 包含所有 K3s 系统镜像 (8个)
- 包含所有 KubeEdge 组件镜像 (4个)
  - cloudcore:v1.22.0
  - iptables-manager:v1.22.0
  - controller-manager:v1.22.0
  - admission:v1.22.0
- 安装前自动预导入，无需联网

## 快速开始

### 云端安装（一键部署）

```bash
# 1. 准备离线包（在有网络的机器上）
cd cloud/build
bash build.sh amd64  # 或 arm64

# 2. 上传生成的包到云端服务器，然后执行安装
sudo bash ../install/install.sh \
  --package /path/to/kubeedge-cloud-amd64-k3s.tar.gz \
  --cloud-ip 10.0.0.1 \
  --port 10000
```

安装完成后将自动输出边缘节点的接入 token。

### 边缘端安装（一键部署）

```bash
# 1. 准备离线包
cd edge/build
bash build.sh amd64  # 或 arm64

# 2. 上传包到边缘节点，然后执行安装
sudo bash ../install/install.sh \
  --package /path/to/kubeedge-edge-amd64.tar.gz \
  --cloud-url wss://10.0.0.1:10000/edge/node-name \
  --token YOUR_TOKEN_FROM_CLOUD \
  --node-name node-name
```

## 项目结构

```
kubeprepare/
├── cloud/                          # 云端相关
│   ├── build/
│   │   └── build.sh               # 构建云端离线包
│   ├── install/
│   │   ├── install.sh             # 云端安装脚本
│   │   └── README.md              # 云端详细说明
│   └── release/                   # 生成的离线包存放位置
├── edge/                           # 边缘端相关
│   ├── build/
│   │   └── build.sh               # 构建边缘端离线包
│   ├── install/
│   │   ├── install.sh             # 边缘端安装脚本
│   │   └── README.md              # 边缘端详细说明
│   └── release/                   # 生成的离线包存放位置
├── cleanup.sh                      # 清理脚本（用于重新安装）
└── README.md                       # 本文件
```

## 功能特性

✅ **完全离线支持** - 所有二进制文件、配置和容器镜像已完整打包
  - 包含 12 个容器镜像（8个K3s + 4个KubeEdge）
  - 支持纯离线环境部署，无需任何网络连接

✅ **多架构支持** - amd64 和 arm64 兼容

✅ **一键安装** - 云端和边缘端都支持自动化部署

✅ **镜像预导入** - 安装前自动加载所有镜像，避免在线拉取

✅ **Token 安全机制** - 云端自动生成 token 供边缘端接入

✅ **持续集成** - 自动构建和发布到 GitHub Release

✅ **完整性验证** - 提供验证脚本确保离线包完整性

✅ **EdgeMesh 服务网格** - 边缘节点使用 host 网络 + EdgeMesh 实现服务发现和通信
  - 无需 CNI 插件配置
  - 支持边缘到边缘的服务访问
  - 支持边缘到云端的服务访问

## 网络架构

### 边缘节点网络模式

边缘节点采用 **host 网络模式**，不使用 CNI 插件：
- ✅ 简化配置，无需为每个边缘节点分配独立的 Pod 网段
- ✅ 更适合边缘场景的资源限制
- ✅ 通过 EdgeMesh 实现服务网格能力

### EdgeMesh 服务网格

EdgeMesh 提供边缘服务发现和流量代理：
- **服务发现**: 通过 EdgeMesh DNS (169.254.96.16)
- **流量代理**: EdgeMesh Agent 实现服务间通信
- **高可用**: 支持配置多个中继节点
- **跨网络**: 支持边缘节点在不同网络环境下的通信

> 📘 详细部署步骤请参考 [EdgeMesh 部署指南](./EDGEMESH_DEPLOYMENT.md)

## 详细文档

- [云端安装指南](./cloud/install/README.md)
- [边缘端安装指南](./edge/install/README.md)
- [EdgeMesh 部署指南](./EDGEMESH_DEPLOYMENT.md) - 边缘服务网格部署
- [离线镜像修复报告](./OFFLINE_IMAGE_FIX.md) - 完整离线支持的技术细节

## 验证工具

### 验证云端离线包完整性

```bash
# 验证构建的离线包是否包含所有必需镜像
bash verify_cloud_images.sh kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz
```

验证内容：
- ✓ 4个KubeEdge组件镜像
- ✓ 8个K3s系统镜像  
- ✓ 所有必需的二进制文件和配置

## 故障排除

### 清理重新安装

```bash
sudo bash cleanup.sh
```

此脚本将清理：
- edgecore 和 containerd 服务
- 相关二进制文件
- 配置文件和数据目录

### EdgeMesh 未自动启动

EdgeMesh 需要在安装完 EdgeCore 后手动部署：
1. 边缘节点需要先成功连接到云端
2. 确保 metaServer 已启用 (安装脚本已自动配置)
3. 在云端通过 Helm 部署 EdgeMesh (参考 [EdgeMesh 部署指南](./EDGEMESH_DEPLOYMENT.md))

## 版本信息

- **KubeEdge**: v1.22
- **k3s**: 最新稳定版
- **支持架构**: amd64, arm64

