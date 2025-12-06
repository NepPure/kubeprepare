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
RELEASE_DIR="$(pwd)/../release"

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

echo "[1/4] Downloading KubeEdge EdgeCore binary..."
EDGECORE_URL="https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VERSION}/edgecore-${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "edgecore.tar.gz" "$EDGECORE_URL"; then
  echo "Error: Failed to download KubeEdge EdgeCore $KUBEEDGE_VERSION for $ARCH"
  exit 1
fi
tar -xzf "edgecore.tar.gz"
rm "edgecore.tar.gz"
echo "✓ KubeEdge EdgeCore downloaded"

echo "[2/4] Downloading KubeEdge keadm..."
KEADM_URL="https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VERSION}/keadm-${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "keadm.tar.gz" "$KEADM_URL"; then
  echo "Error: Failed to download KubeEdge keadm $KUBEEDGE_VERSION for $ARCH"
  exit 1
fi
tar -xzf "keadm.tar.gz"
rm "keadm.tar.gz"
echo "✓ KubeEdge keadm downloaded"

echo "[3/4] Downloading containerd and runc..."
# Determine containerd version
CONTAINERD_VERSION="1.7.0"
RUNC_VERSION="1.1.9"

CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "containerd.tar.gz" "$CONTAINERD_URL"; then
  echo "Warning: Failed to download containerd, trying alternative URL"
  CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v1.6.0/containerd-1.6.0-linux-${ARCH}.tar.gz"
  wget -q -O "containerd.tar.gz" "$CONTAINERD_URL" || echo "Warning: containerd download failed"
fi

if [ -f "containerd.tar.gz" ]; then
  tar -xzf "containerd.tar.gz"
  rm "containerd.tar.gz"
  echo "✓ containerd downloaded"
fi

# Download runc
RUNC_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${ARCH}"
if ! wget -q -O "runc" "$RUNC_URL"; then
  echo "Warning: Failed to download runc"
else
  chmod +x "runc"
  echo "✓ runc downloaded"
fi

# Download CNI plugins
echo "[4/4] Downloading CNI plugins..."
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
tar -czf "$RELEASE_DIR/$PACKAGE_NAME" \
  edgecore \
  keadm \
  runc \
  cni-plugins \
  config
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
