#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 完整清理脚本
# 用途：在重新安装前清理所有 K3s、KubeEdge 组件
# 说明：移除 K3s、CloudCore、EdgeCore、容器运行时和相关配置

if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行此脚本"
  exit 1
fi

echo "=========================================="
echo "=== 开始清理 K3s 和 KubeEdge 组件 ==="
echo "=========================================="
echo ""

# 检测是云端还是边缘端
IS_CLOUD=false
IS_EDGE=false

# 检查k3s服务或二进制文件
if systemctl list-units --full -all | grep -q "k3s.service" || [ -f /usr/local/bin/k3s ]; then
  IS_CLOUD=true
fi

if systemctl list-units --full -all | grep -q "edgecore.service" || [ -f /usr/local/bin/edgecore ]; then
  IS_EDGE=true
fi

echo "检测到的组件："
[ "$IS_CLOUD" = true ] && echo "  - K3s (云端)"
[ "$IS_EDGE" = true ] && echo "  - EdgeCore (边缘端)"
# ==========================================
# 云端清理 (K3s + CloudCore)
# ==========================================
if [ "$IS_CLOUD" = true ]; then
  echo "[云端] 开始清理 K3s 和 CloudCore..."
  echo ""
  
  # 1. 运行 K3s 卸载脚本（如果存在）- 这是最彻底的方式
  echo "[1/9] 运行 K3s 卸载脚本..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh || true
    echo "  ✓ K3s 卸载脚本已执行"
  elif [ -f "$SCRIPT_DIR/k3s-uninstall.sh" ]; then
    "$SCRIPT_DIR/k3s-uninstall.sh" || true
    echo "  ✓ K3s 卸载脚本已执行（使用项目脚本）"
  else
    echo "  - K3s 卸载脚本不存在，手动清理"
  fi
  
  # 2. 停止 K3s 服务
  echo "[2/9] 停止 K3s 服务..."
  if systemctl is-active --quiet k3s 2>/dev/null; then
    systemctl stop k3s || true
    echo "  ✓ K3s 服务已停止"
  fi
  
  if systemctl is-enabled --quiet k3s 2>/dev/null; then
    systemctl disable k3s || true
    echo "  ✓ K3s 服务已禁用"
  fi
  
  # 3. 杀死所有k3s和containerd相关进程
  echo "[3/9] 杀死残留进程..."
  pkill -9 k3s || true
  pkill -9 containerd || true
  pkill -9 containerd-shim || true
  pkill -9 containerd-shim-runc-v2 || true
  pkill -9 cloudcore || true
  sleep 2
  echo "  ✓ 进程已清理"
  
  # 4. 卸载挂载点
  echo "[4/9] 卸载k3s挂载点..."
  for mount in $(mount | grep '/run/k3s\|/var/lib/rancher/k3s\|/var/lib/kubelet' | cut -d ' ' -f 3); do
    umount "$mount" 2>/dev/null || true
  done
  echo "  ✓ 挂载点已卸载"
  
  # 5. 删除 K3s 服务文件和二进制
  echo "[5/9] 删除 K3s 相关文件..."
  rm -f /etc/systemd/system/k3s.service
  rm -f /etc/systemd/system/k3s.service.env
  rm -f /etc/systemd/system/multi-user.target.wants/k3s.service
  rm -f /usr/local/bin/k3s
  rm -f /usr/local/bin/k3s-*
  rm -f /usr/local/bin/kubectl
  rm -f /usr/local/bin/crictl
  rm -f /usr/local/bin/ctr
  systemctl daemon-reload
  echo "  ✓ K3s 二进制文件已删除"
  
  # 6. 删除 K3s 数据目录
  echo "[6/9] 删除 K3s 数据目录..."
  rm -rf /var/lib/rancher/k3s
  rm -rf /var/lib/rancher/node
  rm -rf /var/lib/rancher
  rm -rf /etc/rancher/k3s
  rm -rf /etc/rancher/node
  rm -rf /etc/rancher
  rm -rf /run/k3s
  rm -rf /run/flannel
  echo "  ✓ K3s 数据已删除"
  
  # 7. 删除 CloudCore 和 KubeEdge 组件
  echo "[7/9] 清理 CloudCore..."
  rm -f /usr/local/bin/cloudcore
  rm -f /usr/local/bin/keadm
  rm -rf /etc/kubeedge
  rm -rf /var/lib/kubeedge
  echo "  ✓ CloudCore 已删除"
  
  # 8. 清理网络接口
  echo "[8/9] 清理网络接口..."
  ip link delete cni0 2>/dev/null || true
  ip link delete flannel.1 2>/dev/null || true
  ip link delete kube-bridge 2>/dev/null || true
  
  # 清理网络命名空间
  for ns in $(ip netns list 2>/dev/null | grep 'cni-' | awk '{print $1}'); do
    ip netns delete "$ns" 2>/dev/null || true
  done
  echo "  ✓ 网络接口已清理"
  
  # 9. 清理 iptables 规则
  echo "[9/9] 清理 iptables 规则..."
  iptables -t nat -F 2>/dev/null || true
  iptables -t nat -X 2>/dev/null || true
  iptables -t filter -F 2>/dev/null || true
  iptables -t filter -X 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -t mangle -X 2>/dev/null || true
  echo "  ✓ iptables 规则已清理"
  
  echo ""
  echo "✓ 云端清理完成！"
  echo ""
