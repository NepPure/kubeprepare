# CI/CD 重构变更说明

## 变更日期
2025-12-06

## 主要改变

### 1. 构建流程完全迁移到 GitHub Actions

#### 前：依赖本地脚本
```
开发者 → 本地 build.sh → 需要 Docker → 上传 Release
```

#### 后：完全在 GitHub 云环境
```
Git Tag → GitHub Actions → 自动下载+构建+打包+发布
```

### 2. 移除本地 Docker 依赖

| 项目 | 旧方式 | 新方式 |
|------|--------|--------|
| 镜像下载 | 本地 Docker | GitHub Actions Docker |
| 构建环境 | 本地机器 | GitHub Ubuntu Runner |
| 跨架构编译 | 不支持或复杂 | 使用 QEMU + Docker Buildx |

### 3. 新增功能

#### 多架构并行构建
- 同时构建 amd64 和 arm64
- 加速整体构建过程

#### 自动化镜像打包
- 自动拉取 k3s 系统镜像
- 保存为 tar 文件，包含在离线包中
- 支持离线环境直接使用

#### 完整的离线包
构建产物现在包含：
- k3s/edgecore/keadm 二进制文件
- 所有容器镜像（tar 格式）
- 配置文件模板
- 安装脚本

### 4. 使用流程改变

#### 旧方式
```bash
# 1. 开发机需要 Docker
# 2. 手动运行构建脚本
bash cloud/build/build.sh amd64
bash edge/build/build.sh amd64

# 3. 手动上传 Release
```

#### 新方式
```bash
# 1. 推送 tag 即可
git tag v1.0.0
git push origin v1.0.0

# 2. 自动构建完成
# 3. 自动发布 Release
# 完全无需本地操作
```

### 5. Workflow 文件完全重写

#### 核心变更
- 使用 `docker/setup-qemu-action` 支持 ARM64
- 使用 `docker/setup-buildx-action` 支持多平台构建
- 将所有构建逻辑内联到 workflow 中
- 移除对 build.sh 脚本的依赖

#### 新增步骤
```yaml
- 设置QEMU支持           # 支持 ARM64 模拟
- 设置Docker Buildx     # 多平台编译工具
- 构建云端离线包 (inline)  # 直接在 workflow 中执行
- 构建边缘端离线包 (inline)
- 下载容器镜像           # 使用 Docker 拉取镜像
```

### 6. 文件结构保留

为了兼容性，本地脚本仍保留：
- `cloud/build/build.sh` - 本地构建脚本（可选）
- `edge/build/build.sh` - 本地构建脚本（可选）

这些脚本可用于本地开发/调试，但已不是主要构建方式。

## 依赖变更

### 移除
- ❌ 本地 Docker/Podman 要求
- ❌ 本地 shell 脚本执行
- ❌ 手动版本管理

### 新增
- ✅ GitHub Actions 权限（已配置）
- ✅ Git tag 约定
- ✅ GitHub Release API

## 优势

| 方面 | 优势 |
|------|------|
| 成本 | 无需维护本地 CI 服务器 |
| 效率 | 并行构建多架构，更快完成 |
| 可靠性 | 标准化 GitHub 环境，结果可复现 |
| 扩展性 | 易于添加更多构建步骤 |
| 易用性 | 只需 `git tag && git push` |

## 测试清单

- [x] 云端包构建逻辑完整
- [x] 边缘端包构建逻辑完整
- [x] 容器镜像正确打包
- [x] 安装脚本正确包含
- [x] 校验和正确生成
- [x] Release 自动发布
- [x] 多架构支持

## 回滚计划

如需回到旧方式：
1. 恢复 `.github/workflows/build-release.yml` 历史版本
2. 或者简单地不推送 tag，手动运行 build.sh

## 参考

- 构建配置：`.github/workflows/build-release.yml`
- 架构文档：`CI_CD_ARCHITECTURE.md`
- 云端脚本：`cloud/build/build.sh`（本地，可选）
- 边缘脚本：`edge/build/build.sh`（本地，可选）
