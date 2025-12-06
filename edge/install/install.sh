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

# Check for existing components
echo "[0/6] Checking for existing components..." | tee -a "$INSTALL_LOG"

HAS_EDGECORE=false
HAS_DOCKER=false
HAS_SYSTEM_CONTAINERD=false
USE_SYSTEM_CONTAINERD=false

# Check for existing EdgeCore
if [ -f /usr/local/bin/edgecore ] || systemctl list-units --full -all 2>/dev/null | grep -q "edgecore.service"; then
  HAS_EDGECORE=true
  echo "⚠️  警告: 检测到系统已安装 EdgeCore" | tee -a "$INSTALL_LOG"
  echo "   现有 EdgeCore 安装位置: /usr/local/bin/edgecore" | tee -a "$INSTALL_LOG"
  echo "   如需重新安装，请先运行清理脚本: sudo ./cleanup.sh" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  read -p "是否继续？这将覆盖现有安装 (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消安装" | tee -a "$INSTALL_LOG"
    exit 1
  fi
fi

# Check for Docker
if systemctl list-units --full -all 2>/dev/null | grep -q "docker.service" || command -v docker &> /dev/null; then
  HAS_DOCKER=true
  echo "❌ 错误: 检测到系统已安装 Docker" | tee -a "$INSTALL_LOG"
  echo "   Docker 使用自己的 containerd，与 EdgeCore 的 containerd 冲突" | tee -a "$INSTALL_LOG"
  echo "   Edge 节点不应同时运行 Docker 和 EdgeCore" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "请选择以下操作之一：" | tee -a "$INSTALL_LOG"
  echo "  1. 运行清理脚本卸载 Docker: sudo ./cleanup.sh" | tee -a "$INSTALL_LOG"
  echo "  2. 手动停止 Docker: sudo systemctl stop docker && sudo systemctl disable docker" | tee -a "$INSTALL_LOG"
  exit 1
fi

# Check for system-installed containerd
if command -v containerd &> /dev/null; then
  CONTAINERD_PATH=$(command -v containerd)
  HAS_SYSTEM_CONTAINERD=true
  echo "ℹ️  检测到系统已安装 containerd: $CONTAINERD_PATH" | tee -a "$INSTALL_LOG"
  
  # Check if it's from package manager
  if dpkg -l 2>/dev/null | grep -q "containerd.io" || rpm -qa 2>/dev/null | grep -q "containerd.io"; then
    echo "   来源: 系统包管理器 (apt/yum)" | tee -a "$INSTALL_LOG"
  else
    echo "   来源: 手动安装或其他方式" | tee -a "$INSTALL_LOG"
  fi
  
  # Check if containerd is running
  if systemctl is-active --quiet containerd 2>/dev/null; then
    echo "   状态: 正在运行" | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    echo "选项:" | tee -a "$INSTALL_LOG"
    echo "  1. 使用系统现有的 containerd (推荐，保持系统一致性)" | tee -a "$INSTALL_LOG"
    echo "  2. 覆盖为离线包的 containerd (可能导致版本不兼容)" | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    read -p "是否使用系统现有的 containerd？(Y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      USE_SYSTEM_CONTAINERD=true
      echo "✓ 将使用系统现有的 containerd: $CONTAINERD_PATH" | tee -a "$INSTALL_LOG"
    else
      echo "⚠️  将停止并覆盖系统 containerd" | tee -a "$INSTALL_LOG"
      systemctl stop containerd 2>/dev/null || true
    fi
  else
    echo "   状态: 未运行" | tee -a "$INSTALL_LOG"
    echo "   将使用系统现有的 containerd" | tee -a "$INSTALL_LOG"
    USE_SYSTEM_CONTAINERD=true
  fi
fi

echo "✓ Component check completed" | tee -a "$INSTALL_LOG"
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

