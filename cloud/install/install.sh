#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 云端离线安装脚本

# 用途:
#   1. 安装K3s主节点/云端: sudo ./install.sh <对外IP> [可选-节点名称]
#   2. 安装K3s worker节点: sudo ./install.sh --worker <K3S_MASTER_IP>[:PORT] <K3S_TOKEN> [可选-节点名称]
# 示例:
#   sudo ./install.sh 192.168.1.100
#   sudo ./install.sh 192.168.1.100 k3s-master
#   sudo ./install.sh --worker 192.168.1.100 K10abcdef... worker01

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

MODE="normal"
EXTERNAL_IP=""
K3S_MASTER_ADDR=""
K3S_TOKEN=""
NODE_NAME="k3s-master"

if [ "${1:-}" = "--worker" ]; then
  MODE="worker"
  # worker模式下不赋值 EXTERNAL_IP
  if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    echo "错误：worker模式下必须指定 <K3S_MASTER_IP>[:PORT] <K3S_TOKEN>"
    echo "用法: sudo ./install.sh --worker <K3S_MASTER_IP>[:PORT] <K3S_TOKEN> [可选-节点名称]"
    exit 1
  fi
  K3S_MASTER_ADDR_PORT="${2}"
  K3S_TOKEN="${3}"
  NODE_NAME="${4:-k3s-worker}"
  # 检查是否带端口
  if [[ "$K3S_MASTER_ADDR_PORT" == *:* ]]; then
    K3S_MASTER_ADDR="${K3S_MASTER_ADDR_PORT%%:*}"
    K3S_MASTER_PORT="${K3S_MASTER_ADDR_PORT##*:}"
    # 如果端口不是数字，说明没带端口
    if ! [[ "$K3S_MASTER_PORT" =~ ^[0-9]+$ ]]; then
      K3S_MASTER_ADDR="$K3S_MASTER_ADDR_PORT"
      K3S_MASTER_PORT="6443"
    fi
  else
    K3S_MASTER_ADDR="$K3S_MASTER_ADDR_PORT"
    K3S_MASTER_PORT="6443"
  fi
else
  EXTERNAL_IP="${1:-}"
  NODE_NAME="${2:-k3s-master}"
fi

KUBEEDGE_VERSION="1.22.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LOG="/var/log/kubeedge-cloud-install.log"

# 参数校验
if [ "$MODE" = "normal" ]; then
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

echo "=== KubeEdge 云端/worker离线安装脚本 ===" | tee "$INSTALL_LOG"
echo "架构: $ARCH" | tee -a "$INSTALL_LOG"
if [ "$MODE" = "normal" ]; then
  echo "对外 IP: $EXTERNAL_IP" | tee -a "$INSTALL_LOG"
else
  echo "worker模式: master=$K3S_MASTER_ADDR, token=$K3S_TOKEN" | tee -a "$INSTALL_LOG"
fi
echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# =====================================
# 公共函数定义
# =====================================

# 函数: 检查K3s服务是否已启动
check_k3s_running() {
  local max_wait="${1:-30}"
  local wait_interval="${2:-2}"
  
  echo "检查K3s服务是否已启动 (最多等待 ${max_wait} 秒)..." | tee -a "$INSTALL_LOG"
  
  for i in $(seq 1 "$max_wait"); do
    if command -v k3s &>/dev/null; then
      if k3s kubectl cluster-info &>/dev/null 2>&1; then
        echo "✓ K3s服务已启动并运行正常" | tee -a "$INSTALL_LOG"
        return 0
      fi
    fi
    echo "等待K3s服务启动... (${i}/${max_wait})" | tee -a "$INSTALL_LOG"
    sleep "$wait_interval"
  done
  
  echo "✗ K3s服务启动超时或运行异常" | tee -a "$INSTALL_LOG"
  return 1
}

