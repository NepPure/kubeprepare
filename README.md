# KubeEdge 1.22 离线安装项目

## 简介

这是一个完整的 KubeEdge 1.22 离线安装解决方案，包括：
- **云端**：k3s + KubeEdge CloudCore（支持 amd64/arm64）
- **边缘端**：containerd + runc + KubeEdge EdgeCore（支持 amd64/arm64）

支持在完全离线环境下快速部署 KubeEdge 边缘计算基础设施。

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
├── scripts/
│   └── create-release.sh           # 自动化构建和发布脚本
├── cleanup.sh                      # 清理脚本（用于重新安装）
└── README.md                       # 本文件
```

## 功能特性

✅ **完全离线支持** - 所有二进制文件和配置已包含

✅ **多架构支持** - amd64 和 arm64 兼容

✅ **一键安装** - 云端和边缘端都支持自动化部署

✅ **Token 安全机制** - 云端自动生成 token 供边缘端接入

✅ **持续集成** - 自动构建和发布到 GitHub Release

## 详细文档

- [云端安装指南](./cloud/install/README.md)
- [边缘端安装指南](./edge/install/README.md)

## 故障排除

### 清理重新安装

```bash
sudo bash cleanup.sh
```

此脚本将清理：
- edgecore 和 containerd 服务
- 相关二进制文件
- CNI 插件
- 配置文件和数据目录

## 版本信息

- **KubeEdge**: v1.22
- **k3s**: 最新稳定版
- **支持架构**: amd64, arm64

