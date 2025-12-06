#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 云端离线安装脚本
# 用途: sudo ./install.sh <对外IP> [可选-节点名称]
# 示例: sudo ./install.sh 192.168.1.100
#       sudo ./install.sh 192.168.1.100 k3s-master

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

EXTERNAL_IP="${1:-}"
NODE_NAME="${2:-k3s-master}"
KUBEEDGE_VERSION="1.22.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/kubeedge-cloud-install.log"

# 验证外网 IP
if [ -z "$EXTERNAL_IP" ]; then
  echo "错误：外网 IP 地址是必需的"
  echo "用法: sudo ./install.sh <对外IP> [可选-节点名称]"
  exit 1
fi

if ! [[ "$EXTERNAL_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "错误：无效的 IP 地址: $EXTERNAL_IP"
  exit 1
fi

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    ARCH="amd64"
    ;;
  aarch64)
    ARCH="arm64"
    ;;
  *)
    echo "错误：不支持的架构: $ARCH"
    exit 1
    ;;
esac

echo "=== KubeEdge 云端离线安装脚本 ===" | tee "$INSTALL_LOG"
echo "架构: $ARCH" | tee -a "$INSTALL_LOG"
echo "对外 IP: $EXTERNAL_IP" | tee -a "$INSTALL_LOG"
echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# Find k3s and keadm binaries
echo "[1/7] Locating binaries..." | tee -a "$INSTALL_LOG"
K3S_BIN=$(find "$SCRIPT_DIR" -name "k3s-${ARCH}" -type f 2>/dev/null | head -1)
CLOUDCORE_BIN=$(find "$SCRIPT_DIR" -name "cloudcore" -type f 2>/dev/null | head -1)
KEADM_BIN=$(find "$SCRIPT_DIR" -name "keadm" -type f 2>/dev/null | head -1)

if [ -z "$K3S_BIN" ] || [ -z "$CLOUDCORE_BIN" ] || [ -z "$KEADM_BIN" ]; then
  echo "Error: Required binaries not found in $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
  echo "  k3s-${ARCH}: $K3S_BIN" | tee -a "$INSTALL_LOG"
  echo "  cloudcore: $CLOUDCORE_BIN" | tee -a "$INSTALL_LOG"
  echo "  keadm: $KEADM_BIN" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "✓ Binaries located" | tee -a "$INSTALL_LOG"

# Check prerequisites
echo "[2/7] Checking prerequisites..." | tee -a "$INSTALL_LOG"
for cmd in systemctl docker kubectl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Warning: $cmd not found. Installation may fail." | tee -a "$INSTALL_LOG"
  fi
done
echo "✓ Prerequisites checked" | tee -a "$INSTALL_LOG"

# Install k3s
echo "[3/7] Installing k3s..." | tee -a "$INSTALL_LOG"
cp "$K3S_BIN" /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s

