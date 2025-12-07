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
            SystemdCgroup = false
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
  
  # Pre-load pause image for containerd sandbox (required for keadm join)
  echo "Pre-loading pause image for containerd..." | tee -a "$INSTALL_LOG"
  IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
  if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
    PAUSE_IMAGE=$(find "$IMAGES_DIR" -name "*pause*.tar" -type f 2>/dev/null | head -1)
    if [ -n "$PAUSE_IMAGE" ] && [ -f "$PAUSE_IMAGE" ]; then
      echo "  Loading: $(basename "$PAUSE_IMAGE")" | tee -a "$INSTALL_LOG"
      if "$CTR_BIN" -n k8s.io images import "$PAUSE_IMAGE" >> "$INSTALL_LOG" 2>&1; then
        echo "  ✓ pause image loaded successfully" | tee -a "$INSTALL_LOG"
        # Verify image
        "$CTR_BIN" -n k8s.io images ls | grep pause >> "$INSTALL_LOG" 2>&1 || true
      else
        echo "  Warning: Failed to load pause image" | tee -a "$INSTALL_LOG"
      fi
    else
      echo "  Warning: pause image not found in offline package" | tee -a "$INSTALL_LOG"
    fi
  fi
else
  echo "✓ Skipped containerd installation (using system version)" | tee -a "$INSTALL_LOG"
  
  # Still need to pre-load pause image for system containerd
  echo "Pre-loading pause image for system containerd..." | tee -a "$INSTALL_LOG"
  IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
  if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
    PAUSE_IMAGE=$(find "$IMAGES_DIR" -name "*pause*.tar" -type f 2>/dev/null | head -1)
    if [ -n "$PAUSE_IMAGE" ] && [ -f "$PAUSE_IMAGE" ]; then
      echo "  Loading: $(basename "$PAUSE_IMAGE")" | tee -a "$INSTALL_LOG"
      if "$CTR_BIN" -n k8s.io images import "$PAUSE_IMAGE" >> "$INSTALL_LOG" 2>&1; then
        echo "  ✓ pause image loaded successfully" | tee -a "$INSTALL_LOG"
      else
        echo "  Warning: Failed to load pause image" | tee -a "$INSTALL_LOG"
      fi
    fi
  fi
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

# Install CNI plugins (required for Node Ready status in v1.22.0)
echo "[4/6] Installing CNI plugins..." | tee -a "$INSTALL_LOG"
CNI_BIN_DIR="/opt/cni/bin"
CNI_CONF_DIR="/etc/cni/net.d"

mkdir -p "$CNI_BIN_DIR" "$CNI_CONF_DIR"

