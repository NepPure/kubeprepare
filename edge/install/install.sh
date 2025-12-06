#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 边缘端离线安装脚本
# 用途: sudo ./install.sh <云端地址> <token> [可选-节点名称]
# 示例: sudo ./install.sh 192.168.1.100:10000 <token>
#       sudo ./install.sh 192.168.1.100:10000 <token> edge-node-1

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

CLOUD_ADDRESS="${1:-}"
EDGE_TOKEN="${2:-}"
NODE_NAME="${3:-$(hostname)}"
KUBEEDGE_VERSION="1.22.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/kubeedge-edge-install.log"

# 验证参数
if [ -z "$CLOUD_ADDRESS" ] || [ -z "$EDGE_TOKEN" ]; then
  echo "错误：缺少必需的参数"
  echo "用法: sudo ./install.sh <云端地址> <token> [可选-节点名称]"
  echo "示例: sudo ./install.sh 192.168.1.100:10000 <token>"
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

echo "=== KubeEdge 边缘端离线安装脚本 ===" | tee "$INSTALL_LOG"
echo "架构: $ARCH" | tee -a "$INSTALL_LOG"
echo "云端地址: $CLOUD_ADDRESS" | tee -a "$INSTALL_LOG"
echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "KubeEdge 版本: $KUBEEDGE_VERSION" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# Find binaries
echo "[1/6] Locating binaries..." | tee -a "$INSTALL_LOG"
EDGECORE_BIN=$(find "$SCRIPT_DIR" -name "edgecore" -type f 2>/dev/null | head -1)
KEADM_BIN=$(find "$SCRIPT_DIR" -name "keadm" -type f 2>/dev/null | head -1)

if [ -z "$EDGECORE_BIN" ] || [ -z "$KEADM_BIN" ]; then
  echo "Error: Required binaries not found in $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
  echo "  edgecore: $EDGECORE_BIN" | tee -a "$INSTALL_LOG"
  echo "  keadm: $KEADM_BIN" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "✓ Binaries located" | tee -a "$INSTALL_LOG"

# Check prerequisites
echo "[2/6] Checking prerequisites..." | tee -a "$INSTALL_LOG"
for cmd in systemctl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: $cmd not found. Cannot continue." | tee -a "$INSTALL_LOG"
    exit 1
  fi
done

# Check for containerd (optional, EdgeCore can use other container runtimes)
if ! command -v containerd &> /dev/null; then
  echo "Warning: containerd not found. Will attempt to install from offline package." | tee -a "$INSTALL_LOG"
  
  # Try to install containerd from package
  CONTAINERD_DIR=$(find "$SCRIPT_DIR" -type d -name "bin" 2>/dev/null | head -1)
  if [ -n "$CONTAINERD_DIR" ] && [ -f "$CONTAINERD_DIR/containerd" ]; then
    echo "Installing containerd from offline package..." | tee -a "$INSTALL_LOG"
    cp "$CONTAINERD_DIR/containerd" /usr/local/bin/
    cp "$CONTAINERD_DIR/containerd-shim-runc-v2" /usr/local/bin/
    cp "$CONTAINERD_DIR/ctr" /usr/local/bin/
    chmod +x /usr/local/bin/containerd*
    chmod +x /usr/local/bin/ctr
  fi
fi

echo "✓ Prerequisites checked" | tee -a "$INSTALL_LOG"

# Install runc
echo "[3/6] Installing runc..." | tee -a "$INSTALL_LOG"
RUNC_BIN=$(find "$SCRIPT_DIR" -name "runc" -type f 2>/dev/null | head -1)
if [ -n "$RUNC_BIN" ] && [ -f "$RUNC_BIN" ]; then
  cp "$RUNC_BIN" /usr/local/bin/runc
  chmod +x /usr/local/bin/runc
  echo "✓ runc installed" | tee -a "$INSTALL_LOG"
else
  echo "Warning: runc not found, will use system default" | tee -a "$INSTALL_LOG"
fi

