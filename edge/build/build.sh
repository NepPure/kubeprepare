#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 边缘端离线包构建脚本
# 用途: ./build.sh <架构> [版本]
# 支持的架构: amd64, arm64
# 示例: ./build.sh amd64
#       ./build.sh arm64 1.22.0

ARCH="${1:-amd64}"
KUBEEDGE_VERSION="${2:-1.22.0}"
BUILD_DIR="$(pwd)/edge-${ARCH}-build"
RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/edge/release"

# Validate architecture
if [[ ! "$ARCH" =~ ^(amd64|arm64)$ ]]; then
  echo "Error: Unsupported architecture: $ARCH"
  echo "Supported: amd64, arm64"
  exit 1
fi

echo "=== KubeEdge Edge Offline Package Builder ==="
echo "Architecture: $ARCH"
echo "KubeEdge Version: $KUBEEDGE_VERSION"
echo ""

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[1/4] 下载 KubeEdge 边缘端包..."
# KubeEdge 官方边缘端包名格式: edgesite-v{version}-linux-{arch}.tar.gz
EDGESITE_URL="https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VERSION}/edgesite-v${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "edgesite.tar.gz" "$EDGESITE_URL"; then
  echo "错误：无法下载 KubeEdge 边缘端包 $KUBEEDGE_VERSION for $ARCH"
  echo "尝试的 URL: $EDGESITE_URL"
  exit 1
fi
tar -xzf "edgesite.tar.gz"
# Extract edgecore binary from the archive
cp "edgesite-v${KUBEEDGE_VERSION}-linux-${ARCH}/edgesite/edgesite-agent" ./edgecore
chmod +x ./edgecore
rm "edgesite.tar.gz"
echo "✓ KubeEdge 边缘端包下载完成"

echo "[2/4] 下载 KubeEdge keadm..."
# KubeEdge 官方包名格式: keadm-v{version}-linux-{arch}.tar.gz
KEADM_URL="https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VERSION}/keadm-v${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "keadm.tar.gz" "$KEADM_URL"; then
  echo "错误：无法下载 KubeEdge keadm $KUBEEDGE_VERSION for $ARCH"
  echo "尝试的 URL: $KEADM_URL"
  exit 1
fi
tar -xzf "keadm.tar.gz"
# Extract keadm binary from the archive
cp "keadm-v${KUBEEDGE_VERSION}-linux-${ARCH}/keadm/keadm" ./keadm
chmod +x ./keadm
rm "keadm.tar.gz"
echo "✓ KubeEdge keadm 下载完成"

echo "[3/4] 下载 containerd 和 runc..."
# 确定 containerd 版本
CONTAINERD_VERSION="1.7.0"
RUNC_VERSION="1.1.9"

CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "containerd.tar.gz" "$CONTAINERD_URL"; then
  echo "警告：无法下载 containerd，尝试备用 URL"
  CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v1.6.0/containerd-1.6.0-linux-${ARCH}.tar.gz"
  wget -q -O "containerd.tar.gz" "$CONTAINERD_URL" || echo "警告：containerd 下载失败"
fi

if [ -f "containerd.tar.gz" ]; then
  tar -xzf "containerd.tar.gz"
  rm "containerd.tar.gz"
  echo "✓ containerd 下载完成"
fi

# 下载 runc
RUNC_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${ARCH}"
if ! wget -q -O "runc" "$RUNC_URL"; then
  echo "警告：无法下载 runc"
else
  chmod +x "runc"
  echo "✓ runc 下载完成"
fi

# 下载 CNI 插件
echo "[4/4] 下载 CNI 插件..."
CNI_VERSION="1.3.0"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-${ARCH}-v${CNI_VERSION}.tgz"
if ! wget -q -O "cni-plugins.tgz" "$CNI_URL"; then
  echo "Warning: Failed to download CNI plugins"
else
  mkdir -p cni-plugins
  tar -xzf "cni-plugins.tgz" -C cni-plugins
  rm "cni-plugins.tgz"
  echo "✓ CNI plugins downloaded"
fi

# Create configuration templates
mkdir -p config/kubeedge
cat > config/kubeedge/edgecore-config.yaml << 'EOF'
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
database:
  dataSource: /var/lib/kubeedge/edgecore.db
modules:
  edgeHub:
    enable: true
    heartbeat: 15
  edgeStream:
    enable: true
    handshakeTimeout: 5
    readDeadline: 15
    server: 127.0.0.1:10003
    tlsCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsCertFile: /etc/kubeedge/certs/edge.crt
    tlsPrivateKeyFile: /etc/kubeedge/certs/edge.key
    tlsEnable: true
  eventBus:
    enable: true
    eventBusType: default
  metaManager:
    enable: true
  deviceTwin:
    enable: true
  funcManager:
    enable: false
  imagePrependHostname: true
  surfaceManager:
    enable: false
EOF
echo "✓ Configuration template created"

# Create offline package
echo ""
echo "[5/4] Creating offline package..."
mkdir -p "$RELEASE_DIR"
PACKAGE_NAME="kubeedge-edge-${KUBEEDGE_VERSION}-${ARCH}.tar.gz"
# 获取install.sh的路径
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/install.sh"
if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "错误：找不到安装脚本 $INSTALL_SCRIPT"
  exit 1
fi
tar -czf "$RELEASE_DIR/$PACKAGE_NAME" \
  edgecore \
  keadm \
  runc \
  cni-plugins \
  config \
  -C "$(dirname "$INSTALL_SCRIPT")" install.sh
echo "✓ Package created: $RELEASE_DIR/$PACKAGE_NAME"

# Cleanup build directory
cd ..
rm -rf "$BUILD_DIR"

echo ""
echo "=== Build completed successfully ==="
echo "Package: $RELEASE_DIR/$PACKAGE_NAME"
echo "Size: $(du -h "$RELEASE_DIR/$PACKAGE_NAME" | cut -f1)"
echo ""
echo "To install:"
echo "  cd /path/to/extracted/package"
echo "  sudo ./install.sh <cloud-ip>:<cloud-port> <token> [optional-node-name]"
echo ""