# Install or use existing containerd
if [ "$USE_SYSTEM_CONTAINERD" = true ]; then
  echo "Using existing system containerd..." | tee -a "$INSTALL_LOG"
  CONTAINERD_BIN=$(command -v containerd)
  CTR_BIN=$(command -v ctr)
  echo "  containerd: $CONTAINERD_BIN" | tee -a "$INSTALL_LOG"
  echo "  ctr: $CTR_BIN" | tee -a "$INSTALL_LOG"
  
  # Check if containerd is running
  if ! systemctl is-active --quiet containerd; then
    echo "  Starting existing containerd service..." | tee -a "$INSTALL_LOG"
    systemctl start containerd || {
      echo "Error: Failed to start existing containerd" | tee -a "$INSTALL_LOG"
      exit 1
    }
  fi
  
  echo "✓ Using system containerd (will not modify system configuration)" | tee -a "$INSTALL_LOG"
  SKIP_CONTAINERD_INSTALL=true
else
  echo "Installing containerd from offline package..." | tee -a "$INSTALL_LOG"
  CONTAINERD_DIR=$(find "$SCRIPT_DIR" -type d -name "bin" 2>/dev/null | head -1)
  if [ -n "$CONTAINERD_DIR" ] && [ -f "$CONTAINERD_DIR/containerd" ]; then
    cp "$CONTAINERD_DIR/containerd" /usr/local/bin/
    cp "$CONTAINERD_DIR/containerd-shim-runc-v2" /usr/local/bin/
    cp "$CONTAINERD_DIR/ctr" /usr/local/bin/
  chmod +x /usr/local/bin/containerd*
  chmod +x /usr/local/bin/ctr
    echo "✓ containerd binaries installed" | tee -a "$INSTALL_LOG"
  else
    echo "Error: containerd not found in offline package" | tee -a "$INSTALL_LOG"
    exit 1
  fi

  CONTAINERD_BIN="/usr/local/bin/containerd"
  CTR_BIN="/usr/local/bin/ctr"
  SKIP_CONTAINERD_INSTALL=false
fi

# Configure and start containerd (only if installing from offline package)
if [ "$SKIP_CONTAINERD_INSTALL" != true ]; then
  echo "Configuring containerd..." | tee -a "$INSTALL_LOG"
  mkdir -p /etc/containerd
  cat > /etc/containerd/config.toml << 'CONTAINERD_EOF'
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "kubeedge/pause:3.6"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
CONTAINERD_EOF

  # Create containerd systemd service (使用检测到的路径)
  cat > /etc/systemd/system/containerd.service << CONTAINERD_SVC_EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=$CONTAINERD_BIN
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
CONTAINERD_SVC_EOF
  echo "✓ containerd service file created" | tee -a "$INSTALL_LOG"

  # Start containerd
  systemctl daemon-reload
  systemctl enable containerd
  systemctl restart containerd

  # Wait for containerd to be ready
  echo "Waiting for containerd to start..." | tee -a "$INSTALL_LOG"
  for i in {1..10}; do
    if systemctl is-active --quiet containerd && [ -S /run/containerd/containerd.sock ]; then
        echo "✓ containerd is running" | tee -a "$INSTALL_LOG"
      break
    fi
    sleep 1
  done

  if ! systemctl is-active --quiet containerd; then
    echo "Warning: containerd may not be running properly" | tee -a "$INSTALL_LOG"
    systemctl status containerd --no-pager | tee -a "$INSTALL_LOG"
  fi
else
  echo "✓ Skipped containerd installation (using system version)" | tee -a "$INSTALL_LOG"
fi

echo "✓ Prerequisites checked" | tee -a "$INSTALL_LOG"

# Install runc (强制从离线包安装)
echo "[3/6] Installing runc..." | tee -a "$INSTALL_LOG"
RUNC_BIN=$(find "$SCRIPT_DIR" -name "runc" -type f 2>/dev/null | head -1)
if [ -n "$RUNC_BIN" ] && [ -f "$RUNC_BIN" ]; then
  cp "$RUNC_BIN" /usr/local/bin/runc
  chmod +x /usr/local/bin/runc
  echo "✓ runc installed" | tee -a "$INSTALL_LOG"
else
  echo "Error: runc not found in offline package" | tee -a "$INSTALL_LOG"
  exit 1
fi

