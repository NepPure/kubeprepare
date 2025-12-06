# CI/CD 架构文档

## 概述

此项目已将离线包的完整构建过程移至 GitHub Actions，无需本地依赖 Docker。所有构建工作在 GitHub Actions 的云环境中进行。

## 架构变更

### 旧架构（已弃用）
- 依赖本地 `build.sh` 脚本
- 要求本地开发环境安装 Docker/Podman
- 镜像下载依赖本地容器运行时
- 不支持跨架构构建

### 新架构（当前）
- **完全在 GitHub Actions 中构建**
- 无需本地 Docker
- 支持多架构构建（amd64, arm64）
- 自动处理镜像下载和打包
- 自动发布到 GitHub Release

## 工作流程

### 触发条件
当推送 Git tag（格式 `v*`）时自动触发：
```bash
git tag v1.0.0
git push origin v1.0.0
```

### 构建过程

#### 1. 并行构建（Matrix Build）
- 为每个架构（amd64/arm64）创建独立的构建 job
- 同时进行，加速整体流程

#### 2. 云端离线包构建步骤
1. **下载 k3s 二进制文件** - 从 GitHub 获取 k3s 可执行文件
2. **下载 KubeEdge 云端包** - 提取 cloudcore 二进制
3. **下载 KubeEdge keadm** - 提取 keadm 二进制
4. **下载容器镜像** - 使用 Docker 拉取并保存镜像为 tar 文件
   - `rancher/mirrored-pause:3.6`
   - `rancher/mirrored-coredns:1.11.1`
   - `rancher/mirrored-metrics-server:v0.7.1`
   - `rancher/local-path-provisioner:v0.0.30`
5. **创建配置模板** - 生成 cloudcore 配置文件
6. **打包** - 将所有文件和 install.sh 打包为 tar.gz

#### 3. 边缘端离线包构建步骤
1. **下载 KubeEdge 边缘端包** - 提取 edgecore 二进制
2. **下载 KubeEdge keadm** - 提取 keadm 二进制
3. **下载 containerd 和 runc** - 获取容器运行时
4. **下载 CNI 插件** - 网络插件
5. **创建配置模板** - 生成 edgecore 配置文件
6. **打包** - 将所有文件和 install.sh 打包为 tar.gz

#### 4. Release 发布
- 汇总所有架构的包文件
- 生成 SHA256 校验和
- 创建 GitHub Release 并上传所有文件

## 目录结构

```
.github/workflows/
├── build-release.yml          # 主构建工作流

cloud/
├── build/
│   └── build.sh              # 本地构建脚本（可选，兼容性保留）
├── install/
│   └── install.sh            # 安装脚本
└── release/                   # 构建输出目录（本地）

edge/
├── build/
│   └── build.sh              # 本地构建脚本（可选，兼容性保留）
├── install/
│   └── install.sh            # 安装脚本
└── release/                   # 构建输出目录（本地）
```

## 关键特性

### 1. 多架构支持
- **amd64** 架构编译和打包
- **arm64** 架构编译和打包
- 使用 QEMU 和 Docker Buildx 实现

### 2. 离线环境完整性
- **容器镜像预打包** - k3s 启动所需的所有镜像都已包含
- **所有二进制文件** - k3s、KubeEdge、containerd 等
- **配置文件** - 可用的默认配置模板
- **安装脚本** - 完整的安装脚本

### 3. 校验和验证
- 自动生成 SHA256 校验和
- 支持包完整性验证

### 4. 版本管理
- 通过 Git tag 控制版本
- Release 自动标记版本信息

## 使用说明

### 触发构建
```bash
# 标记新版本
git tag v1.0.0

# 推送标签
git push origin v1.0.0

# GitHub Actions 自动开始构建
```

### 本地构建（可选）
如需在本地构建（需要 Docker）：
```bash
# 云端包
bash cloud/build/build.sh amd64

# 边缘端包
bash edge/build/build.sh amd64

# 输出文件在相应的 release/ 目录
```

### 获取构建产物
- 自动发布到 GitHub Release
- 包含所有架构的离线包
- 包含 SHA256 校验和文件

## 版本信息

### 当前版本配置
- **K3S 版本**: v1.34.2+k3s1
- **KubeEdge 版本**: 1.22.0
- **Containerd 版本**: 1.7.0
- **RUNC 版本**: 1.1.9
- **CNI 插件版本**: 1.3.0

### 修改版本
编辑 `.github/workflows/build-release.yml` 中的版本变量。

## 故障排除

### 构建失败常见原因

1. **网络问题** - GitHub Actions 无法从 GitHub/Docker Hub 下载
   - 检查网络连接和代理设置

2. **镜像拉取失败** - Docker Hub 速率限制
   - 等待一段时间后重试

3. **磁盘空间不足** - 大型镜像导致空间溢出
   - GitHub Actions VM 通常有足够空间，检查最大镜像大小

4. **时间超限** - 构建超过 6 小时限制
   - 优化下载链接或分批处理

## 最佳实践

1. **版本管理** - 始终使用 tag 进行版本控制
2. **校验和验证** - 部署前验证包的 SHA256
3. **测试** - 在正式发布前进行充分测试
4. **发布说明** - GitHub Release 中包含详细的更新说明

## 后续改进

- [ ] 支持多个镜像仓库源
- [ ] 自动化性能测试
- [ ] 更详细的构建日志
- [ ] 支持自定义版本配置
- [ ] 增量构建缓存