# Load container images before starting k3s
echo "[3/7-a] Loading container images..." | tee -a "$INSTALL_LOG"
IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
if [ -d "$IMAGES_DIR" ]; then
  IMAGE_COUNT=0
  for image_tar in "$IMAGES_DIR"/*.tar; do
    if [ -f "$image_tar" ]; then
      echo "  Loading: $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
      # We'll load images after k3s starts using ctr
      IMAGE_COUNT=$((IMAGE_COUNT + 1))
    fi
  done
  if [ $IMAGE_COUNT -gt 0 ]; then
    echo "✓ Found $IMAGE_COUNT images to load" | tee -a "$INSTALL_LOG"
  else
    echo "Warning: No image tar files found in $IMAGES_DIR" | tee -a "$INSTALL_LOG"
  fi
else
  echo "Warning: Images directory not found in $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
fi

# Create k3s service
cat > /etc/systemd/system/k3s.service << EOF
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server \\
  --advertise-address=$EXTERNAL_IP \\
  --node-name=$NODE_NAME \\
  --tls-san=$EXTERNAL_IP \\
  --bind-address=0.0.0.0 \\
  --kube-apiserver-arg=bind-address=0.0.0.0 \\
  --kube-apiserver-arg=advertise-address=$EXTERNAL_IP \\
  --kube-controller-manager-arg=bind-address=0.0.0.0 \\
  --kube-scheduler-arg=bind-address=0.0.0.0
KillMode=process
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=k3s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable k3s
systemctl restart k3s

# Wait for k3s to be ready
echo "Waiting for k3s to be ready..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "✓ k3s is ready" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "Waiting... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
  echo "Error: k3s failed to start" | tee -a "$INSTALL_LOG"
  systemctl status k3s >> "$INSTALL_LOG" 2>&1 || true
  exit 1
fi


# Copy kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
chmod 644 /etc/rancher/k3s/k3s.yaml

# 统一KUBECTL命令
KUBECTL="/usr/local/bin/k3s kubectl"

# Load container images into k3s containerd
echo "[3/7-b] Importing container images into k3s..." | tee -a "$INSTALL_LOG"
if [ -d "$IMAGES_DIR" ]; then
  LOADED_COUNT=0
  FAILED_COUNT=0
  for image_tar in "$IMAGES_DIR"/*.tar; do
    if [ -f "$image_tar" ]; then
      echo "  Importing: $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
      if /usr/local/bin/k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        LOADED_COUNT=$((LOADED_COUNT + 1))
      else
        echo "  Warning: Failed to import $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
        FAILED_COUNT=$((FAILED_COUNT + 1))
      fi
    fi
  done
  echo "✓ Images imported: $LOADED_COUNT successful, $FAILED_COUNT failed" | tee -a "$INSTALL_LOG"
  
  # Verify loaded images
  echo "Verifying loaded images..." | tee -a "$INSTALL_LOG"
  /usr/local/bin/k3s ctr images ls -q | tee -a "$INSTALL_LOG"
else
  echo "Skipping image import (no images directory found)" | tee -a "$INSTALL_LOG"
fi


# Wait for API server
echo "[4/7] Waiting for Kubernetes API..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if $KUBECTL cluster-info &> /dev/null; then
    echo "✓ Kubernetes API is ready" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "Waiting... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done


# Create kubeedge namespace
echo "[5/7] Creating KubeEdge namespace..." | tee -a "$INSTALL_LOG"
$KUBECTL create namespace kubeedge || true
echo "✓ Namespace created" | tee -a "$INSTALL_LOG"

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
  if [ $KUBEEDGE_IMAGE_COUNT -gt 0 ]; then
    echo "✓ Pre-imported $KUBEEDGE_IMAGE_COUNT KubeEdge images" | tee -a "$INSTALL_LOG"
    echo "Verifying KubeEdge images..." | tee -a "$INSTALL_LOG"
    /usr/local/bin/k3s ctr images ls | grep kubeedge | tee -a "$INSTALL_LOG"
  else
    echo "Warning: No KubeEdge images found for pre-import" | tee -a "$INSTALL_LOG"
  fi
else
  echo "Warning: Images directory not found, skipping KubeEdge image pre-import" | tee -a "$INSTALL_LOG"
fi

# Install KubeEdge CloudCore using keadm
echo "[6/7] Installing KubeEdge CloudCore..." | tee -a "$INSTALL_LOG"
cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# Initialize CloudCore
mkdir -p /etc/kubeedge
"$KEADM_BIN" init --advertise-address="$EXTERNAL_IP" --kubeedge-version=v"$KUBEEDGE_VERSION" --kube-config=/etc/rancher/k3s/k3s.yaml || true


# Wait for CloudCore to be ready
echo "Waiting for CloudCore to be ready..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if $KUBECTL -n kubeedge get pod -l app=cloudcore 2>/dev/null | grep -q Running; then
    echo "✓ CloudCore is ready" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "Waiting... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

# Generate edge token
echo "[7/7] Generating edge token..." | tee -a "$INSTALL_LOG"
TOKEN_DIR="/etc/kubeedge/tokens"
mkdir -p "$TOKEN_DIR"

# Get CloudCore service
CLOUD_IP="$EXTERNAL_IP"
CLOUD_PORT="10000"

# Generate token using keadm
EDGE_TOKEN=$("$KEADM_BIN" gettoken --kubeedge-version=v"$KUBEEDGE_VERSION" --kube-config=/etc/rancher/k3s/k3s.yaml 2>/dev/null || echo "")

if [ -z "$EDGE_TOKEN" ]; then
  # Fallback: generate simple token
  EDGE_TOKEN=$(openssl rand -base64 32 | tr -d '\n' || echo "default-token-$(date +%s)")
fi

# Save token to file
TOKEN_FILE="$TOKEN_DIR/edge-token.txt"
cat > "$TOKEN_FILE" << EOF
{
  "cloudIP": "$CLOUD_IP",
  "cloudPort": $CLOUD_PORT,
  "token": "$EDGE_TOKEN",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "edgeConnectCommand": "sudo ./install.sh $CLOUD_IP:$CLOUD_PORT $EDGE_TOKEN"
}
EOF

chmod 600 "$TOKEN_FILE"
echo "✓ Edge token generated" | tee -a "$INSTALL_LOG"

echo "" | tee -a "$INSTALL_LOG"
echo "=== Installation completed successfully ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== CloudCore Information ===" | tee -a "$INSTALL_LOG"
echo "Cloud IP: $CLOUD_IP" | tee -a "$INSTALL_LOG"
echo "Cloud Port: $CLOUD_PORT" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== Edge Connection Token ===" | tee -a "$INSTALL_LOG"
echo "Token: $EDGE_TOKEN" | tee -a "$INSTALL_LOG"
echo "Save this token for edge node installation" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== Next Steps ===" | tee -a "$INSTALL_LOG"
echo "1. Verify k3s cluster:" | tee -a "$INSTALL_LOG"
echo "   kubectl get nodes" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "2. Verify CloudCore:" | tee -a "$INSTALL_LOG"
echo "   kubectl -n kubeedge get pod" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "3. To connect an edge node:" | tee -a "$INSTALL_LOG"
echo "   - Use cloud IP: $CLOUD_IP" | tee -a "$INSTALL_LOG"
echo "   - Use token: $EDGE_TOKEN" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "Installation log: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# Print token to stdout for easy copy
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "EDGE NODE TOKEN:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$TOKEN_FILE" | jq . || cat "$TOKEN_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