# Install CNI plugins
echo "[4/6] Installing CNI plugins..." | tee -a "$INSTALL_LOG"
CNI_DIR=$(find "$SCRIPT_DIR" -type d -name "cni-plugins" 2>/dev/null | head -1)
if [ -n "$CNI_DIR" ] && [ -d "$CNI_DIR" ]; then
  mkdir -p /opt/cni/bin
  cp "$CNI_DIR"/* /opt/cni/bin/ || true
  chmod +x /opt/cni/bin/*
  echo "✓ CNI plugins installed" | tee -a "$INSTALL_LOG"
else
  echo "Warning: CNI plugins not found" | tee -a "$INSTALL_LOG"
fi

# Install EdgeCore
echo "[5/6] Installing EdgeCore..." | tee -a "$INSTALL_LOG"
cp "$EDGECORE_BIN" /usr/local/bin/edgecore
chmod +x /usr/local/bin/edgecore

# Create kubeedge directories
mkdir -p /etc/kubeedge
mkdir -p /var/lib/kubeedge
mkdir -p /var/log/kubeedge

# Copy configuration
CONFIG_DIR=$(find "$SCRIPT_DIR" -type d -name "kubeedge" 2>/dev/null | head -1)
if [ -n "$CONFIG_DIR" ] && [ -d "$CONFIG_DIR" ]; then
  cp "$CONFIG_DIR"/edgecore-config.yaml /etc/kubeedge/edgecore.yaml || true
fi

# Create edgecore service
cat > /etc/systemd/system/edgecore.service << EOF
[Unit]
Description=KubeEdge EdgeCore
Documentation=https://kubeedge.io
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/edgecore --config=/etc/kubeedge/edgecore.yaml
KillMode=process
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=edgecore

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "✓ EdgeCore installed" | tee -a "$INSTALL_LOG"

# Install keadm
echo "[6/6] Setting up edge node configuration..." | tee -a "$INSTALL_LOG"
cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# Join edge node to cluster
echo "Joining edge node to KubeEdge cluster..." | tee -a "$INSTALL_LOG"

# Parse cloud address
if [[ "$CLOUD_ADDRESS" == *":"* ]]; then
  CLOUD_IP="${CLOUD_ADDRESS%%:*}"
  CLOUD_PORT="${CLOUD_ADDRESS##*:}"
else
  CLOUD_IP="$CLOUD_ADDRESS"
  CLOUD_PORT="10000"
fi

# Update edgecore config with cloud address
if [ -f /etc/kubeedge/edgecore.yaml ]; then
  sed -i "s|server: .*|server: ${CLOUD_IP}:${CLOUD_PORT}|g" /etc/kubeedge/edgecore.yaml || true
fi

# Try to join using keadm
if "$KEADM_BIN" join --cloudcore-ipport="${CLOUD_IP}:${CLOUD_PORT}" --edgenode-name="$NODE_NAME" --kubeedge-version="v${KUBEEDGE_VERSION}" 2>&1 | tee -a "$INSTALL_LOG"; then
  echo "✓ Edge node configuration completed" | tee -a "$INSTALL_LOG"
else
  echo "Warning: keadm join returned non-zero, but continuing..." | tee -a "$INSTALL_LOG"
fi

# Enable and start edgecore service
systemctl enable edgecore
systemctl restart edgecore

# Wait for edgecore to start
echo "Waiting for EdgeCore to start..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if systemctl is-active --quiet edgecore; then
    echo "✓ EdgeCore is running" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "Waiting... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

if ! systemctl is-active --quiet edgecore; then
  echo "Warning: EdgeCore may not be running properly" | tee -a "$INSTALL_LOG"
  echo "Check status with: systemctl status edgecore" | tee -a "$INSTALL_LOG"
fi

echo "" | tee -a "$INSTALL_LOG"
echo "=== Installation completed ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== Edge Node Information ===" | tee -a "$INSTALL_LOG"
echo "Node Name: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "Cloud IP: $CLOUD_IP" | tee -a "$INSTALL_LOG"
echo "Cloud Port: $CLOUD_PORT" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== Service Status ===" | tee -a "$INSTALL_LOG"
echo "EdgeCore service status:" | tee -a "$INSTALL_LOG"
systemctl status edgecore 2>&1 | head -10 | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== Next Steps ===" | tee -a "$INSTALL_LOG"
echo "1. Verify EdgeCore is running:" | tee -a "$INSTALL_LOG"
echo "   systemctl status edgecore" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "2. Check EdgeCore logs:" | tee -a "$INSTALL_LOG"
echo "   journalctl -u edgecore -f" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "3. On cloud node, verify edge node is connected:" | tee -a "$INSTALL_LOG"
echo "   kubectl get nodes" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "Installation log: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