fi

# ==========================================
# 边缘端清理 (EdgeCore)
# ==========================================
if [ "$IS_EDGE" = true ]; then
  echo "[边缘端] 开始清理 EdgeCore..."
  echo ""
  
  # 1. 停止并禁用 edgecore 服务
  echo "[1/7] 停止 EdgeCore 服务..."
  if systemctl is-active --quiet edgecore 2>/dev/null; then
    systemctl stop edgecore || true
    echo "  ✓ EdgeCore 服务已停止"
  fi
  
  if systemctl is-enabled --quiet edgecore 2>/dev/null; then
    systemctl disable edgecore || true
    echo "  ✓ EdgeCore 服务已禁用"
  fi
  
  rm -f /etc/systemd/system/edgecore.service
  echo "  ✓ EdgeCore 服务文件已删除"

  # 2. 停止并禁用 mosquitto 服务
  echo "[2/8] 停止 Mosquitto MQTT 服务..."
  if systemctl is-active --quiet mosquitto 2>/dev/null; then
    systemctl stop mosquitto || true
    echo "  ✓ Mosquitto 服务已停止"
  fi
  
  if systemctl is-enabled --quiet mosquitto 2>/dev/null; then
    systemctl disable mosquitto || true
    echo "  ✓ Mosquitto 服务已禁用"
  fi
  
  rm -f /etc/systemd/system/mosquitto.service
  echo "  ✓ Mosquitto 服务文件已删除"

  # 3. 停止并禁用 containerd 服务
  echo "[3/8] 停止 containerd 服务..."
  if systemctl is-active --quiet containerd 2>/dev/null; then
    systemctl stop containerd || true
    echo "  ✓ containerd 服务已停止"
  fi
  
  if systemctl is-enabled --quiet containerd 2>/dev/null; then
    systemctl disable containerd || true
    echo "  ✓ containerd 服务已禁用"
  fi
  
  rm -f /etc/systemd/system/containerd.service
  echo "  ✓ containerd 服务文件已删除"

  # 4. 杀死所有相关进程
  echo "[4/8] 杀死残留进程..."
  pkill -9 edgecore || true
  pkill -9 mosquitto || true
  pkill -9 containerd || true
  pkill -9 containerd-shim || true
  pkill -9 containerd-shim-runc-v2 || true
  sleep 2
  echo "  ✓ 进程已清理"

  # 5. 卸载挂载点
  echo "[5/8] 卸载containerd挂载点..."
  for mount in $(mount | grep '/run/containerd\|/var/lib/containerd\|/var/lib/kubelet' | cut -d ' ' -f 3); do
    umount "$mount" 2>/dev/null || true
  done
  echo "  ✓ 挂载点已卸载"

  # 6. 删除二进制文件
  echo "[6/8] 删除边缘端二进制文件..."
  rm -f /usr/local/bin/edgecore
  rm -f /usr/local/bin/containerd
  rm -f /usr/local/bin/containerd-shim
  rm -f /usr/local/bin/containerd-shim-runc-v2
  rm -f /usr/local/bin/ctr
  rm -f /usr/local/bin/runc
  rm -f /usr/local/bin/keadm
  systemctl daemon-reload
  echo "  ✓ 二进制文件已删除"

  # 7. 删除 CNI 插件
  echo "[7/8] 删除 CNI 插件..."
  rm -rf /opt/cni/bin/*
  rm -rf /etc/cni
  echo "  ✓ CNI 插件已删除"

  # 8. 删除配置和数据目录
  echo "[8/8] 删除配置和数据目录..."
  rm -rf /etc/kubeedge
  rm -rf /etc/containerd
  rm -rf /var/lib/kubeedge
  rm -rf /var/lib/containerd
  rm -rf /var/lib/kubelet
  rm -rf /var/lib/mosquitto
  rm -rf /var/log/mosquitto
  rm -rf /run/containerd
  rm -rf /run/kubeedge
  echo "  ✓ 配置和数据已删除"
  
  echo ""
  echo "✓ 边缘端清理完成！"
  echo ""
fi

# ==========================================
# 通用清理
# ==========================================
echo "[通用] 执行通用清理..."

# 重载 systemd
systemctl daemon-reload

# 清理日志文件
rm -f /var/log/kubeedge-*-install.log

echo "  ✓ systemd 已重载"
echo "  ✓ 日志文件已清理"

echo ""
echo "=========================================="
echo "✓✓✓ 清理完成！系统已重置 ✓✓✓"
echo "=========================================="
echo ""

if [ "$IS_CLOUD" = true ]; then
  echo "现在可以重新安装云端："
  echo "  sudo ./cloud/install/install.sh <对外IP> [节点名称]"
  echo ""
  echo "示例："
  echo "  sudo ./cloud/install/install.sh 192.168.1.100"
fi

if [ "$IS_EDGE" = true ]; then
  echo "现在可以重新安装边缘端："
  echo "  sudo ./edge/install/install.sh <云端地址> <token> [节点名称]"
  echo ""
  echo "示例："
  echo "  sudo ./edge/install/install.sh 192.168.1.100:10000 <token> edge-node-1"
fi

if [ "$IS_CLOUD" = false ] && [ "$IS_EDGE" = false ]; then
  echo "未检测到已安装的组件。"
fi

echo ""
echo "提示：如需完全重启系统，建议执行："
echo "  sudo reboot"
echo ""
