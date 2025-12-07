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

# Enable CloudCore dynamicController and cloudStream (Required for EdgeMesh and edge log/exec)
echo "[6.5/7] Enabling CloudCore additional features..." | tee -a "$INSTALL_LOG"

# Get current CloudCore configuration
CLOUDCORE_CONFIG=$($KUBECTL -n kubeedge get cm cloudcore -o jsonpath='{.data.cloudcore\.yaml}' 2>/dev/null || echo "")

if [ -z "$CLOUDCORE_CONFIG" ]; then
  echo "  Warning: CloudCore ConfigMap not found, skipping customization" | tee -a "$INSTALL_LOG"
else
  echo "  Patching CloudCore ConfigMap to enable dynamicController and cloudStream..." | tee -a "$INSTALL_LOG"
  
  # Use yq-style patch or structured edit (since we don't have yq, use kubectl patch with strategic merge)
  # Note: We only enable features, not changing certificate paths (keep keadm defaults)
  
  # Create a patch that enables dynamicController and cloudStream without touching cert paths
  cat > /tmp/cloudcore-patch.yaml << 'EOF_PATCH'
data:
  cloudcore.yaml: |
    modules:
      cloudHub:
        advertiseAddress:
        - EXTERNAL_IP_PLACEHOLDER
        https:
          enable: true
          port: 10002
        nodeLimit: 1000
        websocket:
          enable: true
          port: 10000
      cloudStream:
        enable: true
        streamPort: 10003
        tunnelPort: 10004
      dynamicController:
        enable: true
EOF_PATCH
  
  # Replace placeholder with actual IP
  sed -i "s/EXTERNAL_IP_PLACEHOLDER/$EXTERNAL_IP/g" /tmp/cloudcore-patch.yaml
  
  # Apply the patch (strategic merge will preserve other fields including cert paths from keadm)
  if $KUBECTL -n kubeedge patch cm cloudcore --patch-file /tmp/cloudcore-patch.yaml >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ CloudCore features enabled successfully" | tee -a "$INSTALL_LOG"
    
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
      if [ $i -eq 30 ]; then
        echo "  Warning: CloudCore restart timeout" | tee -a "$INSTALL_LOG"
      fi
      sleep 2
    done
  else
    echo "  Warning: Failed to patch CloudCore ConfigMap" | tee -a "$INSTALL_LOG"
    echo "  CloudCore will run with default configuration" | tee -a "$INSTALL_LOG"
  fi
  
  rm -f /tmp/cloudcore-patch.yaml
fi

# Generate edge token
echo "[7/7] Generating edge token..." | tee -a "$INSTALL_LOG"
TOKEN_DIR="/etc/kubeedge/tokens"
mkdir -p "$TOKEN_DIR"

# Get CloudCore service
CLOUD_IP="$EXTERNAL_IP"
CLOUD_PORT="10000"

# Wait for tokensecret to be ready (with CloudCore running check)
echo "  Waiting for KubeEdge token secret..." | tee -a "$INSTALL_LOG"
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
  # First ensure CloudCore is Running
  if ! $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
    if [ $((i % 10)) -eq 0 ]; then
      echo "  CloudCore not running yet, waiting... ($i/$MAX_WAIT)" | tee -a "$INSTALL_LOG"
    fi
    sleep 2
    continue
  fi
  
  # Then check for tokensecret
  if $KUBECTL get secret -n kubeedge tokensecret &>/dev/null; then
    echo "  ✓ Token secret is ready" | tee -a "$INSTALL_LOG"
    break
  fi
  
  if [ $i -eq $MAX_WAIT ]; then
    echo "  Warning: Token secret not found after ${MAX_WAIT} attempts, will try keadm" | tee -a "$INSTALL_LOG"
  fi
  sleep 2
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

# =====================================
# 6.8. Patch K3s Built-in Metrics Server for KubeEdge
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[6.8/7] Patching K3s built-in Metrics Server for KubeEdge..." | tee -a "$INSTALL_LOG"

