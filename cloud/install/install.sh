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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Check for existing components
echo "[0/7] Checking for existing components..." | tee -a "$INSTALL_LOG"

HAS_K3S=false
HAS_DOCKER=false

if [ -f /usr/local/bin/k3s ] || systemctl list-units --full -all 2>/dev/null | grep -q "k3s.service"; then
  HAS_K3S=true
  echo "⚠️  警告: 检测到系统已安装 K3s" | tee -a "$INSTALL_LOG"
  echo "   现有 K3s 安装位置: /usr/local/bin/k3s" | tee -a "$INSTALL_LOG"
  echo "   如需重新安装，请先运行清理脚本: sudo ./cleanup.sh" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  read -p "是否继续？这将覆盖现有安装 (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消安装" | tee -a "$INSTALL_LOG"
    exit 1
  fi
fi

if systemctl list-units --full -all 2>/dev/null | grep -q "docker.service" || command -v docker &> /dev/null; then
  HAS_DOCKER=true
  echo "⚠️  警告: 检测到系统已安装 Docker" | tee -a "$INSTALL_LOG"
  echo "   Docker 与 K3s 可以共存，但它们使用不同的 containerd" | tee -a "$INSTALL_LOG"
  echo "   K3s 有自己内置的 containerd，不会影响 Docker" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
fi

echo "✓ Component check completed" | tee -a "$INSTALL_LOG"

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
if ! command -v systemctl &> /dev/null; then
  echo "Error: systemctl not found. This script requires systemd." | tee -a "$INSTALL_LOG"
  exit 1
fi
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
  --cluster-cidr=10.42.0.0/16 \\
  --service-cidr=10.43.0.0/16 \\
  --cluster-dns=10.43.0.10 \\
  --kube-apiserver-arg=bind-address=0.0.0.0 \\
  --kube-apiserver-arg=advertise-address=$EXTERNAL_IP \\
  --kube-controller-manager-arg=bind-address=0.0.0.0 \\
  --kube-controller-manager-arg=node-cidr-mask-size=24 \\
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