# Install CNI plugins (强制从离线包安装)
echo "[4/6] Installing CNI plugins..." | tee -a "$INSTALL_LOG"
CNI_DIR=$(find "$SCRIPT_DIR" -type d -name "cni-plugins" 2>/dev/null | head -1)
if [ -n "$CNI_DIR" ] && [ -d "$CNI_DIR" ]; then
  mkdir -p /opt/cni/bin
  cp "$CNI_DIR"/* /opt/cni/bin/ || true
  chmod +x /opt/cni/bin/*
  echo "✓ CNI plugins installed to /opt/cni/bin" | tee -a "$INSTALL_LOG"
else
  echo "Error: CNI plugins not found in offline package" | tee -a "$INSTALL_LOG"
  exit 1
fi

# Create CNI config directory (EdgeCore's edged module will create CNI config automatically)
echo "[4.2/6] Preparing CNI directory..." | tee -a "$INSTALL_LOG"
mkdir -p /etc/cni/net.d
echo "  ✓ CNI目录已创建 (EdgeCore的edged模块将根据PodCIDR自动配置CNI)" | tee -a "$INSTALL_LOG"
echo "✓ CNI准备完成" | tee -a "$INSTALL_LOG"


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
    
    # 导入镜像到 containerd（使用离线包提供的 ctr）
    if [ -f "$CTR_BIN" ]; then
      if "$CTR_BIN" -n k8s.io images import "$MQTT_IMAGE_TAR" >> "$INSTALL_LOG" 2>&1; then
        echo "  ✓ MQTT 镜像已导入到 containerd" | tee -a "$INSTALL_LOG"
        
        # 创建 mosquitto systemd service（使用离线包 ctr 的绝对路径）
        cat > /etc/systemd/system/mosquitto.service << MOSQUITTO_SVC_EOF
[Unit]
Description=Mosquitto MQTT Broker for KubeEdge IoT Devices
Documentation=https://mosquitto.org/
After=network-online.target containerd.service
Wants=network-online.target
Requires=containerd.service

[Service]
Type=simple
Restart=always
RestartSec=5
TimeoutStartSec=0

# 使用 ctr 运行 mosquitto 容器
ExecStartPre=-$CTR_BIN -n k8s.io task kill --signal SIGTERM mosquitto
ExecStartPre=-$CTR_BIN -n k8s.io task delete mosquitto
ExecStartPre=-$CTR_BIN -n k8s.io container delete mosquitto
ExecStartPre=/bin/mkdir -p /var/lib/mosquitto/data /var/log/mosquitto

ExecStart=$CTR_BIN -n k8s.io run \
  --rm \
  --net-host \
  --mount type=bind,src=/var/lib/mosquitto/data,dst=/mosquitto/data,options=rbind:rw \
  --mount type=bind,src=/var/log/mosquitto,dst=/mosquitto/log,options=rbind:rw \
  docker.io/library/eclipse-mosquitto:2.0 \
  mosquitto \
  mosquitto -c /mosquitto-no-auth.conf

ExecStop=$CTR_BIN -n k8s.io task kill --signal SIGTERM mosquitto
ExecStopPost=$CTR_BIN -n k8s.io task delete mosquitto
ExecStopPost=$CTR_BIN -n k8s.io container delete mosquitto

StandardOutput=journal
StandardError=journal
SyslogIdentifier=mosquitto

[Install]
WantedBy=multi-user.target
MOSQUITTO_SVC_EOF
        
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

# 创建 EdgeCore systemd service
cat > /etc/systemd/system/edgecore.service << 'EDGECORE_SVC_EOF'
[Unit]
Description=KubeEdge EdgeCore
Documentation=https://kubeedge.io
After=network-online.target mosquitto.service containerd.service
Wants=network-online.target
Requires=containerd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/edgecore --config=/etc/kubeedge/edgecore.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=edgecore

[Install]
WantedBy=multi-user.target
EDGECORE_SVC_EOF

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
    httpServer: https://CLOUD_IP_PLACEHOLDER:10002
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
      cgroupDriver: systemd
      cgroupsPerQOS: true
      clusterDNS:
        - 10.43.0.10
      clusterDomain: cluster.local
      containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
      networkPluginName: cni
      networkPluginMTU: 1500
      cniConfDir: /etc/cni/net.d
      cniBinDir: /opt/cni/bin
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
