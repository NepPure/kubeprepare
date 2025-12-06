# CI/CD 持续集成配置

## 概述

本项目已配置 GitHub Actions 工作流，在推送 Git tag 时自动触发离线安装包构建和发布。

## 工作流说明

### 触发条件

- 当推送任何形如 `v*` 的 tag 时自动触发（如 `v1.22.0`, `v1.23.0`）

### 工作流步骤

1. **检出代码** - 获取最新的代码
2. **环境准备** - 安装必需的工具（wget, tar, gzip）
3. **构建离线包** - 执行 `online_prepare.sh` 下载所有依赖并打包
4. **重命名包** - 将包文件按版本号命名
5. **生成校验和** - 创建 SHA256 校验文件
6. **发布 Release** - 创建 GitHub Release 并上传构建产物
7. **清理** - 删除临时构建文件

## 使用方法

### 1. 创建并推送 tag

```bash
# 创建本地 tag
git tag v1.22.0

# 推送到远程
git push origin v1.22.0
```

### 2. 查看构建进度

在 GitHub 仓库页面：
- 点击 "Actions" 标签
- 找到对应的工作流运行
- 查看实时执行日志

### 3. 获取发布的包

构建完成后，在 GitHub 仓库的 "Releases" 页面将出现：
- `kubeedge-edge-offline-vX.X.X.tar.gz` - 离线安装包
- `checksums.txt` - SHA256 校验文件

## 配置说明

工作流配置文件：`.github/workflows/build-release.yml`

### 环境要求

- **Runner**: Ubuntu latest
- **权限**: 需要 GITHUB_TOKEN 用于创建 Release

### 自定义版本号

工作流从 Git tag 自动提取版本号，无需手动配置。

Tag 格式建议：
- `v1.22.0` - 正式版本
- `v1.22.0-beta` - beta 版本
- `v1.22.0-rc1` - RC 版本

## 常见问题

### Q: 如何修改版本号？

A: 直接创建新的 tag 并推送即可，工作流会自动使用该版本号。

### Q: 构建失败怎么办？

A: 查看 Actions 日志了解失败原因，常见问题包括：
- 网络连接问题（下载依赖失败）
- 磁盘空间不足
- 依赖版本不可用

### Q: 能否修改构建输出文件名？

A: 在 `.github/workflows/build-release.yml` 中修改相应步骤的命名逻辑。

### Q: 能否同时构建多个架构？

A: 可以，需要在工作流中添加 matrix 策略。详见 GitHub Actions 文档。

## 相关文件

- `online_prepare.sh` - 联网环境下的离线包准备脚本
- `offline_install.sh` - 离线安装脚本
- `.github/workflows/build-release.yml` - CI/CD 工作流配置

## 发布说明

Release 会包含以下信息：
- 发布标题：从 Git tag 自动生成
- 发布说明：GitHub 自动从提交信息生成
- 资源文件：离线安装包和校验文件
