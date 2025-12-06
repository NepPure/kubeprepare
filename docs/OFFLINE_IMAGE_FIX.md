# Cloud端离线安装镜像完整性修复报告

## 问题描述

在之前的版本中，cloud端安装过程**未充分考虑 KubeEdge CloudCore 依赖的镜像**，无法完全做到离线安装。

### 根本原因

1. **构建阶段**: `.github/workflows/build-release.yml` 只下载了 k3s 相关镜像，遗漏了 KubeEdge 组件镜像
2. **安装阶段**: `cloud/install/install.sh` 使用 `keadm init` 命令部署 CloudCore，该命令会尝试从网络拉取镜像
3. **缺失镜像**: 4个 KubeEdge 核心组件镜像未被打包

## 缺失的镜像列表

根据 KubeEdge v1.22.0 源码 (`keadm/cmd/keadm/app/cmd/util/image.go`)，CloudCore 需要以下镜像：

```
kubeedge/cloudcore:v1.22.0
kubeedge/iptables-manager:v1.22.0  
kubeedge/controller-manager:v1.22.0
kubeedge/admission:v1.22.0
```

## 修复方案

### 1. 构建脚本修复 (`.github/workflows/build-release.yml`)

**修改位置**: 第105-133行

**修改内容**:
```yaml
# 添加 KubeEdge 组件镜像列表
KUBEEDGE_IMAGES=(
  "docker.io/kubeedge/cloudcore:v${KUBEEDGE_VERSION}"
  "docker.io/kubeedge/iptables-manager:v${KUBEEDGE_VERSION}"
  "docker.io/kubeedge/controller-manager:v${KUBEEDGE_VERSION}"
  "docker.io/kubeedge/admission:v${KUBEEDGE_VERSION}"
)

# 合并 k3s 和 KubeEdge 镜像一起下载
ALL_IMAGES=("${K3S_IMAGES[@]}" "${KUBEEDGE_IMAGES[@]}")
```

**效果**: 
- 构建时下载 8个k3s镜像 + 4个KubeEdge镜像，共12个镜像
- 所有镜像打包到 `images/` 目录

### 2. 安装脚本修复 (`cloud/install/install.sh`)

**修改位置**: 第198-221行 (在 keadm init 之前)

**修改内容**:
```bash
# Pre-import KubeEdge images before keadm init
echo "[5/7-b] Pre-importing KubeEdge component images..." | tee -a "$INSTALL_LOG"
if [ -d "$IMAGES_DIR" ]; then
  KUBEEDGE_IMAGE_COUNT=0
  for image_tar in "$IMAGES_DIR"/docker.io-kubeedge-*.tar; do
    if [ -f "$image_tar" ]; then
      echo "  Pre-importing KubeEdge image: $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
      if /usr/local/bin/k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        KUBEEDGE_IMAGE_COUNT=$((KUBEEDGE_IMAGE_COUNT + 1))
      else
        echo "  Warning: Failed to import $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  echo "✓ Pre-imported $KUBEEDGE_IMAGE_COUNT KubeEdge images" | tee -a "$INSTALL_LOG"
fi
```

**效果**:
- 在执行 `keadm init` **之前**，提前将 KubeEdge 镜像导入到 k3s containerd
- `keadm init` 执行时会优先使用本地已有镜像，不再从网络拉取
- 通过文件名模式 `docker.io-kubeedge-*.tar` 精确匹配 KubeEdge 镜像

## 验证方法

### 构建验证

```bash
# 查看构建后的镜像文件
tar -tzf kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz | grep "images/"

# 应该包含以下文件:
images/docker.io-kubeedge-cloudcore-v1.22.0.tar
images/docker.io-kubeedge-iptables-manager-v1.22.0.tar
images/docker.io-kubeedge-controller-manager-v1.22.0.tar
images/docker.io-kubeedge-admission-v1.22.0.tar
```

### 安装验证

```bash
# 在完全离线环境安装后，检查日志
cat /var/log/kubeedge-cloud-install.log | grep "Pre-importing KubeEdge"

# 应该显示:
# ✓ Pre-imported 4 KubeEdge images

# 验证镜像已加载
k3s ctr images ls | grep kubeedge
# 应该列出4个kubeedge镜像
```

### 完整离线测试

```bash
# 1. 断网测试
sudo iptables -A OUTPUT -p tcp --dport 443 -j REJECT
sudo iptables -A OUTPUT -p tcp --dport 80 -j REJECT

# 2. 执行安装
sudo ./install.sh <对外IP>

# 3. 验证成功
kubectl -n kubeedge get pod
# 所有pod应该正常Running，没有ImagePullBackOff
```

## 技术细节

### 镜像命名规则

Docker save 的镜像文件名格式化规则:
```bash
filename=$(echo "$image" | sed 's/[\/:]/-/g')
```

示例:
- `docker.io/kubeedge/cloudcore:v1.22.0` → `docker.io-kubeedge-cloudcore-v1.22.0.tar`

### 导入顺序

1. **第一批**: k3s 系统镜像 (coredns, pause, metrics-server等)
2. **第二批**: KubeEdge 组件镜像 (在keadm init之前)
3. keadm init 使用本地镜像部署 CloudCore

### 兼容性

- ✅ k3s v1.34.2+k3s1
- ✅ KubeEdge v1.22.0
- ✅ amd64 / arm64 双架构
- ✅ 完全离线环境

## 影响范围

### 修改文件
1. `.github/workflows/build-release.yml` - 构建工作流
2. `cloud/install/install.sh` - 安装脚本

### 不影响
- edge端安装流程
- 现有的k3s镜像处理逻辑
- keadm 命令参数
- 配置文件模板

## 后续优化建议

1. **镜像预热**: 可考虑在构建时验证镜像完整性
2. **版本管理**: 将镜像列表提取为独立配置文件
3. **MD5校验**: 为每个镜像tar添加校验和
4. **压缩优化**: 考虑使用更高效的镜像压缩方式

## 参考资料

- KubeEdge 镜像定义: `keadm/cmd/keadm/app/cmd/util/image.go`
- CloudCore Helm Chart: `manifests/charts/cloudcore/README.md`
- 测试脚本: `tests/scripts/keadm_e2e.sh`

## 修复日期

2025-12-06

## 版本信息

- KubeEdge: v1.22.0
- k3s: v1.34.2+k3s1
- 修复版本: 本次提交
