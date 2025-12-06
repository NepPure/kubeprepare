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
NODE_NAME="${3:-}"
KUBEEDGE_VERSION="1.22.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/kubeedge-edge-install.log"

# 验证参数
if [ -z "$CLOUD_ADDRESS" ] || [ -z "$EDGE_TOKEN" ] || [ -z "$NODE_NAME" ]; then
  echo "错误：缺少必需的参数"
  echo "用法: sudo ./install.sh <云端地址> <token> <节点名称>"
  echo "示例: sudo ./install.sh 192.168.1.100:10000 <token> edge-node-1"
  exit 1
fi

# 校验 nodename 合法性（小写、字母数字、-、.，且首尾为字母数字）
if ! [[ "$NODE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]; then
  echo "错误：节点名称 '$NODE_NAME' 不符合 RFC 1123 规范，必须为小写字母、数字、'-'或'.'，且首尾为字母数字。"
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


# Install systemd service dir variable early for MQTT and EdgeCore
SYSTEMD_DIR=$(find "$SCRIPT_DIR" -type d -name "systemd" 2>/dev/null | head -1)

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
mkdir -p /etc/kubeedge/ca
mkdir -p /etc/kubeedge/certs

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

# Configure edge node (完全离线模式 - 直接生成完整配置)
echo "Configuring edge node for KubeEdge cluster..." | tee -a "$INSTALL_LOG"

# Parse cloud address
if [[ "$CLOUD_ADDRESS" == *":"* ]]; then
  CLOUD_IP="${CLOUD_ADDRESS%%:*}"
  CLOUD_PORT="${CLOUD_ADDRESS##*:}"
else
  CLOUD_IP="$CLOUD_ADDRESS"
  CLOUD_PORT="10000"
fi

# 直接生成完整的 edgecore.yaml 配置文件（符合 KubeEdge v1alpha2 官方标准）
echo "  Generating edgecore configuration..." | tee -a "$INSTALL_LOG"
cat > /etc/kubeedge/edgecore.yaml << 'EOF'
apiVersion: edgecore.config.kubeedge.io/v1alpha2
kind: EdgeCore
database:
  aliasName: default
  dataSource: /var/lib/kubeedge/edgecore.db
  driverName: sqlite3
modules:
  dbTest:
    enable: false
  deviceTwin:
    dmiSockPath: /etc/kubeedge/dmi.sock
    enable: true
  edgeHub:
    enable: true
    heartbeat: 15
    httpServer: https://CLOUD_IP_PLACEHOLDER:CLOUD_PORT_PLACEHOLDER
    messageBurst: 60
    messageQPS: 30
    projectID: e632aba927ea4ac2b575ec1603d56f10
    quic:
      enable: false
      handshakeTimeout: 30
      readDeadline: 15
      server: CLOUD_IP_PLACEHOLDER:10001
      writeDeadline: 15
    rotateCertificates: true
    tlsCaFile: /etc/kubeedge/ca/rootCA.crt
    tlsCertFile: /etc/kubeedge/certs/server.crt
    tlsPrivateKeyFile: /etc/kubeedge/certs/server.key
    token: "TOKEN_PLACEHOLDER"
    websocket:
      enable: true
      handshakeTimeout: 30
      readDeadline: 15
      server: CLOUD_IP_PLACEHOLDER:CLOUD_PORT_PLACEHOLDER
      writeDeadline: 15
  edgeStream:
    enable: true
    handshakeTimeout: 30
    readDeadline: 15
    server: CLOUD_IP_PLACEHOLDER:10003
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    writeDeadline: 15
  edged:
    enable: true
    hostnameOverride: NODE_NAME_PLACEHOLDER
    maxContainerCount: -1
    maxPerPodContainerCount: 1
    minimumGCAge: 0s
    podSandboxImage: kubeedge/pause:3.6
    registerNodeNamespace: default
    registerSchedulable: true
    tailoredKubeletConfig:
      address: 127.0.0.1
      cgroupDriver: cgroupfs
      cgroupsPerQOS: true
      clusterDNS: ""
      clusterDomain: cluster.local
      containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
      contentType: application/json
      enableDebuggingHandlers: true
      evictionHard:
        imagefs.available: 15%
        memory.available: 100Mi
        nodefs.available: 10%
        nodefs.inodesFree: 5%
      evictionPressureTransitionPeriod: 5m0s
      failSwapOn: false
      imageGCHighThresholdPercent: 85
      imageGCLowThresholdPercent: 80
      imageServiceEndpoint: unix:///run/containerd/containerd.sock
      maxPods: 110
      podLogsDir: /var/log/pods
      registerNode: true
      rotateCertificates: true
      serializeImagePulls: true
      staticPodPath: /etc/kubeedge/manifests
  eventBus:
    enable: true
    eventBusTLS:
      enable: false
      tlsMqttCAFile: /etc/kubeedge/ca/rootCA.crt
      tlsMqttCertFile: /etc/kubeedge/certs/server.crt
      tlsMqttPrivateKeyFile: /etc/kubeedge/certs/server.key
    mqttMode: 2
    mqttQOS: 0
    mqttRetain: false
    mqttServerExternal: tcp://127.0.0.1:1883
    mqttServerInternal: tcp://127.0.0.1:1884
    mqttSessionQueueSize: 100
  metaManager:
    contextSendGroup: hub
    contextSendModule: websocket
    enable: true
    metaServer:
      enable: false
      server: 127.0.0.1:10550
    remoteQueryTimeout: 60
  serviceBus:
    enable: false
  taskManager:
    enable: false
EOF

# 替换配置文件中的占位符为实际值
sed -i "s|CLOUD_IP_PLACEHOLDER|${CLOUD_IP}|g" /etc/kubeedge/edgecore.yaml
sed -i "s|CLOUD_PORT_PLACEHOLDER|${CLOUD_PORT}|g" /etc/kubeedge/edgecore.yaml
sed -i "s|NODE_NAME_PLACEHOLDER|${NODE_NAME}|g" /etc/kubeedge/edgecore.yaml
sed -i "s|TOKEN_PLACEHOLDER|${EDGE_TOKEN}|g" /etc/kubeedge/edgecore.yaml

echo "  ✓ EdgeCore configuration generated" | tee -a "$INSTALL_LOG"

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