# Copy CNI binaries from offline package
CNI_SOURCE=$(find "$SCRIPT_DIR" -type d -name "cni-bin" 2>/dev/null | head -1)
if [ -n "$CNI_SOURCE" ] && [ -d "$CNI_SOURCE" ]; then
  cp "$CNI_SOURCE"/* "$CNI_BIN_DIR/" 2>/dev/null || true
  chmod +x "$CNI_BIN_DIR"/*
  echo "✓ CNI plugins installed to $CNI_BIN_DIR" | tee -a "$INSTALL_LOG"
  
  # Generate CNI configuration with node-specific CIDR to avoid conflicts
  # Use node name hash to generate unique subnet (10.244.X.0/24)
  NODE_HASH=$(echo -n "$NODE_NAME" | md5sum | cut -c1-2)
  SUBNET_OCTET=$((16#$NODE_HASH % 254 + 1))
  POD_CIDR="10.244.${SUBNET_OCTET}.0/24"
  
  echo "  Generating CNI config with Pod CIDR: $POD_CIDR" | tee -a "$INSTALL_LOG"
  
  cat > "$CNI_CONF_DIR/10-kubeedge-bridge.conflist" << EOF_CNI
{
  "cniVersion": "1.0.0",
  "name": "kubeedge-cni",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isDefaultGateway": true,
      "forceAddress": false,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "subnet": "${POD_CIDR}",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
EOF_CNI
  
  echo "✓ CNI configuration created: $CNI_CONF_DIR/10-kubeedge-bridge.conflist" | tee -a "$INSTALL_LOG"
  echo "  Pod CIDR: $POD_CIDR (based on node name: $NODE_NAME)" | tee -a "$INSTALL_LOG"
else
  echo "Warning: CNI binaries not found in offline package" | tee -a "$INSTALL_LOG"
  echo "  Edge node may show NotReady status" | tee -a "$INSTALL_LOG"
fi


# Deploy Mosquitto MQTT Broker for IoT devices
echo "[4.5/6] 导入边缘镜像 (EdgeMesh + MQTT)..." | tee -a "$INSTALL_LOG"
IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
MQTT_DEPLOYED=false

if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
  # 1. 导入 EdgeMesh Agent 镜像
  EDGEMESH_IMAGE_TAR=$(find "$IMAGES_DIR" -name "*edgemesh-agent*.tar" -type f 2>/dev/null | head -1)
  
  if [ -n "$EDGEMESH_IMAGE_TAR" ] && [ -f "$EDGEMESH_IMAGE_TAR" ]; then
    echo "  导入 EdgeMesh Agent 镜像..." | tee -a "$INSTALL_LOG"
    
    # 确保 containerd 正在运行
    if ! systemctl is-active --quiet containerd 2>/dev/null; then
      echo "    启动 containerd..." | tee -a "$INSTALL_LOG"
      systemctl start containerd || echo "    警告: 无法启动 containerd" | tee -a "$INSTALL_LOG"
      sleep 2
    fi
    
    # 导入镜像到 containerd
    if [ -f "$CTR_BIN" ]; then
      if "$CTR_BIN" -n k8s.io images import "$EDGEMESH_IMAGE_TAR" >> "$INSTALL_LOG" 2>&1; then
        echo "  ✓ EdgeMesh Agent 镜像已导入" | tee -a "$INSTALL_LOG"
        # 验证镜像
        "$CTR_BIN" -n k8s.io images ls | grep edgemesh >> "$INSTALL_LOG" 2>&1 || true
      else
        echo "  ⚠️  EdgeMesh 镜像导入失败，边缘节点将无法加入服务网格" | tee -a "$INSTALL_LOG"
      fi
    else
      echo "  ⚠️  ctr 命令未找到，无法导入 EdgeMesh 镜像" | tee -a "$INSTALL_LOG"
    fi
  else
    echo "  ⚠️  EdgeMesh 镜像未在离线包中找到" | tee -a "$INSTALL_LOG"
    echo "     边缘节点将无法加入服务网格" | tee -a "$INSTALL_LOG"
  fi
  
  # 2. 导入 Mosquitto MQTT 镜像
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
# Note: DO NOT pre-create ca/ and certs/ directories
# EdgeCore will automatically create them and request certificates from CloudCore on first startup

# 创建 EdgeCore systemd service (使用官方路径)
cat > /etc/systemd/system/edgecore.service << 'EDGECORE_SVC_EOF'
[Unit]
Description=KubeEdge EdgeCore
Documentation=https://kubeedge.io
After=network-online.target mosquitto.service containerd.service
Wants=network-online.target
Requires=containerd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/edgecore --config=/etc/kubeedge/config/edgecore.yaml
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

# Use keadm join to register edge node (following official workflow)
echo "  Preparing for edge node join..." | tee -a "$INSTALL_LOG"

# Find keadm binary
KEADM_BIN=$(find "$SCRIPT_DIR" -name "keadm" -type f 2>/dev/null | head -1)
if [ -z "$KEADM_BIN" ]; then
  echo "Error: keadm not found in offline package" | tee -a "$INSTALL_LOG"
  exit 1
fi

cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# Pre-load KubeEdge installation-package image (required for offline keadm join)
echo "  Pre-loading KubeEdge installation-package image..." | tee -a "$INSTALL_LOG"
IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
INSTALLATION_IMAGE=""

if [ -d "$IMAGES_DIR" ]; then
  # Look for installation-package image
  INSTALLATION_IMAGE=$(find "$IMAGES_DIR" -name "*installation-package*.tar" -type f 2>/dev/null | head -1)
fi

if [ -n "$INSTALLATION_IMAGE" ] && [ -f "$INSTALLATION_IMAGE" ]; then
  echo "  Loading: $(basename "$INSTALLATION_IMAGE")" | tee -a "$INSTALL_LOG"
  if ctr -n k8s.io images import "$INSTALLATION_IMAGE" >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ installation-package image loaded successfully" | tee -a "$INSTALL_LOG"
    # Verify image
    if ctr -n k8s.io images ls | grep -q "installation-package"; then
      echo "  ✓ Image verified in containerd" | tee -a "$INSTALL_LOG"
    fi
  else
    echo "  Warning: Failed to load installation-package image" | tee -a "$INSTALL_LOG"
    echo "  keadm join may attempt online download" | tee -a "$INSTALL_LOG"
  fi
else
  echo "  Warning: installation-package image not found in offline package" | tee -a "$INSTALL_LOG"
  echo "  Expected location: $IMAGES_DIR/*installation-package*.tar" | tee -a "$INSTALL_LOG"
  echo "  keadm join will attempt online download (may fail if offline)" | tee -a "$INSTALL_LOG"
fi

# Run keadm join to generate config and download certificates from cloud
# Note: --cloudcore-ipport is for WebSocket runtime, --certport is for HTTPS cert download (10002)
echo "  Joining edge node using keadm..." | tee -a "$INSTALL_LOG"
echo "  Running: keadm join --cloudcore-ipport=${CLOUD_IP}:${CLOUD_PORT} --certport=10002 --edgenode-name=${NODE_NAME} --token=<token> --kubeedge-version=v${KUBEEDGE_VERSION}" | tee -a "$INSTALL_LOG"

if /usr/local/bin/keadm join \
  --cloudcore-ipport="${CLOUD_IP}:${CLOUD_PORT}" \
  --certport=10002 \
  --edgenode-name="${NODE_NAME}" \
  --token="${EDGE_TOKEN}" \
  --kubeedge-version="v${KUBEEDGE_VERSION}" \
  --remote-runtime-endpoint="unix:///run/containerd/containerd.sock" >> "$INSTALL_LOG" 2>&1; then
  
  echo "  ✓ keadm join completed successfully" | tee -a "$INSTALL_LOG"
  echo "  ✓ Certificates downloaded from cloud (via port 10002)" | tee -a "$INSTALL_LOG"
  echo "  ✓ EdgeCore configuration generated at /etc/kubeedge/config/edgecore.yaml" | tee -a "$INSTALL_LOG"
else
  echo "  Error: keadm join failed" | tee -a "$INSTALL_LOG"
  echo "  Check $INSTALL_LOG for details" | tee -a "$INSTALL_LOG"
  exit 1
fi

# Post-join customization: Enable metaServer, configure CNI, and adjust MQTT settings
echo "  Applying edge customizations (metaServer, CNI, MQTT)..." | tee -a "$INSTALL_LOG"

if [ -f /etc/kubeedge/config/edgecore.yaml ]; then
  # Backup original config
  cp /etc/kubeedge/config/edgecore.yaml /etc/kubeedge/config/edgecore.yaml.keadm-original
  
  # 1. Enable metaServer (required for EdgeMesh)
  if ! grep -q "metaServer:" /etc/kubeedge/config/edgecore.yaml; then
    # Add metaServer section to metaManager
    sed -i '/metaManager:/a\    metaServer:\n      enable: true\n      server: 127.0.0.1:10550' /etc/kubeedge/config/edgecore.yaml
  else
    # Enable if exists but disabled
    sed -i '/metaServer:/,/enable:/ s/enable: false/enable: true/' /etc/kubeedge/config/edgecore.yaml
  fi
  
  # 2. Configure CNI and DNS for edged module
  if grep -q "edged:" /etc/kubeedge/config/edgecore.yaml; then
    # Ensure networkPluginName is set to cni
    if ! grep -q "networkPluginName:" /etc/kubeedge/config/edgecore.yaml; then
      sed -i '/edged:/a\    networkPluginName: cni' /etc/kubeedge/config/edgecore.yaml
      echo "  ✓ CNI network plugin configured in edged" | tee -a "$INSTALL_LOG"
    fi
    
    # Set clusterDNS to EdgeMesh DNS (169.254.96.16 - EdgeMesh bridgeDeviceIP)
    # EdgeMesh will handle DNS resolution for edge Pods
    if ! grep -q "clusterDNS:" /etc/kubeedge/config/edgecore.yaml; then
      sed -i '/edged:/a\    clusterDNS:\n    - 169.254.96.16' /etc/kubeedge/config/edgecore.yaml
      echo "  ✓ ClusterDNS configured: 169.254.96.16 (EdgeMesh DNS)" | tee -a "$INSTALL_LOG"
    fi
    
    # Set clusterDomain
    if ! grep -q "clusterDomain:" /etc/kubeedge/config/edgecore.yaml; then
      sed -i '/edged:/a\    clusterDomain: cluster.local' /etc/kubeedge/config/edgecore.yaml
      echo "  ✓ ClusterDomain configured: cluster.local" | tee -a "$INSTALL_LOG"
    fi
  fi
  
  # 3. Configure MQTT for IoT devices (eventBus)
  if grep -q "mqttServerExternal:" /etc/kubeedge/config/edgecore.yaml; then
    sed -i 's|mqttServerExternal:.*|mqttServerExternal: tcp://127.0.0.1:1883|' /etc/kubeedge/config/edgecore.yaml
    sed -i 's|mqttServerInternal:.*|mqttServerInternal: tcp://127.0.0.1:1884|' /etc/kubeedge/config/edgecore.yaml
  fi
  
  echo "  ✓ Edge customizations applied (metaServer + CNI + MQTT)" | tee -a "$INSTALL_LOG"
fi

echo "✓ Edge node configuration completed (official keadm workflow)" | tee -a "$INSTALL_LOG"
echo "  Note: Certificates auto-downloaded from cloud via HTTPS (port 10002)" | tee -a "$INSTALL_LOG"

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
