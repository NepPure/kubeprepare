#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 云端离线包构建脚本
# 用途: ./build.sh <架构> [版本]
# 支持的架构: amd64, arm64
# 示例: ./build.sh amd64
#       ./build.sh arm64 1.22.0

ARCH="${1:-amd64}"
K3S_VERSION="${2:-v1.34.2+k3s1}"
KUBEEDGE_VERSION="1.22.0"
BUILD_DIR="$(pwd)/cloud-${ARCH}-build"
RELEASE_DIR="$(pwd)/../release"

# Validate architecture
if [[ ! "$ARCH" =~ ^(amd64|arm64)$ ]]; then
  echo "Error: Unsupported architecture: $ARCH"
  echo "Supported: amd64, arm64"
  exit 1
fi

echo "=== KubeEdge 云端离线包构建器 ==="
echo "架构: $ARCH"
echo "K3S 版本: $K3S_VERSION"
echo "KubeEdge 版本: $KUBEEDGE_VERSION"
echo ""

# 创建构建目录
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[1/5] 下载 k3s 二进制文件..."
K3S_ARCH="$ARCH"
if [ "$ARCH" = "arm64" ]; then
  K3S_ARCH="arm64"
else
  K3S_ARCH="amd64"
fi

# k3s amd64 没有后缀，arm64 有后缀
if [ "$K3S_ARCH" = "amd64" ]; then
  K3S_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s"
else
  K3S_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-${K3S_ARCH}"
fi

if ! wget -q -O "k3s-${ARCH}" "$K3S_URL"; then
  echo "错误：无法下载 k3s $K3S_VERSION for $ARCH"
  echo "尝试的 URL: $K3S_URL"
  exit 1
fi
chmod +x "k3s-${ARCH}"
echo "✓ k3s 下载完成"

echo "[2/5] 下载 KubeEdge 云端包..."
# KubeEdge 官方云端包名格式: kubeedge-v{version}-linux-{arch}.tar.gz
KUBEEDGE_URL="https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VERSION}/kubeedge-v${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "kubeedge.tar.gz" "$KUBEEDGE_URL"; then
  echo "错误：无法下载 KubeEdge 云端包 $KUBEEDGE_VERSION for $ARCH"
  echo "尝试的 URL: $KUBEEDGE_URL"
  exit 1
fi
tar -xzf "kubeedge.tar.gz"
rm "kubeedge.tar.gz"
echo "✓ KubeEdge 云端包下载完成"

echo "[3/5] 下载 KubeEdge keadm..."
# KubeEdge 官方包名格式: keadm-v{version}-linux-{arch}.tar.gz
KEADM_URL="https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VERSION}/keadm-v${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
if ! wget -q -O "keadm.tar.gz" "$KEADM_URL"; then
  echo "错误：无法下载 KubeEdge keadm $KUBEEDGE_VERSION for $ARCH"
  echo "尝试的 URL: $KEADM_URL"
  exit 1
fi
tar -xzf "keadm.tar.gz"
rm "keadm.tar.gz"
echo "✓ KubeEdge keadm 下载完成"

echo "[4/5] Creating configuration templates..."
mkdir -p config/kubeedge
cat > config/kubeedge/cloudcore-config.yaml << 'EOF'
apiVersion: cloudcore.config.kubeedge.io/v1alpha2
kind: CloudCore
kubeAPIConfig:
  kubeConfig: ""
  master: ""
  contentType: application/vnd.kubernetes.protobuf
  qps: 100
  burst: 200
databases:
  redis:
    enable: false
cloudHub:
  tlsCAFile: /etc/kubeedge/ca/rootCA.crt
  tlsCertFile: /etc/kubeedge/certs/server.crt
  tlsPrivateKeyFile: /etc/kubeedge/certs/server.key
  listenAddr: 0.0.0.0
  port: 10000
  protocol: websocket
  nodeLimit: 1000
cloudStream:
  enable: true
  streamPort: 10003
  tlsStreamCAFile: /etc/kubeedge/ca/rootCA.crt
  tlsStreamCertFile: /etc/kubeedge/certs/stream.crt
  tlsStreamPrivateKeyFile: /etc/kubeedge/certs/stream.key
  tlsEnable: true
authentication:
  address: 127.0.0.1:10003
modules:
  cloudHub:
    enable: true
  edgeController:
    enable: true
  deviceController:
    enable: true
    nodeStatusUpdateFrequency: 10
EOF
echo "✓ Configuration templates created"

echo "[5/5] Creating offline package..."
mkdir -p "$RELEASE_DIR"
PACKAGE_NAME="kubeedge-cloud-${KUBEEDGE_VERSION}-k3s-${K3S_VERSION}-${ARCH}.tar.gz"
tar -czf "$RELEASE_DIR/$PACKAGE_NAME" \
  "k3s-${ARCH}" \
  cloudcore \
  keadm \
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
echo "  sudo ./install.sh <external-ip> [optional-node-name]"
echo ""
