#!/usr/bin/env bash
set -euo pipefail

# KubeEdge Edge 清理脚本
# 用途：清理 EdgeCore、containerd 和相关组件
# 说明：移除 EdgeCore、containerd、CNI 和相关配置

if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行此脚本"
  exit 1
fi

echo "=========================================="
echo "=== KubeEdge Edge 清理脚本 ==="
echo "=========================================="
echo ""

HAS_DOCKER=false
HAS_SYSTEM_CONTAINERD=false

# 检查 Docker
if systemctl list-units --full -all 2>/dev/null | grep -q "docker.service" || command -v docker &> /dev/null; then
  HAS_DOCKER=true
fi

# 检查系统安装的 containerd
if dpkg -l 2>/dev/null | grep -q "containerd.io" || rpm -qa 2>/dev/null | grep -q "containerd.io"; then
  HAS_SYSTEM_CONTAINERD=true
fi

echo "检测到的组件："
echo "  - EdgeCore (边缘端)"
echo "  - Containerd (离线包安装)"
echo "  - CNI 插件"
[ "$HAS_DOCKER" = true ] && echo "  - Docker (系统安装)"
[ "$HAS_SYSTEM_CONTAINERD" = true ] && echo "  - Containerd (系统包管理器安装)"

# 默认不卸载 Docker 和系统 containerd (可通过环境变量控制)
UNINSTALL_DOCKER=${UNINSTALL_DOCKER:-false}
UNINSTALL_SYSTEM_CONTAINERD=${UNINSTALL_SYSTEM_CONTAINERD:-false}

if [ "$HAS_DOCKER" = true ]; then
  if [ "$UNINSTALL_DOCKER" = "true" ]; then
    echo "⚠️  将卸载 Docker (UNINSTALL_DOCKER=true)"
  else
    echo "ℹ️  保留 Docker (如需卸载，请设置: UNINSTALL_DOCKER=true)"
  fi
fi

if [ "$HAS_SYSTEM_CONTAINERD" = true ] && [ "$UNINSTALL_DOCKER" = false ]; then
  if [ "$UNINSTALL_SYSTEM_CONTAINERD" = "true" ]; then
    echo "⚠️  将卸载系统 containerd (UNINSTALL_SYSTEM_CONTAINERD=true)"
  else
    echo "ℹ️  保留系统 containerd (如需卸载，请设置: UNINSTALL_SYSTEM_CONTAINERD=true)"
  fi
fi

echo "⚠️  开始自动清理 EdgeCore 和相关组件..."
echo ""
echo "[边缘端] 开始清理 EdgeCore..."
echo ""

# 1. 停止 EdgeCore 服务
echo "[1/8] 停止 EdgeCore 服务..."
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

# 2. 停止 Mosquitto MQTT 服务
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

# 3. 处理 Docker (如果用户选择卸载)
if [ "$UNINSTALL_DOCKER" = true ]; then
  echo "[3/8] 卸载 Docker..."
  systemctl stop docker 2>/dev/null || true
  systemctl stop docker.socket 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true
  systemctl disable docker.socket 2>/dev/null || true
  
  # 使用包管理器卸载
  if command -v apt-get &> /dev/null; then
    apt-get remove -y docker-ce docker-ce-cli docker.io docker-compose-plugin 2>/dev/null || true
    apt-get purge -y docker-ce docker-ce-cli docker.io docker-compose-plugin 2>/dev/null || true
  elif command -v yum &> /dev/null; then
    yum remove -y docker-ce docker-ce-cli docker.io 2>/dev/null || true
  fi
  
  echo "  ✓ Docker 已卸载"
else
  echo "[3/8] 跳过 Docker (用户选择保留)"
  # 如果保留 Docker，需要停止它以便清理 containerd
  if systemctl is-active --quiet docker 2>/dev/null; then
    echo "  ⚠️  临时停止 Docker 以清理离线 containerd"
    systemctl stop docker 2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
  fi
fi

# 4. 停止 containerd 服务
echo "[4/8] 停止 containerd 服务..."
if systemctl is-active --quiet containerd 2>/dev/null; then
  systemctl stop containerd || true
  echo "  ✓ containerd 服务已停止"
fi

if systemctl is-enabled --quiet containerd 2>/dev/null; then
  systemctl disable containerd || true
  echo "  ✓ containerd 服务已禁用"
fi

