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

# Verify offline package metadata
META_DIR=$(find "$SCRIPT_DIR" -type d -name "meta" 2>/dev/null | head -1)
if [ -n "$META_DIR" ] && [ -f "$META_DIR/version.txt" ]; then
  echo "离线包信息:" | tee -a "$INSTALL_LOG"
  cat "$META_DIR/version.txt" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
fi

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

# Deploy Mosquitto MQTT Broker for IoT devices
echo "[4.5/6] Deploying Mosquitto MQTT Broker for IoT devices..." | tee -a "$INSTALL_LOG"
IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
MQTT_DEPLOYED=false

if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
  MQTT_IMAGE_TAR=$(find "$IMAGES_DIR" -name "*mosquitto*.tar" -type f 2>/dev/null | head -1)
  
  if [ -n "$MQTT_IMAGE_TAR" ] && [ -f "$MQTT_IMAGE_TAR" ]; then
    echo "  导入 Mosquitto MQTT 镜像..." | tee -a "$INSTALL_LOG"
    
    # 确保 containerd 正在运行
    if ! systemctl is-active --quiet containerd 2>/dev/null; then
      echo "    启动 containerd..." | tee -a "$INSTALL_LOG"
      systemctl start containerd || echo "    警告: 无法启动 containerd" | tee -a "$INSTALL_LOG"
      sleep 2
    fi
    
    # 导入镜像到 containerd
    if command -v ctr &> /dev/null; then
      if ctr -n k8s.io images import "$MQTT_IMAGE_TAR" >> "$INSTALL_LOG" 2>&1; then
        echo "  ✓ MQTT 镜像已导入到 containerd" | tee -a "$INSTALL_LOG"
        
        # 安装 mosquitto systemd service
        if [ -n "$SYSTEMD_DIR" ] && [ -f "$SYSTEMD_DIR/mosquitto.service" ]; then
          cp "$SYSTEMD_DIR/mosquitto.service" /etc/systemd/system/mosquitto.service
          systemctl daemon-reload
          systemctl enable mosquitto
          systemctl start mosquitto
          
          # 等待 MQTT 启动
          echo "    等待 MQTT broker 启动..." | tee -a "$INSTALL_LOG"
          for i in {1..10}; do
            if systemctl is-active --quiet mosquitto; then
              echo "  ✓ MQTT Broker 已启动 (localhost:1883)" | tee -a "$INSTALL_LOG"
              MQTT_DEPLOYED=true
              break
            fi
            sleep 1
          done
          
          if ! $MQTT_DEPLOYED; then
            echo "  ⚠️  MQTT 启动超时,请检查: systemctl status mosquitto" | tee -a "$INSTALL_LOG"
          fi
        else
          echo "  ⚠️  mosquitto.service 模板未找到" | tee -a "$INSTALL_LOG"
        fi
      else
        echo "  ⚠️  MQTT 镜像导入失败" | tee -a "$INSTALL_LOG"
      fi
    else
      echo "  ⚠️  ctr 命令未找到,无法导入 MQTT 镜像" | tee -a "$INSTALL_LOG"
    fi
  else
    echo "  ⚠️  MQTT 镜像未在离线包中找到" | tee -a "$INSTALL_LOG"
  fi
else
  echo "  ⚠️  images 目录未找到" | tee -a "$INSTALL_LOG"
fi

if ! $MQTT_DEPLOYED; then
  echo "  注意: MQTT broker 未部署,设备管理功能将不可用" | tee -a "$INSTALL_LOG"
  echo "  可以稍后手动部署: systemctl start mosquitto" | tee -a "$INSTALL_LOG"
fi

# Install EdgeCore
echo "[5/6] Installing EdgeCore..." | tee -a "$INSTALL_LOG"
cp "$EDGECORE_BIN" /usr/local/bin/edgecore
chmod +x /usr/local/bin/edgecore

# Create kubeedge directories
mkdir -p /etc/kubeedge
mkdir -p /var/lib/kubeedge
mkdir -p /var/log/kubeedge