# 函数: 检查网络连通性
check_network_connectivity() {
  local target_host="$1"
  local target_port="$2"
  local timeout="${3:-5}"
  
  echo "检查网络连通性到 $target_host:$target_port..." | tee -a "$INSTALL_LOG"
  
  # 检查DNS解析
  if ! nslookup "$target_host" >/dev/null 2>&1; then
    # 如果DNS解析失败，尝试直接使用IP
    if [[ ! "$target_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "警告: 无法解析主机名: $target_host" | tee -a "$INSTALL_LOG"
      return 1
    fi
  fi
  
  # 使用nc检查端口
  if command -v nc &>/dev/null; then
    if nc -z -w "$timeout" "$target_host" "$target_port" 2>/dev/null; then
      echo "✓ 网络连通性检查通过: $target_host:$target_port 可达" | tee -a "$INSTALL_LOG"
      return 0
    else
      echo "✗ 网络连通性检查失败: $target_host:$target_port 不可达" | tee -a "$INSTALL_LOG"
      return 1
    fi
  fi
  
  # 使用telnet检查端口
  if command -v telnet &>/dev/null; then
    if timeout "$timeout" telnet "$target_host" "$target_port" </dev/null 2>&1 | grep -q "Connected"; then
      echo "✓ 网络连通性检查通过: $target_host:$target_port 可达" | tee -a "$INSTALL_LOG"
      return 0
    else
      echo "✗ 网络连通性检查失败: $target_host:$target_port 不可达" | tee -a "$INSTALL_LOG"
      return 1
    fi
  fi
  
  # 使用bash内置TCP检查
  if timeout "$timeout" bash -c "exec 3<>/dev/tcp/$target_host/$target_port" 2>/dev/null; then
    echo "✓ 网络连通性检查通过: $target_host:$target_port 可达" | tee -a "$INSTALL_LOG"
    return 0
  else
    echo "✗ 网络连通性检查失败: $target_host:$target_port 不可达" | tee -a "$INSTALL_LOG"
    return 1
  fi
}

# 函数: 加载镜像到K3s containerd
load_images_to_k3s() {
  local images_dir="$1"
  local mode="$2"  # master 或 worker
  
  echo "导入镜像到本地 k3s containerd ($mode模式)..." | tee -a "$INSTALL_LOG"
  
  if [ ! -d "$images_dir" ]; then
    echo "警告: 镜像目录不存在: $images_dir" | tee -a "$INSTALL_LOG"
    echo "跳过镜像导入" | tee -a "$INSTALL_LOG"
    return 1
  fi
  
  local image_count=$(find "$images_dir" -name "*.tar" -type f 2>/dev/null | wc -l)
  if [ "$image_count" -eq 0 ]; then
    echo "警告: 镜像目录中没有找到 .tar 文件: $images_dir" | tee -a "$INSTALL_LOG"
    echo "跳过镜像导入" | tee -a "$INSTALL_LOG"
    return 1
  fi
  
  echo "找到 $image_count 个镜像文件" | tee -a "$INSTALL_LOG"
  
  local loaded_count=0
  local failed_count=0
  
  # 导入所有镜像
  for image_tar in "$images_dir"/*.tar; do
    if [ -f "$image_tar" ]; then
      local image_name=$(basename "$image_tar")
      echo "  导入: $image_name" | tee -a "$INSTALL_LOG"
      
      if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        loaded_count=$((loaded_count + 1))
        echo "    ✓ 成功" | tee -a "$INSTALL_LOG"
      else
        failed_count=$((failed_count + 1))
        echo "    ✗ 失败" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  
  # 验证已加载的镜像
  echo "镜像导入完成: $loaded_count 成功, $failed_count 失败" | tee -a "$INSTALL_LOG"
  
  if [ "$loaded_count" -gt 0 ]; then
    echo "验证已加载的镜像列表:" | tee -a "$INSTALL_LOG"
    k3s ctr images ls -q | while read -r image; do
      echo "  $image" | tee -a "$INSTALL_LOG"
    done
  fi
  
  return $((failed_count > 0 ? 1 : 0))
}

# 函数: 预加载KubeEdge特定镜像
preload_kubeedge_images() {
  local images_dir="$1"
  
  echo "预加载KubeEdge组件镜像..." | tee -a "$INSTALL_LOG"
  
  if [ ! -d "$images_dir" ]; then
    echo "警告: 镜像目录不存在: $images_dir" | tee -a "$INSTALL_LOG"
    return 1
  fi
  
  local kubeedge_count=0
  
  # 查找并导入所有KubeEdge相关镜像
  for image_tar in "$images_dir"/docker.io-kubeedge-*.tar; do
    if [ -f "$image_tar" ]; then
      local image_name=$(basename "$image_tar")
      echo "  预加载KubeEdge镜像: $image_name" | tee -a "$INSTALL_LOG"
      
      if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        kubeedge_count=$((kubeedge_count + 1))
        echo "    ✓ 成功" | tee -a "$INSTALL_LOG"
      else
        echo "    ✗ 失败" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  
  # 同时查找其他可能的KubeEdge镜像命名模式
  for image_tar in "$images_dir"/*kubeedge*.tar; do
    if [ -f "$image_tar" ] && [[ ! "$image_tar" == *docker.io-kubeedge-* ]]; then
      local image_name=$(basename "$image_tar")
      echo "  预加载KubeEdge镜像: $image_name" | tee -a "$INSTALL_LOG"
      
      if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        kubeedge_count=$((kubeedge_count + 1))
        echo "    ✓ 成功" | tee -a "$INSTALL_LOG"
      else
        echo "    ✗ 失败" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  
  if [ "$kubeedge_count" -gt 0 ]; then
    echo "✓ 预加载 $kubeedge_count 个KubeEdge镜像" | tee -a "$INSTALL_LOG"
    echo "验证KubeEdge镜像:" | tee -a "$INSTALL_LOG"
    k3s ctr images ls | grep -i kubeedge | tee -a "$INSTALL_LOG"
  else
    echo "警告: 没有找到KubeEdge镜像" | tee -a "$INSTALL_LOG"
  fi
}

# 函数: 检查并等待k3s-agent服务完全启动
# 函数: 检查并等待k3s-agent服务完全启动（简化版）
wait_for_k3s_agent() {
  local max_attempts=30  # 减少等待时间
  local attempt=1
  
  echo "等待k3s-agent服务启动..." | tee -a "$INSTALL_LOG"
  
  # 先立即检查一次
  local status=$(systemctl is-active k3s-agent 2>/dev/null || echo "unknown")
  if [ "$status" = "active" ]; then
    echo "✓ k3s-agent服务已启动" | tee -a "$INSTALL_LOG"
    return 0
  fi
  
  while [ $attempt -le $max_attempts ]; do
    status=$(systemctl is-active k3s-agent 2>/dev/null || echo "unknown")
    
    if [ "$status" = "active" ]; then
      echo "✓ k3s-agent服务已启动 (等待${attempt}秒)" | tee -a "$INSTALL_LOG"
      
      # 验证进程存在
      if ps aux | grep -v grep | grep -q "k3s agent"; then
        echo "✓ k3s agent进程确认存在" | tee -a "$INSTALL_LOG"
      else
        echo "⚠ k3s agent进程未找到，但服务状态为active" | tee -a "$INSTALL_LOG"
      fi
      
      return 0
    elif [ "$status" = "failed" ]; then
      echo "✗ k3s-agent服务启动失败" | tee -a "$INSTALL_LOG"
      systemctl status k3s-agent --no-pager | tee -a "$INSTALL_LOG"
      return 1
    fi
    
    if [ $((attempt % 5)) -eq 0 ]; then
      echo "  等待中... (${attempt}/${max_attempts}) - 当前状态: $status" | tee -a "$INSTALL_LOG"
    fi
    
    sleep 2
    attempt=$((attempt + 1))
  done
  
  # 检查最终状态
  status=$(systemctl is-active k3s-agent 2>/dev/null || echo "unknown")
  if [ "$status" = "active" ]; then
    echo "✓ k3s-agent服务最终启动成功" | tee -a "$INSTALL_LOG"
    return 0
  else
    echo "✗ k3s-agent服务启动超时，最终状态: $status" | tee -a "$INSTALL_LOG"
    systemctl status k3s-agent --no-pager | tee -a "$INSTALL_LOG"
    return 1
  fi
}

# 函数: 安装K3s worker节点
install_k3s_worker() {
  local k3s_bin="$1"
  local k3s_master_addr="$2"
  local k3s_master_port="$3"
  local k3s_token="$4"
  local node_name="$5"
  local script_dir="$6"
  
  echo "=== 开始安装K3s worker节点 ===" | tee -a "$INSTALL_LOG"
  
  # 步骤1: 检查网络连通性
  echo "[1/5] 检查到master节点的网络连通性..." | tee -a "$INSTALL_LOG"
  if ! check_network_connectivity "$k3s_master_addr" "$k3s_master_port"; then
    echo "警告: 网络连通性检查失败，但继续安装..." | tee -a "$INSTALL_LOG"
    echo "  请确保以下条件:" | tee -a "$INSTALL_LOG"
    echo "  1. master节点($k3s_master_addr)正在运行" | tee -a "$INSTALL_LOG"
    echo "  2. 防火墙已放行端口 $k3s_master_port" | tee -a "$INSTALL_LOG"
    echo "  3. 网络路由正确配置" | tee -a "$INSTALL_LOG"
  else
    echo "✓ 网络连通性检查通过" | tee -a "$INSTALL_LOG"
  fi
  
  # 步骤2: 安装k3s二进制文件
  echo "[2/5] 安装k3s二进制文件..." | tee -a "$INSTALL_LOG"
  if [ -f "$k3s_bin" ]; then
    cp "$k3s_bin" /usr/local/bin/k3s
    chmod +x /usr/local/bin/k3s
    echo "✓ k3s二进制文件已安装" | tee -a "$INSTALL_LOG"
  else
    echo "✗ 找不到k3s二进制文件: $k3s_bin" | tee -a "$INSTALL_LOG"
    return 1
  fi
  
  # 步骤3: 创建k3s-agent服务
  echo "[3/5] 配置k3s-agent服务..." | tee -a "$INSTALL_LOG"
  
  # 清理可能存在的旧配置
  systemctl stop k3s-agent 2>/dev/null || true
  systemctl disable k3s-agent 2>/dev/null || true
  rm -f /etc/systemd/system/k3s-agent.service
  
  # 创建新的服务文件
  cat > /etc/systemd/system/k3s-agent.service << EOF
[Unit]
Description=Lightweight Kubernetes Agent
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s agent \\
  --server=https://${k3s_master_addr}:${k3s_master_port} \\
  --token=${k3s_token} \\
  --node-name=${node_name} \\
  --data-dir=/var/lib/rancher/k3s/agent \\
  --kubelet-arg=cloud-provider=external \\
  --kubelet-arg=provider-id=k3s://${node_name}
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  
  # 设置权限
  chmod 644 /etc/systemd/system/k3s-agent.service
  
  # 重新加载systemd并启动服务
  systemctl daemon-reload
  systemctl enable k3s-agent
  
  echo "✓ k3s-agent服务配置完成" | tee -a "$INSTALL_LOG"
  
  # 步骤4: 启动并等待k3s-agent服务
  echo "[4/5] 启动k3s-agent服务..." | tee -a "$INSTALL_LOG"
  
  # 启动服务
  if ! systemctl start k3s-agent; then
    echo "✗ 启动k3s-agent服务失败" | tee -a "$INSTALL_LOG"
    systemctl status k3s-agent --no-pager | tee -a "$INSTALL_LOG"
    return 1
  fi
  
  # 等待服务完全启动
  if ! wait_for_k3s_agent; then
    echo "✗ k3s-agent服务启动超时或失败" | tee -a "$INSTALL_LOG"
    return 1
  fi
  
  echo "✓ k3s-agent服务启动成功" | tee -a "$INSTALL_LOG"
  
  # 步骤5: 加载镜像
  echo "[5/5] 加载容器镜像..." | tee -a "$INSTALL_LOG"
  
  # 等待k3s containerd准备就绪
  echo "  等待containerd准备就绪..." | tee -a "$INSTALL_LOG"
  for i in $(seq 1 30); do
    if k3s ctr images ls >/dev/null 2>&1; then
      echo "  ✓ containerd已就绪" | tee -a "$INSTALL_LOG"
      break
    fi
    if [ $i -eq 30 ]; then
      echo "  ✗ containerd准备超时，跳过镜像加载" | tee -a "$INSTALL_LOG"
      return 0
    fi
    sleep 1
  done
  
  # 查找并加载镜像
  local images_dir=$(find "$script_dir" -type d -name "images" 2>/dev/null | head -1)
  if [ -n "$images_dir" ] && [ -d "$images_dir" ]; then
    # 先加载普通镜像
    if load_images_to_k3s "$images_dir" "worker"; then
      echo "✓ 普通镜像加载完成" | tee -a "$INSTALL_LOG"
    else
      echo "✗ 普通镜像加载失败" | tee -a "$INSTALL_LOG"
    fi
    
    # 预加载KubeEdge镜像
    if preload_kubeedge_images "$images_dir"; then
      echo "✓ KubeEdge镜像预加载完成" | tee -a "$INSTALL_LOG"
    else
      echo "✗ KubeEdge镜像预加载失败" | tee -a "$INSTALL_LOG"
    fi
  else
    echo "⚠ 未找到镜像目录，跳过镜像加载" | tee -a "$INSTALL_LOG"
  fi
  
  echo "=== K3s worker节点安装完成 ===" | tee -a "$INSTALL_LOG"
  return 0
}

# =====================================
# 主程序逻辑
# =====================================

# worker模式只做worker节点安装
if [ "$MODE" = "worker" ]; then
  echo "=== K3s Worker节点安装模式 ===" | tee -a "$INSTALL_LOG"
  
  # 查找k3s二进制文件
  K3S_BIN=$(find "$SCRIPT_DIR" -name "k3s-${ARCH}" -type f 2>/dev/null | head -1)
  if [ -z "$K3S_BIN" ]; then
    echo "错误: 未找到 k3s-${ARCH} 二进制文件在 $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
    exit 1
  fi
  
  # 检查master节点token格式
  if [[ ! "$K3S_TOKEN" =~ ^K10.* ]]; then
    echo "警告: K3S_TOKEN格式可能不正确，应该以 'K10' 开头" | tee -a "$INSTALL_LOG"
    echo "当前token: ${K3S_TOKEN:0:50}..." | tee -a "$INSTALL_LOG"
  fi
  
  # 安装worker节点
  if install_k3s_worker "$K3S_BIN" "$K3S_MASTER_ADDR" "$K3S_MASTER_PORT" "$K3S_TOKEN" "$NODE_NAME" "$SCRIPT_DIR"; then
    echo "" | tee -a "$INSTALL_LOG"
    echo "=== Worker节点加入成功 ===" | tee -a "$INSTALL_LOG"
    echo "Master地址: $K3S_MASTER_ADDR:$K3S_MASTER_PORT" | tee -a "$INSTALL_LOG"
    echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
    echo "Token: ${K3S_TOKEN:0:20}..." | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    
    echo "=== 故障排除指南 ===" | tee -a "$INSTALL_LOG"
    echo "1. 检查服务状态: sudo systemctl status k3s-agent" | tee -a "$INSTALL_LOG"
    echo "2. 查看服务日志: sudo journalctl -u k3s-agent -f" | tee -a "$INSTALL_LOG"
    echo "3. 检查网络连接: ping $K3S_MASTER_ADDR" | tee -a "$INSTALL_LOG"
    echo "4. 验证端口连通性: telnet $K3S_MASTER_ADDR $K3S_MASTER_PORT" | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    echo "✓ K3s worker节点安装完成" | tee -a "$INSTALL_LOG"
  else
    echo "✗ K3s worker节点安装失败" | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    echo "=== 故障排除建议 ===" | tee -a "$INSTALL_LOG"
    echo "1. 确保master节点正在运行并且可以从worker节点访问" | tee -a "$INSTALL_LOG"
    echo "2. 检查token是否正确: 在master节点上运行 'cat /var/lib/rancher/k3s/server/node-token'" | tee -a "$INSTALL_LOG"
    echo "3. 检查防火墙设置，确保端口 $K3S_MASTER_PORT 已开放" | tee -a "$INSTALL_LOG"
    echo "4. 查看详细日志: cat $INSTALL_LOG" | tee -a "$INSTALL_LOG"
    exit 1
  fi
  
  exit 0
fi

# =====================================
# Master/Cloud 安装模式 (保持不变)
# =====================================

echo "=== KubeEdge Cloud/Master 安装模式 ===" | tee -a "$INSTALL_LOG"

# 步骤1: 定位二进制文件
echo "[1/10] 定位二进制文件..." | tee -a "$INSTALL_LOG"
K3S_BIN=$(find "$SCRIPT_DIR" -name "k3s-${ARCH}" -type f 2>/dev/null | head -1)
CLOUDCORE_BIN=$(find "$SCRIPT_DIR" -name "cloudcore" -type f 2>/dev/null | head -1)
KEADM_BIN=$(find "$SCRIPT_DIR" -name "keadm" -type f 2>/dev/null | head -1)

if [ -z "$K3S_BIN" ] || [ -z "$CLOUDCORE_BIN" ] || [ -z "$KEADM_BIN" ]; then
  echo "错误: 在 $SCRIPT_DIR 中未找到必需的二进制文件" | tee -a "$INSTALL_LOG"
  echo "  k3s-${ARCH}: $K3S_BIN" | tee -a "$INSTALL_LOG"
  echo "  cloudcore: $CLOUDCORE_BIN" | tee -a "$INSTALL_LOG"
  echo "  keadm: $KEADM_BIN" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "✓ 二进制文件已定位" | tee -a "$INSTALL_LOG"

# 步骤2: 检查先决条件
echo "[2/10] 检查先决条件..." | tee -a "$INSTALL_LOG"
if ! command -v systemctl &> /dev/null; then
  echo "错误: 未找到 systemctl。此脚本需要 systemd。" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "✓ 先决条件检查通过" | tee -a "$INSTALL_LOG"

# 步骤3: 安装k3s
echo "[3/10] 安装k3s..." | tee -a "$INSTALL_LOG"
cp "$K3S_BIN" /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s

# 创建k3s服务
cat > /etc/systemd/system/k3s.service << EOF
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server \\
  --egress-selector-mode=disabled \\
  --advertise-address=$EXTERNAL_IP \\
  --node-name=$NODE_NAME \\
  --tls-san=$EXTERNAL_IP \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.42.0.0/16 \\
  --service-cidr=10.43.0.0/16 \\
  --cluster-dns=10.43.0.10 \\
  --kube-apiserver-arg=bind-address=0.0.0.0 \\
  --kube-apiserver-arg=advertise-address=$EXTERNAL_IP \\
  --kube-apiserver-arg=kubelet-certificate-authority= \\
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

# 等待k3s启动
echo "等待k3s启动..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "✓ k3s已启动" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "等待... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
  echo "错误: k3s启动失败" | tee -a "$INSTALL_LOG"
  systemctl status k3s >> "$INSTALL_LOG" 2>&1 || true
  exit 1
fi

# 复制kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
chmod 644 /etc/rancher/k3s/k3s.yaml

# 统一KUBECTL命令
KUBECTL="/usr/local/bin/k3s kubectl"

# 步骤4: 加载镜像到k3s containerd
echo "[4/10] 加载容器镜像到k3s..." | tee -a "$INSTALL_LOG"
IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)

if check_k3s_running 30 2; then
  # 加载所有镜像
  load_images_to_k3s "$IMAGES_DIR" "master"
  
  # 预加载KubeEdge特定镜像
  preload_kubeedge_images "$IMAGES_DIR"
else
  echo "错误: K3s未运行，无法加载镜像" | tee -a "$INSTALL_LOG"
  exit 1
fi

# 步骤5: 等待API服务器
echo "[5/10] 等待Kubernetes API..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if $KUBECTL cluster-info &> /dev/null; then
    echo "✓ Kubernetes API已就绪" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "等待... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

# 步骤6: 创建kubeedge命名空间
echo "[6/10] 创建KubeEdge命名空间..." | tee -a "$INSTALL_LOG"
$KUBECTL create namespace kubeedge || true
echo "✓ 命名空间已创建" | tee -a "$INSTALL_LOG"

# 步骤7: 安装Istio CRDs
echo "[7/10] 安装Istio CRDs (EdgeMesh依赖)..." | tee -a "$INSTALL_LOG"
CRDS_DIR="$SCRIPT_DIR/crds/istio"
if [ -d "$CRDS_DIR" ] && [ -n "$(ls -A "$CRDS_DIR" 2>/dev/null)" ]; then
  CRD_COUNT=0
  for crd_file in "$CRDS_DIR"/*.yaml; do
    if [ -f "$crd_file" ]; then
      echo "  安装 $(basename "$crd_file")..." | tee -a "$INSTALL_LOG"
      if $KUBECTL apply -f "$crd_file" >> "$INSTALL_LOG" 2>&1; then
        CRD_COUNT=$((CRD_COUNT + 1))
      else
        echo "  警告: 安装失败 $(basename "$crd_file")" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  if [ $CRD_COUNT -gt 0 ]; then
    echo "✓ 安装 $CRD_COUNT 个Istio CRDs" | tee -a "$INSTALL_LOG"
  else
    echo "警告: 在 $CRDS_DIR 中未找到Istio CRDs" | tee -a "$INSTALL_LOG"
  fi
else
  echo "警告: 未找到Istio CRDs目录，EdgeMesh可能无法正常工作" | tee -a "$INSTALL_LOG"
  echo "  期望位置: $CRDS_DIR" | tee -a "$INSTALL_LOG"
fi

# 步骤8: 安装KubeEdge CloudCore
echo "[8/10] 安装KubeEdge CloudCore..." | tee -a "$INSTALL_LOG"
cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# 初始化CloudCore
mkdir -p /etc/kubeedge
"$KEADM_BIN" init --advertise-address="$EXTERNAL_IP" --kubeedge-version=v"$KUBEEDGE_VERSION" --kube-config=/etc/rancher/k3s/k3s.yaml || true

# 等待CloudCore就绪
echo "等待CloudCore就绪..." | tee -a "$INSTALL_LOG"
for i in {1..30}; do
  if $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
    echo "✓ CloudCore已就绪" | tee -a "$INSTALL_LOG"
    break
  fi
  echo "等待... ($i/30)" | tee -a "$INSTALL_LOG"
  sleep 2
done

# 步骤9: 启用CloudCore附加功能
echo "[9/10] 启用CloudCore附加功能..." | tee -a "$INSTALL_LOG"
CLOUDCORE_CONFIG=$($KUBECTL -n kubeedge get cm cloudcore -o jsonpath='{.data.cloudcore\.yaml}' 2>/dev/null || echo "")

if [ -z "$CLOUDCORE_CONFIG" ]; then
  echo "  警告: 未找到CloudCore ConfigMap，跳过自定义配置" | tee -a "$INSTALL_LOG"
else
  echo "  修补CloudCore ConfigMap以启用dynamicController和cloudStream..." | tee -a "$INSTALL_LOG"
  
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
  
  sed -i "s/EXTERNAL_IP_PLACEHOLDER/$EXTERNAL_IP/g" /tmp/cloudcore-patch.yaml
  
  if $KUBECTL -n kubeedge patch cm cloudcore --patch-file /tmp/cloudcore-patch.yaml >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ CloudCore功能已启用" | tee -a "$INSTALL_LOG"
    
    echo "  重启CloudCore pod以应用配置..." | tee -a "$INSTALL_LOG"
    $KUBECTL -n kubeedge delete pod -l kubeedge=cloudcore >> "$INSTALL_LOG" 2>&1 || true
    
    echo "  等待CloudCore重启..." | tee -a "$INSTALL_LOG"
    sleep 5
    for i in {1..30}; do
      if $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
        echo "  ✓ CloudCore重启成功" | tee -a "$INSTALL_LOG"
        break
      fi
      if [ $i -eq 30 ]; then
        echo "  警告: CloudCore重启超时" | tee -a "$INSTALL_LOG"
      fi
      sleep 2
    done
  else
    echo "  警告: 修补CloudCore ConfigMap失败" | tee -a "$INSTALL_LOG"
    echo "  CloudCore将以默认配置运行" | tee -a "$INSTALL_LOG"
  fi
  
  rm -f /tmp/cloudcore-patch.yaml
fi

# 步骤10: 生成edge token
echo "[10/10] 生成edge token..." | tee -a "$INSTALL_LOG"
TOKEN_DIR="/etc/kubeedge/tokens"
mkdir -p "$TOKEN_DIR"

CLOUD_IP="$EXTERNAL_IP"
CLOUD_PORT="10000"

# 等待tokensecret就绪
echo "  等待KubeEdge token secret..." | tee -a "$INSTALL_LOG"
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
  if ! $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
    if [ $((i % 10)) -eq 0 ]; then
      echo "  CloudCore尚未运行，等待... ($i/$MAX_WAIT)" | tee -a "$INSTALL_LOG"
    fi
    sleep 2
    continue
  fi
  
  if $KUBECTL get secret -n kubeedge tokensecret &>/dev/null; then
    echo "  ✓ Token secret已就绪" | tee -a "$INSTALL_LOG"
    break
  fi
  
  if [ $i -eq $MAX_WAIT ]; then
    echo "  警告: ${MAX_WAIT}次尝试后未找到token secret，将尝试keadm" | tee -a "$INSTALL_LOG"
  fi
  sleep 2
done

# 从K8s secret获取token
EDGE_TOKEN=$($KUBECTL get secret -n kubeedge tokensecret -o jsonpath='{.data.tokendata}' 2>/dev/null | base64 -d)

# 备用方案: 尝试keadm gettoken
if [ -z "$EDGE_TOKEN" ]; then
  echo "  尝试keadm gettoken..." | tee -a "$INSTALL_LOG"
  EDGE_TOKEN=$("$KEADM_BIN" gettoken --kubeedge-version=v"$KUBEEDGE_VERSION" --kube-config=/etc/rancher/k3s/k3s.yaml 2>/dev/null || echo "")
fi

# 最后备用方案: 生成简单token
if [ -z "$EDGE_TOKEN" ]; then
  echo "  警告: 使用备用token生成" | tee -a "$INSTALL_LOG"
  EDGE_TOKEN=$(openssl rand -base64 32 | tr -d '\n' || echo "default-token-$(date +%s)")
fi

# 验证token格式
if [[ "$EDGE_TOKEN" == *"."* ]]; then
  echo "  ✓ Token格式已验证 (JWT)" | tee -a "$INSTALL_LOG"
else
  echo "  警告: Token格式可能不正确 (非JWT格式)" | tee -a "$INSTALL_LOG"
fi

# 保存token到文件
TOKEN_FILE="$TOKEN_DIR/edge-token.txt"
cat > "$TOKEN_FILE" << EOF
{
  "cloudIP": "$CLOUD_IP",
  "cloudPort": $CLOUD_PORT,
  "token": "$EDGE_TOKEN",
  "generatedAt": "$(date -u +%Y-%m%dT%H:%M:%SZ)",
  "edgeConnectCommand": "sudo ./install.sh $CLOUD_IP:$CLOUD_PORT $EDGE_TOKEN"
}
EOF

chmod 600 "$TOKEN_FILE"
echo "✓ Edge token已生成" | tee -a "$INSTALL_LOG"

echo "" | tee -a "$INSTALL_LOG"

# =====================================
# 附加配置 (保持不变)
# =====================================

# 修补K3s内置Metrics Server
echo "" | tee -a "$INSTALL_LOG"
echo "=== 配置 Metrics Server 以支持 KubeEdge ===" | tee -a "$INSTALL_LOG"

if $KUBECTL get deployment metrics-server -n kube-system &>/dev/null; then
  echo "找到内置metrics-server，应用KubeEdge兼容性补丁..." | tee -a "$INSTALL_LOG"
  
  # 设置hostNetwork, affinity和tolerations
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
    echo "✓ 已应用hostNetwork, affinity和tolerations" | tee -a "$INSTALL_LOG"
  fi
  
  # 修改容器配置
  $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":4443}]' >> "$INSTALL_LOG" 2>&1 || true
  $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"--secure-port=4443"}]' >> "$INSTALL_LOG" 2>&1 || true
  $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >> "$INSTALL_LOG" 2>&1 || true
  $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-use-node-status-port"}]' >> "$INSTALL_LOG" 2>&1 || true
  $KUBECTL patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"}]' >> "$INSTALL_LOG" 2>&1 || true
  
  echo "✓ Metrics-server补丁完成，将自动重启" | tee -a "$INSTALL_LOG"
else
  echo "未找到metrics-server，跳过补丁" | tee -a "$INSTALL_LOG"
fi

# 配置svclb避免边缘节点
echo "" | tee -a "$INSTALL_LOG"
echo "=== 配置 svclb 避免调度到边缘节点 ===" | tee -a "$INSTALL_LOG"

echo "等待svclb DaemonSets创建..." | tee -a "$INSTALL_LOG"
SVCLB_COUNT=0
for i in {1..30}; do
  SVCLB_COUNT=$($KUBECTL get daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname --no-headers 2>/dev/null | wc -l)
  if [ "$SVCLB_COUNT" -gt 0 ]; then
    echo "✓ 找到 $SVCLB_COUNT 个svclb DaemonSet" | tee -a "$INSTALL_LOG"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "等待后未找到svclb DaemonSet" | tee -a "$INSTALL_LOG"
  fi
  sleep 1
done

if [ "$SVCLB_COUNT" -gt 0 ]; then
  echo "添加nodeAffinity以排除边缘节点..." | tee -a "$INSTALL_LOG"
  
  PATCHED_COUNT=0
  $KUBECTL get daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname -o name | while read -r ds; do
    DS_NAME=$(echo "$ds" | cut -d'/' -f2)
    
    AFFINITY_PATCH='{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}'
    
    if $KUBECTL patch "$ds" -n kube-system --type=strategic -p="$AFFINITY_PATCH" >> "$INSTALL_LOG" 2>&1; then
      echo "✓ 已修补 $DS_NAME 的nodeAffinity" | tee -a "$INSTALL_LOG"
      PATCHED_COUNT=$((PATCHED_COUNT + 1))
    else
      echo "修补 $DS_NAME 失败" | tee -a "$INSTALL_LOG"
    fi
  done
  
  echo "✓ svclb DaemonSets已配置 ($PATCHED_COUNT 个已修补)" | tee -a "$INSTALL_LOG"
else
  echo "未找到svclb DaemonSet。如果没有LoadBalancer Service，这是正常的" | tee -a "$INSTALL_LOG"
fi

# 配置kube-proxy避免边缘节点
echo "" | tee -a "$INSTALL_LOG"
echo "=== 配置 kube-proxy 避免边缘节点 (可选) ===" | tee -a "$INSTALL_LOG"
if $KUBECTL -n kube-system get daemonset kube-proxy &>/dev/null; then
  if $KUBECTL -n kube-system patch daemonset kube-proxy --type=strategic -p '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}' >> "$INSTALL_LOG" 2>&1; then
    echo "✓ 已修补kube-proxy以排除边缘节点" | tee -a "$INSTALL_LOG"
  else
    echo "修补kube-proxy失败 (可能已配置)" | tee -a "$INSTALL_LOG"
  fi
else
  echo "未找到kube-proxy DaemonSet (k3s可能未部署); 跳过" | tee -a "$INSTALL_LOG"
fi

# 安装EdgeMesh (可选)
echo "" | tee -a "$INSTALL_LOG"
echo "=== 安装 EdgeMesh (可选) ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

HELM_CHART_DIR="$SCRIPT_DIR/helm-charts"
if [ -d "$HELM_CHART_DIR" ] && [ -f "$HELM_CHART_DIR/edgemesh.tgz" ]; then
  echo "检测到 EdgeMesh Helm Chart，开始自动安装..." | tee -a "$INSTALL_LOG"
  
  # 生成EdgeMesh PSK
  EDGEMESH_PSK=$(openssl rand -base64 32)
  echo "生成 EdgeMesh PSK: $EDGEMESH_PSK" | tee -a "$INSTALL_LOG"
  
  # 获取master节点名称
  MASTER_NODE=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}')
  echo "使用 Relay Node: $MASTER_NODE" | tee -a "$INSTALL_LOG"
  
  # 检查helm是否可用
  HELM_CMD=""
  if command -v helm &> /dev/null; then
    HELM_CMD="helm"
  elif [ -f "$SCRIPT_DIR/helm" ]; then
    HELM_CMD="$SCRIPT_DIR/helm"
  else
    echo "警告: 未找到 helm 命令，跳过EdgeMesh自动安装" | tee -a "$INSTALL_LOG"
    echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
    echo "EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
  fi
  
  if [ -n "$HELM_CMD" ]; then
    $HELM_CMD install edgemesh "$HELM_CHART_DIR/edgemesh.tgz" \
      --namespace kubeedge \
      --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
      --set agent.psk="$EDGEMESH_PSK" \
      --set agent.relayNodes[0].nodeName="$MASTER_NODE" \
      --set agent.relayNodes[0].advertiseAddress="{$CLOUD_IP}" 2>&1 | tee -a "$INSTALL_LOG"
    
    if [ $? -eq 0 ]; then
      echo "✓ EdgeMesh 安装成功" | tee -a "$INSTALL_LOG"
      echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
      echo "EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
    else
      echo "✗ EdgeMesh 安装失败，请检查日志" | tee -a "$INSTALL_LOG"
    fi
  fi
else
  echo "未检测到 EdgeMesh Helm Chart，跳过安装" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 安装完成
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "=== 安装完成 ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== CloudCore 信息 ===" | tee -a "$INSTALL_LOG"
echo "Cloud IP: $CLOUD_IP" | tee -a "$INSTALL_LOG"
echo "Cloud Port: $CLOUD_PORT" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== Edge 连接 Token ===" | tee -a "$INSTALL_LOG"
echo "Token: $EDGE_TOKEN" | tee -a "$INSTALL_LOG"
echo "保存此token用于边缘节点安装" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "【K3s worker 节点加入命令】" | tee -a "$INSTALL_LOG"
K3S_TOKEN_VALUE=""
if [ -f /var/lib/rancher/k3s/server/node-token ]; then
  K3S_TOKEN_VALUE=$(cat /var/lib/rancher/k3s/server/node-token)
  echo "K3S_TOKEN: $K3S_TOKEN_VALUE" | tee -a "$INSTALL_LOG"
else
  echo "K3S_TOKEN: <未找到 /var/lib/rancher/k3s/server/node-token 文件>" | tee -a "$INSTALL_LOG"
fi
echo "sudo ./install.sh --worker $EXTERNAL_IP:6443 $K3S_TOKEN_VALUE <worker节点名称>" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "【KubeEdge edge 节点加入命令】" | tee -a "$INSTALL_LOG"
echo "sudo ./install.sh $CLOUD_IP:$CLOUD_PORT '$EDGE_TOKEN' <edge节点名称>" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== 后续步骤 ===" | tee -a "$INSTALL_LOG"
echo "1. 验证k3s集群:" | tee -a "$INSTALL_LOG"
echo "   kubectl get nodes" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "2. 验证CloudCore:" | tee -a "$INSTALL_LOG"
echo "   kubectl -n kubeedge get pod" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "3. 验证镜像加载:" | tee -a "$INSTALL_LOG"
echo "   k3s ctr images ls" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "4. 连接边缘节点:" | tee -a "$INSTALL_LOG"
echo "   - 使用 cloud IP: $CLOUD_IP" | tee -a "$INSTALL_LOG"
echo "   - 使用 token: $EDGE_TOKEN" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# 打印token到stdout便于复制
echo ""
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