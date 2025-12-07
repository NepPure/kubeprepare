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

---

## Edge端 keadm join 离线依赖研究与解决方案（新增）

### 背景与问题

在完全离线环境执行 `keadm join` 时，边缘节点会尝试在线拉取 `kubeedge/installation-package:v1.22.0` 镜像，并在复制二进制资源时依赖 containerd 的 Pod Sandbox 基础镜像 `kubeedge/pause:3.6`。这导致在无外网条件下 join 失败，报错包含镜像拉取超时或 sandbox 镜像缺失。

### 核心原理（源码依据）

- `keadm join` 执行流程参考：`keadm/cmd/keadm/app/cmd/edge/join_others.go`（v1.22.0）
  - 步骤包含：拉取镜像 → 复制资源 → 生成 systemd 服务 → 写入配置/证书
- 资源复制实现参考：`pkg/containers/container_runtime.go`（v1.22.0）
  - 使用 CRI 创建临时 Pod Sandbox（网络命名空间为 Node，Privileged）
  - 需要 `sandbox_image`（pause 镜像）可用，随后启动临时容器以从 installation-package 镜像拷贝 `edgecore` 与 `keadm` 二进制至宿主机
- `installation-package` 镜像内容参考：`build/docker/installation-package/installation-package.dockerfile`（v1.22.0）
  - 仅包含 `/usr/local/bin/edgecore` 与 `/usr/local/bin/keadm` 两个二进制，无其他依赖

### 离线依赖清单（Edge）

- 必需镜像：
  - `docker.io/kubeedge/installation-package:v1.22.0`（keadm join 拷贝二进制用途）
  - `docker.io/kubeedge/pause:3.6`（containerd sandbox 基础镜像）
- 必需插件/组件：
  - CNI plugins v1.5.1（bridge/host-local/loopback/portmap 等）
  - containerd + runc（CRI 与 OCI 运行时）
- 不需预先打包的内容：
  - 证书文件（通过 CloudCore 10002 HTTPS 服务在线下内网下载）
  - EdgeCore 配置（由 keadm 生成，后续按需调整 clusterDNS 等）

### 我们的改造与实现

1. GitHub Actions（`build-release-edge.yml`）
   - 预拉取并保存：`kubeedge/installation-package:v1.22.0` 与 `kubeedge/pause:3.6` 到 `images/` 目录（离线包）
   - 同时打包 CNI plugins v1.5.1 到 `cni-bin/`，保证 Node Ready（v1.22.0 要求）

2. 安装脚本（`edge/install/install.sh`）
   - 在启动 containerd 后，优先 `ctr -n k8s.io images import` 预加载 `pause:3.6`（保证 Sandbox 创建）
   - 在 keadm join 前，预加载 `installation-package:v1.22.0`，避免在线拉取
   - 设置 `--cloudcore-ipport=<CLOUD_IP>:10002` 使用证书服务端口；移除过时参数；显式 `--remote-runtime-endpoint` 指向 containerd
   - 写入 EdgeCore 配置：启用 `networkPluginName: cni`，`clusterDNS: [169.254.96.16]`（EdgeMesh DNS），并设置 `clusterDomain`

3. 配置一致性
   - systemd `ExecStart` 路径修正为 `/etc/kubeedge/config/edgecore.yaml`（keadm 官方路径）
   - containerd `config.toml` 中 `sandbox_image = "kubeedge/pause:3.6"` 与实际镜像保持一致

### 加载顺序与关键时机

1. 安装并启动 containerd
2. 立即导入 `pause:3.6`（关键，供 Sandbox 使用）
3. 安装 runc 与 CNI plugins
4. 导入 `installation-package:v1.22.0`
5. 执行 `keadm join`（使用本地镜像与内网证书服务）

### 验证方式（摘录）

```bash
# 验证镜像是否已导入
ctr -n k8s.io images ls | grep pause
ctr -n k8s.io images ls | grep installation-package

# 执行 keadm join（无需外网）
sudo keadm join \
  --cloudcore-ipport=<CLOUD_IP>:10002 \
  --edgenode-name=<NODE_NAME> \
  --token=<TOKEN> \
  --kubeedge-version=v1.22.0 \
  --remote-runtime-endpoint=unix:///run/containerd/containerd.sock
```

### 常见问题与处理

- 仍尝试拉取 installation-package：确认镜像已在 `k8s.io` 命名空间并标签匹配；手动 `ctr import` 后复验
- Sandbox 创建失败：确认 `pause:3.6` 已导入且 `config.toml` 指向正确；重启 containerd
- **cgroup driver 冲突**（重要）：keadm join v1.22.0 使用 cgroupfs 路径格式，与 `SystemdCgroup = true` 不兼容，导致 runc 报错 `expected cgroupsPath to be of format "slice:prefix:name"`。**解决方案**：containerd config.toml 中设置 `SystemdCgroup = false`（边缘场景推荐 cgroupfs）
- Node NotReady：确认 CNI plugins 已安装并生成 node 专属 CIDR；检查 EdgeCore `networkPluginName: cni`
- DNS 解析异常：确认 `clusterDNS` 使用 `169.254.96.16`（EdgeMesh DNS），避免指向云 CoreDNS

### 结论

通过在构建阶段打包 installation-package 与 pause 镜像，并在安装阶段按正确时机预加载，再结合 CNI 与 EdgeMesh 的必要配置，`keadm join` 可在完全离线环境中可靠执行，证书获取通过内网的 CloudCore 10002 完成，整体不再依赖公网访问。


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
