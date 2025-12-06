#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo ./offline_install.sh <offline-package-path> <cloud_url> <token> [node_name]
# Example: sudo ./offline_install.sh /root/kubeedge-edge-offline-v1.22.tar.gz "wss://10.0.0.1:10000/edge/node01" "mytoken" node01

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

if [ $# -lt 3 ]; then
  echo "Usage: $0 <offline-package-path> <cloud_url> <token> [node_name]"
  exit 2
fi

PKG_PATH="$1"
CLOUD_URL="$2"
TOKEN="$3"
NODE_NAME="${4:-$(hostname -s)}"

WORKDIR="/tmp/kubeedge_offline_install_$$"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "Extracting package: $PKG_PATH"
tar -zxf "$PKG_PATH" -C .

# Expect to find: bin/edgecore, containerd/bin/*, cni/bin/*, etc/edgecore.yaml.tmpl
if [ ! -f "bin/edgecore" ]; then
  echo "edgecore binary not found in package"
  exit 3
fi

# 1) Install containerd and runc
echo "Installing containerd and runc..."

mkdir -p /usr/local/bin
# copy any containerd/bin/* or top-level bins if present
if [ -d "containerd/bin" ]; then
  cp -r containerd/bin/* /usr/local/bin/ || true
else
  # some packages may have bin/ directly
  if [ -d "bin" ]; then
    cp -r bin/* /usr/local/bin/ || true
  fi
fi

# If runc exists in containerd/bin it is copied above; otherwise check for containerd/bin/runc
if [ -f "/usr/local/bin/runc" ]; then
  chmod +x /usr/local/bin/runc
fi

# Install containerd systemd unit if not present
if ! command -v containerd >/dev/null 2>&1; then
  if [ -f "/usr/local/bin/containerd" ]; then
    echo "containerd installed to /usr/local/bin/containerd"
  else
    echo "Warning: containerd binary not found. If you already have a container runtime installed, skip this."
  fi
fi

# 2) Install CNI plugins
mkdir -p /opt/cni/bin
if [ -d "cni/bin" ]; then
  cp -r cni/bin/* /opt/cni/bin/ || true
fi

# 3) Configure containerd default config if not exists
if [ ! -f "/etc/containerd/config.toml" ]; then
  if command -v containerd >/dev/null 2>&1; then
    echo "Generating /etc/containerd/config.toml"
    containerd config default > /etc/containerd/config.toml || true
    # Try to adjust to runc v2 if present
    if grep -q "io.containerd.runc.v2" /etc/containerd/config.toml 2>/dev/null; then
      echo "containerd runtime seems OK"
    fi
  fi
fi

# 4) Install edgecore
mkdir -p /usr/local/bin /etc/kubeedge/config
cp bin/edgecore /usr/local/bin/
chmod +x /usr/local/bin/edgecore

# 5) Prepare edgecore.yaml by replacing placeholders
TEMPLATE="etc/edgecore.yaml.tmpl"
TARGET="/etc/kubeedge/config/edgecore.yaml"

if [ -f "$TEMPLATE" ]; then
  echo "Preparing edgecore config from template"
  sed "s#__CLOUD_URL__#${CLOUD_URL}#g;s#__TOKEN__#${TOKEN}#g;s#__NODE_NAME__#${NODE_NAME}#g" "$TEMPLATE" > "$TARGET"
else
  echo "No template found, trying to generate minimal config via edgecore --minconfig"
  /usr/local/bin/edgecore --minconfig > "$TARGET" || true
  # insert/patch required fields
  # Use a simple replacement approach (append values)
  cat >> "$TARGET" <<YAML

# patched by offline_install.sh
edgeHub:
  websocket:
    url: "${CLOUD_URL}"
  token: "${TOKEN}"
modules:
  edged:
    hostnameOverride: "${NODE_NAME}"
YAML
fi

# 6) Create systemd unit for edgecore
cat > /etc/systemd/system/edgecore.service <<SYSTEMD
[Unit]
Description=KubeEdge EdgeCore
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/edgecore --config /etc/kubeedge/config/edgecore.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable edgecore || true
systemctl restart edgecore || true

echo "edgecore service started. Check status with: systemctl status edgecore -l"

# 7) Suggest containerd systemd service start if containerd is installed
if command -v containerd >/dev/null 2>&1; then
  systemctl enable containerd || true
  systemctl restart containerd || true
  echo "containerd enabled & restarted"
fi

# Cleanup
rm -rf "$WORKDIR"

echo "Installation finished. 在 CloudCore 上检查节点是否加入： kubectl get nodes (在 cloud/k8s 控制面上)"