# 检查 metrics-server 是否存在
if $KUBECTL get deployment metrics-server -n kube-system &>/dev/null; then
  echo "  Found built-in metrics-server, applying KubeEdge compatibility patch..." | tee -a "$INSTALL_LOG"
  
  # 为 KubeEdge 修改 metrics-server 部署（参考 KubeEdge 官方文档）
  # 1. 启用 hostNetwork 以访问 CloudStream 隧道端口映射
  # 2. 修改监听端口为 4443 避免与 kubelet 的 10250 冲突
  # 3. 添加 nodeAffinity 确保只在 master 节点运行
  # 4. 添加 tolerations 容忍 master 节点污点  
  # 5. 添加 --kubelet-insecure-tls 跳过 TLS 验证
  
  # Step 1: 设置 hostNetwork, affinity 和 tolerations (不包含 containers，避免冲突)
  PATCH_DATA=$(cat <<'EOF'
{
  "spec": {
    "template": {
      "spec": {
        "hostNetwork": true,
        "affinity": {
          "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
              "nodeSelectorTerms": [
                {
                  "matchExpressions": [
                    {
                      "key": "node-role.kubernetes.io/control-plane",
                      "operator": "Exists"
                    }
                  ]
                },
                {
                  "matchExpressions": [
                    {
                      "key": "node-role.kubernetes.io/master",
                      "operator": "Exists"
                    }
                  ]
                }
              ]
            }
          }
        },
        "tolerations": [
          {
            "key": "node-role.kubernetes.io/control-plane",
            "operator": "Exists",
            "effect": "NoSchedule"
          },
          {
            "key": "node-role.kubernetes.io/master",
            "operator": "Exists",
            "effect": "NoSchedule"
          }
        ]
      }
    }
  }
}
EOF
)
  
  if echo "$PATCH_DATA" | $KUBECTL patch deployment metrics-server -n kube-system --type=strategic --patch-file /dev/stdin >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ Applied hostNetwork, affinity and tolerations." | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠ Failed to apply base configuration." | tee -a "$INSTALL_LOG"
  fi
  
  # Step 2: 使用 JSON patch 修改容器端口
  if $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":4443}]' >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ Updated containerPort to 4443." | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠ Failed to update containerPort." | tee -a "$INSTALL_LOG"
  fi
  
  # Step 3: 修改 --secure-port 参数
  if $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"--secure-port=4443"}]' >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ Updated --secure-port=4443." | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠ Failed to update --secure-port." | tee -a "$INSTALL_LOG"
  fi
  
  # Step 4: 添加 --kubelet-insecure-tls 参数
  if $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ Added --kubelet-insecure-tls." | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠ Failed to add --kubelet-insecure-tls (may already exist)." | tee -a "$INSTALL_LOG"
  fi
  
  echo "  ✓ Metrics-server patch completed. It will restart automatically." | tee -a "$INSTALL_LOG"
  echo "  提示: metrics-server 已配置为:" | tee -a "$INSTALL_LOG"
  echo "    - 使用 hostNetwork 访问 CloudStream 隧道" | tee -a "$INSTALL_LOG"
  echo "    - 监听端口 4443 (避免与 kubelet:10250 冲突)" | tee -a "$INSTALL_LOG"
  echo "    - 跳过 TLS 验证以支持边缘节点" | tee -a "$INSTALL_LOG"
  echo "    - 验证命令: kubectl top nodes (边缘节点加入后生效)" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠ metrics-server not found, skipping patch." | tee -a "$INSTALL_LOG"
fi

echo "" | tee -a "$INSTALL_LOG"
echo "=== Configuring svclb to avoid edge nodes ===" | tee -a "$INSTALL_LOG"

# 配置所有 svclb DaemonSet，防止调度到边缘节点
# K3s 的 Service Load Balancer (svclb) 不应该在边缘节点运行
# 使用 nodeAffinity 而不是 nodeSelector，因为 nodeSelector 只能匹配标签存在且值相等的情况
SVCLB_COUNT=$($KUBECTL get daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname --no-headers 2>/dev/null | wc -l)

if [ "$SVCLB_COUNT" -gt 0 ]; then
  echo "  Found $SVCLB_COUNT svclb DaemonSet(s), adding nodeAffinity to exclude edge nodes..." | tee -a "$INSTALL_LOG"
  
  # 为所有 svclb DaemonSet 添加 nodeAffinity (排除带有 node-role.kubernetes.io/edge 标签的节点)
  $KUBECTL get daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname -o name | while read -r ds; do
    DS_NAME=$(echo "$ds" | cut -d'/' -f2)
    
    # 使用 nodeAffinity 的 DoesNotExist 操作符排除边缘节点
    AFFINITY_PATCH='{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}'
    
    if $KUBECTL patch "$ds" -n kube-system --type=strategic -p="$AFFINITY_PATCH" >> "$INSTALL_LOG" 2>&1; then
      echo "  ✓ Patched $DS_NAME with nodeAffinity (DoesNotExist edge label)." | tee -a "$INSTALL_LOG"
    else
      echo "  ⚠ Failed to patch $DS_NAME." | tee -a "$INSTALL_LOG"
    fi
  done
  
  echo "  ✓ svclb DaemonSets configured to avoid edge nodes." | tee -a "$INSTALL_LOG"
  echo "  提示: svclb 已配置 nodeAffinity (排除 node-role.kubernetes.io/edge 标签的节点)" | tee -a "$INSTALL_LOG"
else
  echo "  No svclb DaemonSet found, skipping." | tee -a "$INSTALL_LOG"
fi