# Install Istio CRDs (Required for EdgeMesh)
echo "[5.5/7] Installing Istio CRDs (EdgeMesh dependency)..." | tee -a "$INSTALL_LOG"
CRDS_DIR="$SCRIPT_DIR/crds/istio"
if [ -d "$CRDS_DIR" ] && [ -n "$(ls -A "$CRDS_DIR" 2>/dev/null)" ]; then
  CRD_COUNT=0
  for crd_file in "$CRDS_DIR"/*.yaml; do
    if [ -f "$crd_file" ]; then
      echo "  Installing $(basename "$crd_file")..." | tee -a "$INSTALL_LOG"
      if $KUBECTL apply -f "$crd_file" >> "$INSTALL_LOG" 2>&1; then
        CRD_COUNT=$((CRD_COUNT + 1))
      else
        echo "  Warning: Failed to install $(basename "$crd_file")" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  if [ $CRD_COUNT -gt 0 ]; then
    echo "✓ Installed $CRD_COUNT Istio CRDs" | tee -a "$INSTALL_LOG"
  else
    echo "Warning: No Istio CRDs found in $CRDS_DIR" | tee -a "$INSTALL_LOG"
  fi
else
  echo "Warning: Istio CRDs directory not found, EdgeMesh may not work properly" | tee -a "$INSTALL_LOG"
  echo "  Expected location: $CRDS_DIR" | tee -a "$INSTALL_LOG"
fi

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
  if $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
    echo "✓ CloudCore is ready" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "Waiting... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

# Enable CloudCore dynamicController (Required for EdgeMesh metaServer)
echo "[6.5/7] Enabling CloudCore dynamicController and cloudStream..." | tee -a "$INSTALL_LOG"
if $KUBECTL -n kubeedge get cm cloudcore 2>/dev/null | grep -q cloudcore; then
  echo "  Patching CloudCore ConfigMap to enable dynamicController and cloudStream..." | tee -a "$INSTALL_LOG"
  
  # Get current configmap
  CLOUDCORE_CM_FILE=$(mktemp)
  $KUBECTL -n kubeedge get cm cloudcore -o yaml > "$CLOUDCORE_CM_FILE"
  
  # Check if dynamicController and cloudStream are already enabled
  if grep -q "enable: true" "$CLOUDCORE_CM_FILE" | grep -q "dynamicController" 2>/dev/null && grep -q "cloudStream" "$CLOUDCORE_CM_FILE" 2>/dev/null; then
    echo "  ✓ dynamicController and cloudStream are already enabled" | tee -a "$INSTALL_LOG"
  else
    # Use kubectl patch to enable dynamicController and cloudStream
    if $KUBECTL -n kubeedge patch cm cloudcore --type=json -p='[{"op": "replace", "path": "/data/cloudcore.yaml", "value": "modules:\n  cloudHub:\n    advertiseAddress:\n    - '\"$EXTERNAL_IP\"'\n    nodeLimit: 1000\n  cloudStream:\n    enable: true\n    streamPort: 10003\n    tunnelPort: 10004\n  dynamicController:\n    enable: true\n"}]' >> "$INSTALL_LOG" 2>&1; then
      echo "  ✓ dynamicController and cloudStream enabled successfully" | tee -a "$INSTALL_LOG"
      
      # Restart CloudCore pod to apply changes
      echo "  Restarting CloudCore pod to apply configuration..." | tee -a "$INSTALL_LOG"
      $KUBECTL -n kubeedge delete pod -l kubeedge=cloudcore >> "$INSTALL_LOG" 2>&1 || true
      
      # Wait for CloudCore to be ready again
      echo "  Waiting for CloudCore to restart..." | tee -a "$INSTALL_LOG"
      sleep 5
      for i in {1..30}; do
        if $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
          echo "  ✓ CloudCore restarted successfully" | tee -a "$INSTALL_LOG"
          break
        fi
        sleep 2
      done
    else
      echo "  Warning: Failed to patch CloudCore ConfigMap" | tee -a "$INSTALL_LOG"
      echo "  You may need to manually enable dynamicController and cloudStream in /etc/kubeedge/config/cloudcore.yaml" | tee -a "$INSTALL_LOG"
    fi
  fi
  rm -f "$CLOUDCORE_CM_FILE"
else
  echo "  Warning: CloudCore ConfigMap not found" | tee -a "$INSTALL_LOG"
  echo "  Checking if cloudcore.yaml exists in /etc/kubeedge/config/..." | tee -a "$INSTALL_LOG"
  if [ -f /etc/kubeedge/config/cloudcore.yaml ]; then
    echo "  Found /etc/kubeedge/config/cloudcore.yaml, enabling dynamicController and cloudStream..." | tee -a "$INSTALL_LOG"
    # Backup original config
    cp /etc/kubeedge/config/cloudcore.yaml /etc/kubeedge/config/cloudcore.yaml.bak
    
    # Check if dynamicController section exists
    if grep -q "dynamicController:" /etc/kubeedge/config/cloudcore.yaml; then
      # Replace enable: false with enable: true
      sed -i '/dynamicController:/,/enable:/ s/enable: false/enable: true/' /etc/kubeedge/config/cloudcore.yaml
    else
      # Add dynamicController section
      cat >> /etc/kubeedge/config/cloudcore.yaml << 'DYNAMIC_EOF'
  dynamicController:
    enable: true
DYNAMIC_EOF
    fi
    
    # Check if cloudStream section exists
    if grep -q "cloudStream:" /etc/kubeedge/config/cloudcore.yaml; then
      # Enable cloudStream if it's disabled
      sed -i '/cloudStream:/,/enable:/ s/enable: false/enable: true/' /etc/kubeedge/config/cloudcore.yaml
    else
      # Add cloudStream section
      cat >> /etc/kubeedge/config/cloudcore.yaml << 'STREAM_EOF'
  cloudStream:
    enable: true
    streamPort: 10003
    tunnelPort: 10004
STREAM_EOF
    fi
    
    echo "  ✓ dynamicController and cloudStream enabled in cloudcore.yaml" | tee -a "$INSTALL_LOG"
    echo "  Restarting cloudcore service..." | tee -a "$INSTALL_LOG"
    systemctl restart cloudcore 2>/dev/null || $KUBECTL -n kubeedge delete pod -l kubeedge=cloudcore >> "$INSTALL_LOG" 2>&1 || true
    sleep 5
  else
    echo "  Warning: Could not find CloudCore configuration" | tee -a "$INSTALL_LOG"
  fi
fi

# Generate edge token
echo "[7/7] Generating edge token..." | tee -a "$INSTALL_LOG"
TOKEN_DIR="/etc/kubeedge/tokens"
mkdir -p "$TOKEN_DIR"

# Get CloudCore service
CLOUD_IP="$EXTERNAL_IP"
CLOUD_PORT="10000"

# Wait for tokensecret to be ready
echo "  Waiting for KubeEdge token secret..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if $KUBECTL get secret -n kubeedge tokensecret &>/dev/null; then
    echo "  ✓ Token secret is ready" | tee -a "$INSTALL_LOG"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "  Warning: Token secret not found, will try keadm" | tee -a "$INSTALL_LOG"
  fi
  sleep 1
done

# Get token directly from K8s secret (正确的完整JWT格式)
EDGE_TOKEN=$($KUBECTL get secret -n kubeedge tokensecret -o jsonpath='{.data.tokendata}' 2>/dev/null | base64 -d)

# Fallback: try keadm gettoken
if [ -z "$EDGE_TOKEN" ]; then
  echo "  Trying keadm gettoken..." | tee -a "$INSTALL_LOG"
  EDGE_TOKEN=$("$KEADM_BIN" gettoken --kubeedge-version=v"$KUBEEDGE_VERSION" --kube-config=/etc/rancher/k3s/k3s.yaml 2>/dev/null || echo "")
fi

# Last fallback: generate simple token (should not happen in normal case)
if [ -z "$EDGE_TOKEN" ]; then
  echo "  Warning: Using fallback token generation" | tee -a "$INSTALL_LOG"
  EDGE_TOKEN=$(openssl rand -base64 32 | tr -d '\n' || echo "default-token-$(date +%s)")
fi

# Validate token format (should be JWT format with dots)
if [[ "$EDGE_TOKEN" == *"."* ]]; then
  echo "  ✓ Token format validated (JWT)" | tee -a "$INSTALL_LOG"
else
  echo "  Warning: Token format may be incorrect (not JWT format)" | tee -a "$INSTALL_LOG"
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
# =====================================
# 7. Install EdgeMesh (Optional)
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "=== 7. 安装 EdgeMesh (可选) ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# Check if helm-charts directory exists
HELM_CHART_DIR="$SCRIPT_DIR/helm-charts"
if [ -d "$HELM_CHART_DIR" ] && [ -f "$HELM_CHART_DIR/edgemesh.tgz" ]; then
  echo "检测到 EdgeMesh Helm Chart，是否安装 EdgeMesh? (y/n)" | tee -a "$INSTALL_LOG"
  read -r INSTALL_EDGEMESH
  
  if [[ "$INSTALL_EDGEMESH" == "y" || "$INSTALL_EDGEMESH" == "Y" ]]; then
    echo "[7/7] 安装 EdgeMesh..." | tee -a "$INSTALL_LOG"
    
    # Generate PSK for EdgeMesh
    EDGEMESH_PSK=$(openssl rand -base64 32)
    echo "生成 EdgeMesh PSK: $EDGEMESH_PSK" | tee -a "$INSTALL_LOG"
    
    # Get master node name for relay
    MASTER_NODE=$(/usr/local/bin/kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    echo "使用 Relay Node: $MASTER_NODE" | tee -a "$INSTALL_LOG"
    
    # Install EdgeMesh using local helm chart
    /usr/local/bin/helm install edgemesh "$HELM_CHART_DIR/edgemesh.tgz" \
      --namespace kubeedge \
      --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
      --set agent.psk="$EDGEMESH_PSK" \
      --set agent.relayNodes[0].nodeName="$MASTER_NODE" \
      --set agent.relayNodes[0].advertiseAddress="{$CLOUD_IP}" 2>&1 | tee -a "$INSTALL_LOG"
    
    if [ $? -eq 0 ]; then
      echo "✓ EdgeMesh 安装成功" | tee -a "$INSTALL_LOG"
      
      # Wait for EdgeMesh pods
      echo "等待 EdgeMesh Agent Pod 启动..." | tee -a "$INSTALL_LOG"
      /usr/local/bin/kubectl wait --for=condition=ready pod -l app=edgemesh-agent \
        -n kubeedge --timeout=300s 2>&1 | tee -a "$INSTALL_LOG"
      
      # Save PSK to file for edge nodes
      echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
      echo "EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
    else
      echo "✗ EdgeMesh 安装失败，请检查日志" | tee -a "$INSTALL_LOG"
      echo "可以稍后手动安装: helm install edgemesh $HELM_CHART_DIR/edgemesh.tgz ..." | tee -a "$INSTALL_LOG"
    fi
  else
    echo "跳过 EdgeMesh 安装" | tee -a "$INSTALL_LOG"
    echo "如需稍后安装，执行:" | tee -a "$INSTALL_LOG"
    echo "  helm install edgemesh $HELM_CHART_DIR/edgemesh.tgz --namespace kubeedge \\" | tee -a "$INSTALL_LOG"
    echo "    --set agent.psk=\$(openssl rand -base64 32) \\" | tee -a "$INSTALL_LOG"
    echo "    --set agent.relayNodes[0].nodeName=<master-node-name> \\" | tee -a "$INSTALL_LOG"
    echo "    --set agent.relayNodes[0].advertiseAddress=\"{$CLOUD_IP}\"" | tee -a "$INSTALL_LOG"
  fi
else
  echo "未检测到 EdgeMesh Helm Chart，跳过安装" | tee -a "$INSTALL_LOG"
  echo "EdgeMesh 需要从 cloud 离线包中获取" | tee -a "$INSTALL_LOG"
fi

echo "" | tee -a "$INSTALL_LOG"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "边缘节点接入Token (请保存用于edge节点安装):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v jq &>/dev/null; then
  cat "$TOKEN_FILE" | jq -r . 2>/dev/null || cat "$TOKEN_FILE"
else
  cat "$TOKEN_FILE"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "完整Token内容 (用于edge安装脚本第2个参数):"
echo "$EDGE_TOKEN"
echo ""
echo "使用方法:"
echo "  cd /data/kubeedge-edge-xxx && sudo ./install.sh $CLOUD_IP:$CLOUD_PORT '$EDGE_TOKEN' <节点名称>"
echo ""
