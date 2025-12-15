#!/usr/bin/env bash
set -euo pipefail

# KubeEdge Cloud 完全清理脚本
# 用途：清理 K3s 和 CloudCore 所有组件
# 说明：移除所有 K3s、CloudCore 和相关配置，不区分节点类型

if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行此脚本"
  exit 1
fi

echo "=========================================="
echo "=== KubeEdge 完全清理脚本 ==="
echo "=========================================="
echo ""

HAS_DOCKER=false
HAS_K3S=false
HAS_CLOUDCORE=false

# 检查组件是否存在
if systemctl list-unit-files 2>/dev/null | grep -q "^k3s.service" || systemctl list-unit-files 2>/dev/null | grep -q "^k3s-agent.service"; then
  HAS_K3S=true
fi

if command -v cloudcore &> /dev/null || [ -f /usr/local/bin/cloudcore ] || [ -f /etc/kubeedge/config/cloudcore.yaml ]; then
  HAS_CLOUDCORE=true
fi

if systemctl list-units --full -all 2>/dev/null | grep -q "docker.service" || command -v docker &> /dev/null; then
  HAS_DOCKER=true
fi

echo "检测到的组件："
[ "$HAS_K3S" = true ] && echo "  - K3s (已安装)"
[ "$HAS_CLOUDCORE" = true ] && echo "  - CloudCore (已安装)"
[ "$HAS_DOCKER" = true ] && echo "  - Docker (已安装)"

if [ "$HAS_DOCKER" = true ]; then
  echo ""
  echo "⚠️  警告: 检测到系统已安装 Docker"
  echo "   Docker 依赖 containerd，清理 K3s 可能不会影响 Docker"
  echo "   但如果您想完全卸载 Docker，请手动执行："
  echo "   - apt-get remove docker-ce docker-ce-cli docker.io"
  echo "   - systemctl stop docker && systemctl disable docker"
  echo ""
fi

echo "⚠️  开始自动清理 KubeEdge 所有组件..."
echo ""
read -p "确定要继续吗？(y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "操作已取消"
    exit 1
fi

# 1. 停止所有相关服务
echo "[1/12] 停止所有相关服务..."
for service in k3s k3s-agent cloudcore; do
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    systemctl stop "$service"
    systemctl disable "$service"
    echo "  ✓ $service 服务已停止并禁用"
  fi
done

# 2. 运行 K3s 卸载脚本（如果存在）
echo "[2/12] 运行 K3s 卸载脚本..."
for uninstall_script in /usr/local/bin/k3s-uninstall.sh /usr/local/bin/k3s-agent-uninstall.sh; do
  if [ -f "$uninstall_script" ]; then
    echo "  - 执行 $uninstall_script"
    "$uninstall_script" || true
  fi
done

# 3. 杀死所有相关进程
echo "[3/12] 强制停止所有相关进程..."
pkill -9 k3s 2>/dev/null || true
pkill -9 cloudcore 2>/dev/null || true
pkill -9 containerd 2>/dev/null || true
pkill -9 containerd-shim 2>/dev/null || true
pkill -9 flanneld 2>/dev/null || true

# 查找并杀死所有 K3s/containerd 相关进程
K3S_PIDS=$(ps aux | grep -E '[k]3s|[c]ontainerd' | awk '{print $2}' || true)
if [ -n "$K3S_PIDS" ]; then
  echo "  - 找到相关进程 PID: $K3S_PIDS"
  kill -9 $K3S_PIDS 2>/dev/null || true
fi
sleep 2
echo "  ✓ 所有相关进程已停止"

# 4. 卸载挂载点
echo "[4/12] 卸载所有相关挂载点..."
MOUNT_POINTS=$(mount | grep -E '(k3s|kubelet|rancher|containerd)' | cut -d ' ' -f 3 || true)
if [ -n "$MOUNT_POINTS" ]; then
  for mount in $MOUNT_POINTS; do
    umount -f "$mount" 2>/dev/null || true
    echo "  - 已卸载: $mount"
  done
fi
echo "  ✓ 挂载点已清理"

# 5. 删除 K3s 二进制文件
echo "[5/12] 删除 K3s 二进制文件..."
for binary in k3s kubectl crictl ctr k3s-killall.sh k3s-uninstall.sh k3s-agent-uninstall.sh; do
  if [ -f "/usr/local/bin/$binary" ]; then
    rm -f "/usr/local/bin/$binary"
    echo "  - 已删除: /usr/local/bin/$binary"
  fi