echo "" | tee -a "$INSTALL_LOG"
echo "=== Next Steps ===" | tee -a "$INSTALL_LOG"
echo "1. Verify k3s cluster:" | tee -a "$INSTALL_LOG"
echo "   kubectl get nodes" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "2. Verify CloudCore:" | tee -a "$INSTALL_LOG"
echo "   kubectl -n kubeedge get pod" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "3. Verify Metrics Server (K3s built-in, patched):" | tee -a "$INSTALL_LOG"
echo "   kubectl get deployment -n kube-system metrics-server -o yaml" | tee -a "$INSTALL_LOG"
echo "   kubectl top node  # 在边缘节点加入后可用" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "4. 验证日志与监控功能:" | tee -a "$INSTALL_LOG"
echo "   sudo bash manifests/verify-logs-metrics.sh  # 自动检查所有功能" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "5. To connect an edge node:" | tee -a "$INSTALL_LOG"
echo "   - Use cloud IP: $CLOUD_IP" | tee -a "$INSTALL_LOG"
echo "   - Use token: $EDGE_TOKEN" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "Installation log: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# Print token to stdout for easy copy
echo ""
# =====================================
# 7. Install EdgeMesh (Automatic)
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "=== 7. 安装 EdgeMesh ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# Check if helm-charts directory exists
HELM_CHART_DIR="$SCRIPT_DIR/helm-charts"
if [ -d "$HELM_CHART_DIR" ] && [ -f "$HELM_CHART_DIR/edgemesh.tgz" ]; then
  echo "检测到 EdgeMesh Helm Chart，开始自动安装..." | tee -a "$INSTALL_LOG"
  echo "[7/7] 安装 EdgeMesh..." | tee -a "$INSTALL_LOG"
  
  # Generate PSK for EdgeMesh
  EDGEMESH_PSK=$(openssl rand -base64 32)
  echo "生成 EdgeMesh PSK: $EDGEMESH_PSK" | tee -a "$INSTALL_LOG"
  
  # Get master node name for relay
  MASTER_NODE=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}')
  echo "使用 Relay Node: $MASTER_NODE" | tee -a "$INSTALL_LOG"
  
  # Check if helm is available
  HELM_CMD=""
  if command -v helm &> /dev/null; then
    HELM_CMD="helm"
  elif [ -f "$SCRIPT_DIR/helm" ]; then
    HELM_CMD="$SCRIPT_DIR/helm"
  else
    echo "警告: 未找到 helm 命令，尝试使用 kubectl 手动部署 EdgeMesh" | tee -a "$INSTALL_LOG"
    echo "EdgeMesh 需要 helm 进行部署，请手动安装:" | tee -a "$INSTALL_LOG"
    echo "  1. 下载 helm: wget https://get.helm.sh/helm-v3.13.0-linux-$ARCH.tar.gz" | tee -a "$INSTALL_LOG"
    echo "  2. 解压并安装: tar -xzf helm-v3.13.0-linux-$ARCH.tar.gz && sudo mv linux-$ARCH/helm /usr/local/bin/" | tee -a "$INSTALL_LOG"
    echo "  3. 安装 EdgeMesh: helm install edgemesh $HELM_CHART_DIR/edgemesh.tgz --namespace kubeedge \\" | tee -a "$INSTALL_LOG"
    echo "       --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \\" | tee -a "$INSTALL_LOG"
    echo "       --set agent.psk=\"$EDGEMESH_PSK\" \\" | tee -a "$INSTALL_LOG"
    echo "       --set agent.relayNodes[0].nodeName=\"$MASTER_NODE\" \\" | tee -a "$INSTALL_LOG"
    echo "       --set agent.relayNodes[0].advertiseAddress=\"{$CLOUD_IP}\"" | tee -a "$INSTALL_LOG"
    
    # Save PSK to file for edge nodes
    echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
    echo "EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
    HELM_CMD=""
  fi
  
  if [ -n "$HELM_CMD" ]; then
    # Install EdgeMesh using helm
    $HELM_CMD install edgemesh "$HELM_CHART_DIR/edgemesh.tgz" \
      --namespace kubeedge \
      --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
      --set agent.psk="$EDGEMESH_PSK" \
      --set agent.relayNodes[0].nodeName="$MASTER_NODE" \
      --set agent.relayNodes[0].advertiseAddress="{$CLOUD_IP}" 2>&1 | tee -a "$INSTALL_LOG"
    
    if [ $? -eq 0 ]; then
      echo "✓ EdgeMesh 安装成功" | tee -a "$INSTALL_LOG"
      
      # Save PSK to file for edge nodes
      echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
      echo "EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
      echo "  提示: EdgeMesh Agent 将在边缘节点加入后自动部署到各边缘节点" | tee -a "$INSTALL_LOG"
    else
      echo "✗ EdgeMesh 安装失败，请检查日志" | tee -a "$INSTALL_LOG"
    fi
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