# 如果用户选择卸载系统 containerd
if [ "$UNINSTALL_SYSTEM_CONTAINERD" = true ]; then
  if command -v apt-get &> /dev/null; then
    apt-get remove -y containerd.io containerd 2>/dev/null || true
    apt-get purge -y containerd.io containerd 2>/dev/null || true
  elif command -v yum &> /dev/null; then
    yum remove -y containerd.io containerd 2>/dev/null || true
  fi
  echo "  ✓ 系统 containerd 已卸载"
fi

rm -f /etc/systemd/system/containerd.service
rm -f /lib/systemd/system/containerd.service
echo "  ✓ containerd 服务文件已删除"

# 5. 杀死所有相关进程
echo "[5/8] 杀死残留进程..."
pkill -9 edgecore || true
pkill -9 mosquitto || true
if [ "$UNINSTALL_DOCKER" = true ]; then
  pkill -9 dockerd || true
  pkill -9 docker-proxy || true
fi
pkill -9 containerd || true
pkill -9 containerd-shim || true
pkill -9 containerd-shim-runc-v2 || true
sleep 3

# 再次确认清理
pkill -9 containerd || true
if [ "$UNINSTALL_DOCKER" = true ]; then
  pkill -9 dockerd || true
fi
sleep 1
echo "  ✓ 进程已清理"

# 6. 卸载挂载点
echo "[6/8] 卸载containerd挂载点..."
for mount in $(mount | grep '/run/containerd\|/var/lib/containerd\|/var/lib/kubelet\|/var/lib/docker' | cut -d ' ' -f 3); do
  umount "$mount" 2>/dev/null || true
done
echo "  ✓ 挂载点已卸载"

# 7. 删除二进制文件
echo "[7/8] 删除边缘端二进制文件..."
# 删除 EdgeCore 和 keadm
rm -f /usr/local/bin/edgecore
rm -f /usr/local/bin/keadm

# 删除离线安装的 containerd
rm -f /usr/local/bin/containerd*
rm -f /usr/local/bin/ctr

# 如果用户选择卸载，也删除系统位置的
if [ "$UNINSTALL_SYSTEM_CONTAINERD" = true ] || [ "$UNINSTALL_DOCKER" = true ]; then
  rm -f /usr/bin/containerd*
  rm -f /usr/sbin/containerd*
  rm -f /usr/bin/ctr
  rm -f /usr/bin/docker*
  rm -f /usr/bin/runc
  rm -f /usr/sbin/runc
fi

# 删除离线安装的 runc
rm -f /usr/local/bin/runc
rm -f /usr/local/sbin/runc

echo "  ✓ 二进制文件已删除"

# 8. 删除 CNI 插件和配置
echo "[8/8] 删除 CNI 插件..."
rm -rf /opt/cni/bin/*
rm -rf /etc/cni
echo "  ✓ CNI 插件已删除"

# 9. 删除配置和数据目录
echo "[9/8] 删除配置和数据目录..."
rm -rf /etc/kubeedge
rm -rf /etc/containerd
rm -rf /var/lib/kubeedge
rm -rf /var/lib/containerd
rm -rf /var/lib/kubelet
rm -rf /var/lib/mosquitto
rm -rf /var/log/mosquitto
rm -rf /run/containerd
rm -rf /run/kubeedge

if [ "$UNINSTALL_DOCKER" = true ]; then
  rm -rf /var/lib/docker
  rm -rf /etc/docker
fi

echo "  ✓ 配置和数据已删除"

echo ""
echo "✓ 边缘端清理完成！"
echo ""

# 如果保留了 Docker，重新启动它
if [ "$HAS_DOCKER" = true ] && [ "$UNINSTALL_DOCKER" = false ]; then
  echo "[恢复] 重新启动 Docker..."
  systemctl start docker 2>/dev/null || true
  echo "  ✓ Docker 已重新启动"
fi

# 通用清理
echo "[通用] 执行通用清理..."
systemctl daemon-reload
echo "  ✓ systemd 已重载"

rm -f /var/log/kubeedge-*.log
echo "  ✓ 日志文件已清理"

echo ""
echo "=========================================="
echo "✓✓✓ 清理完成！系统已重置 ✓✓✓"
echo "=========================================="
echo ""
echo "现在可以重新安装边缘端："
echo "  cd /data && sudo ./install.sh <云端地址> <token> [节点名称]"
echo ""
echo "提示：如需完全重启系统，建议执行："
echo "  sudo reboot"