done
echo "  ✓ K3s 二进制文件已删除"

# 6. 删除 K3s 数据目录
echo "[6/12] 删除 K3s 数据目录..."
for dir in /var/lib/rancher/k3s /etc/rancher /run/k3s /var/lib/kubelet /var/lib/cni /opt/cni; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "  - 已删除: $dir"
  fi
done
echo "  ✓ K3s 数据目录已删除"

# 7. 清理 CloudCore
echo "[7/12] 清理 CloudCore 组件..."
if command -v cloudcore &> /dev/null || [ -f /usr/local/bin/cloudcore ]; then
  rm -f /usr/local/bin/cloudcore
  rm -f /usr/local/bin/keadm
  echo "  - CloudCore 二进制文件已删除"
fi

for dir in /etc/kubeedge /var/lib/kubeedge /var/log/kubeedge; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "  - 已删除: $dir"
  fi
done
echo "  ✓ CloudCore 已清理"

# 8. 清理网络接口
echo "[8/12] 清理网络接口..."
for iface in cni0 flannel.1 kube-bridge edge0; do
  if ip link show "$iface" &> /dev/null; then
    ip link delete "$iface" 2>/dev/null || true
    echo "  - 已删除网络接口: $iface"
  fi
done
echo "  ✓ 网络接口已清理"

# 9. 清理 iptables 规则
echo "[9/12] 清理 iptables 规则..."
for table in filter nat mangle raw security; do
  iptables -t "$table" -F 2>/dev/null || true
  iptables -t "$table" -X 2>/dev/null || true
done
echo "  ✓ iptables 规则已清理"

# 10. 清理 DNS 配置
echo "[10/12] 清理 DNS 配置..."
if [ -f /etc/resolv.conf.bak ]; then
  cp /etc/resolv.conf.bak /etc/resolv.conf
  echo "  - DNS 配置已恢复"
fi
sed -i '/10.43.0.10/d' /etc/resolv.conf 2>/dev/null || true
sed -i '/k3s/d' /etc/resolv.conf 2>/dev/null || true

# 11. 清理 systemd 服务文件
echo "[11/12] 清理 systemd 服务文件..."
for service_file in /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service /etc/systemd/system/cloudcore.service; do
  if [ -f "$service_file" ]; then
    rm -f "$service_file"
    echo "  - 已删除: $service_file"
  fi
done

# 清理 systemd 目录
rm -f /etc/systemd/system/k3s*.service 2>/dev/null || true
rm -f /etc/systemd/system/cloudcore.service 2>/dev/null || true
systemctl daemon-reload
echo "  ✓ systemd 服务文件已清理"

# 12. 清理日志文件
echo "[12/12] 清理日志文件..."
find /var/log -name "*k3s*" -type f -delete 2>/dev/null || true
find /var/log -name "*kubeedge*" -type f -delete 2>/dev/null || true
find /var/log -name "*containerd*" -type f -delete 2>/dev/null || true
find /tmp -name "*k3s*" -type f -delete 2>/dev/null || true
find /tmp -name "*kubeedge*" -type f -delete 2>/dev/null || true
echo "  ✓ 日志文件已清理"

echo ""
echo "=========================================="
echo "✓✓✓ KubeEdge 完全清理完成！✓✓✓"
echo "=========================================="
echo ""
echo "已清理的组件："
[ "$HAS_K3S" = true ] && echo "  ✓ K3s (包括 master/worker)"
[ "$HAS_CLOUDCORE" = true ] && echo "  ✓ CloudCore"
[ "$HAS_DOCKER" = true ] && echo "  ⓘ Docker 未被清理（如需清理请手动执行）"
echo ""
echo "清理完成的项目："
echo "  ✓ 停止所有服务"
echo "  ✓ 删除二进制文件"
echo "  ✓ 删除数据目录"
echo "  ✓ 清理网络配置"
echo "  ✓ 清理 iptables 规则"
echo "  ✓ 清理日志文件"
echo ""
echo "现在可以重新安装："
echo "  cd /data && sudo ./install.sh <对外IP> [节点名称]"
echo ""
echo "提示：如需完全重启系统，建议执行："
echo "  sudo reboot"