# Copy configuration from offline package
CONFIG_DIR=$(find "$SCRIPT_DIR" -type d -name "kubeedge" 2>/dev/null | head -1)
if [ -n "$CONFIG_DIR" ] && [ -d "$CONFIG_DIR" ]; then
  if [ -f "$CONFIG_DIR/edgecore-config.yaml" ]; then
    cp "$CONFIG_DIR/edgecore-config.yaml" /etc/kubeedge/edgecore.yaml || true
    echo "  ✓ 使用离线包中的配置文件" | tee -a "$INSTALL_LOG"
  fi
fi

# Install systemd service from offline package (优先使用离线包)
SYSTEMD_DIR=$(find "$SCRIPT_DIR" -type d -name "systemd" 2>/dev/null | head -1)
if [ -n "$SYSTEMD_DIR" ] && [ -f "$SYSTEMD_DIR/edgecore.service" ]; then
  echo "  使用离线包中的 systemd service 文件..." | tee -a "$INSTALL_LOG"
  cp "$SYSTEMD_DIR/edgecore.service" /etc/systemd/system/edgecore.service
  echo "  ✓ systemd service 已从离线包安装" | tee -a "$INSTALL_LOG"
else
  echo "  离线包中未找到 service 文件，创建默认配置..." | tee -a "$INSTALL_LOG"
  # 如果离线包中没有，则创建默认的
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
fi

systemctl daemon-reload
echo "✓ EdgeCore installed" | tee -a "$INSTALL_LOG"

# Install keadm
echo "[6/6] Setting up edge node configuration..." | tee -a "$INSTALL_LOG"
cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# Configure edge node (完全离线模式)
echo "Configuring edge node for KubeEdge cluster..." | tee -a "$INSTALL_LOG"

# Parse cloud address
if [[ "$CLOUD_ADDRESS" == *":"* ]]; then
  CLOUD_IP="${CLOUD_ADDRESS%%:*}"
  CLOUD_PORT="${CLOUD_ADDRESS##*:}"
else
  CLOUD_IP="$CLOUD_ADDRESS"
  CLOUD_PORT="10000"
fi

# Update edgecore config with cloud address and node name
if [ -f /etc/kubeedge/edgecore.yaml ]; then
  echo "  Updating edgecore configuration..." | tee -a "$INSTALL_LOG"
  sed -i "s|server: .*|server: ${CLOUD_IP}:${CLOUD_PORT}|g" /etc/kubeedge/edgecore.yaml || true
  sed -i "s|hostnameOverride: .*|hostnameOverride: ${NODE_NAME}|g" /etc/kubeedge/edgecore.yaml || true
  echo "  ✓ Configuration updated" | tee -a "$INSTALL_LOG"
else
  echo "  Warning: edgecore.yaml not found, creating minimal config..." | tee -a "$INSTALL_LOG"
  
  # Create minimal edgecore config if not exists
  cat > /etc/kubeedge/edgecore.yaml << EDGECONFIG
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
database:
  dataSource: /var/lib/kubeedge/edgecore.db
modules:
  edgeHub:
    enable: true
    heartbeat: 15
    httpServer: https://${CLOUD_IP}:${CLOUD_PORT}
    websocket:
      enable: true
      server: ${CLOUD_IP}:${CLOUD_PORT}
  edged:
    enable: true
    hostnameOverride: ${NODE_NAME}
    nodeIP: 
  edgeStream:
    enable: true
    handshakeTimeout: 30
    readDeadline: 15
    server: ${CLOUD_IP}:10003
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    writeDeadline: 15
  eventBus:
    enable: true
    mqttMode: 2
    mqttServerExternal: tcp://127.0.0.1:1883
    mqttServerInternal: tcp://127.0.0.1:1884
  metaManager:
    enable: true
    metaServer:
      enable: true
  serviceBus:
    enable: false
EDGECONFIG
  echo "  ✓ Minimal configuration created" | tee -a "$INSTALL_LOG"
fi

echo "✓ Edge node configuration completed (offline mode)" | tee -a "$INSTALL_LOG"
echo "  Note: Using local configuration only, no network access required" | tee -a "$INSTALL_LOG"

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
